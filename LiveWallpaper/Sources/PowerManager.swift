import Foundation
import IOKit.ps

enum PowerState {
    case ac
    case battery(percentRemaining: Int)
    case unknown
}

protocol PowerManagerDelegate: AnyObject {
    /// Fired only when the COMBINED power-pause condition (low battery ||
    /// Low Power Mode || thermal ≥ serious) flips. AppDelegate maps a flip
    /// to set/clear the coordinator's `.power` reason.
    func powerPauseConditionDidChange(_ isPaused: Bool)
}

class PowerManager {
    weak var delegate: PowerManagerDelegate?
    private var runLoopSource: CFRunLoopSource?
    private var thermalObserver: NSObjectProtocol?
    private var lowPowerObservation: NSKeyValueObservation?
    private var pollTimer: Timer?
    private(set) var currentState: PowerState = .unknown
    private(set) var shouldPausePlayback = false

    init() {
        currentState = Self.readPowerState()
        shouldPausePlayback = computeShouldPause()

        // Low Power Mode: KVO on ProcessInfo. KVO compliance is not officially
        // guaranteed here, so this is a best-effort fast path; the IOPS
        // power-source callback below re-reads the full condition as a
        // defensive fallback (AC/battery transitions coincide with LPM
        // toggles in practice), and the thermal notification also
        // re-evaluates. Evaluation itself reads live ProcessInfo state, so a
        // missed KVO tick only delays, never strands, a flip.
        lowPowerObservation = ProcessInfo.processInfo.observe(
            \.isLowPowerModeEnabled, options: [.new]
        ) { [weak self] _, _ in
            self?.reevaluate()
        }

        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reevaluate()
        }

        let context = Unmanaged.passUnretained(self).toOpaque()
        runLoopSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let mgr = Unmanaged<PowerManager>.fromOpaque(context).takeUnretainedValue()
            mgr.currentState = PowerManager.readPowerState()
            mgr.reevaluate()
        }, context).takeRetainedValue()

        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)

        // Correctness backstop for Low Power Mode: KVO on ProcessInfo is
        // undocumented and the IOPS source fires only on plug/unplug (thermal
        // only on transitions), so on AC power a missed KVO tick could strand
        // a flip for hours. A 30s poll re-reads the full condition; the
        // flip-only callback makes redundant polls free.
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.reevaluate()
        }
        // .common so the poll keeps ticking while a status-bar menu is
        // tracked (same pattern as IdleMonitor).
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    deinit {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        }
        pollTimer?.invalidate()
        if let observer = thermalObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        lowPowerObservation?.invalidate()
    }

    private static let pollInterval: TimeInterval = 30

    /// The full combined condition, evaluated live.
    private func computeShouldPause() -> Bool {
        let battery: Int?
        if case .battery(let pct) = currentState { battery = pct } else { battery = nil }
        return PowerPausePolicy.shouldPause(
            batteryPercentRemaining: battery,
            isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermalState: ProcessInfo.processInfo.thermalState
        )
    }

    /// All observation paths funnel here; KVO may fire off-main, so the
    /// delegate flip notification is marshalled to the main thread where the
    /// coordinator and AppDelegate are used.
    private func reevaluate() {
        if Thread.isMainThread {
            notifyIfFlipped()
        } else {
            DispatchQueue.main.async { [weak self] in self?.notifyIfFlipped() }
        }
    }

    private func notifyIfFlipped() {
        let paused = computeShouldPause()
        let wasPaused = shouldPausePlayback
        shouldPausePlayback = paused
        if paused != wasPaused {
            delegate?.powerPauseConditionDidChange(paused)
        }
    }

    static func readPowerState() -> PowerState {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [Any],
              let first = sources.first,
              let info = IOPSGetPowerSourceDescription(snapshot, first as CFTypeRef)?.takeUnretainedValue() as? [String: Any]
        else {
            return .unknown
        }

        let isCharging = (info[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
        if isCharging { return .ac }

        let capacity = info[kIOPSCurrentCapacityKey] as? Int ?? 100
        return .battery(percentRemaining: capacity)
    }
}
