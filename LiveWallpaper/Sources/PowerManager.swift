import Foundation
import IOKit.ps

enum PowerState {
    case ac
    case battery(percentRemaining: Int)
    case unknown

    var shouldPausePlayback: Bool {
        if case .battery(let pct) = self, pct <= 20 { return true }
        return false
    }
}

protocol PowerManagerDelegate: AnyObject {
    func powerStateDidChange(_ state: PowerState)
}

class PowerManager {
    weak var delegate: PowerManagerDelegate?
    private var runLoopSource: CFRunLoopSource?
    private(set) var currentState: PowerState = .unknown

    init() {
        currentState = Self.readPowerState()

        let context = Unmanaged.passUnretained(self).toOpaque()
        runLoopSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let mgr = Unmanaged<PowerManager>.fromOpaque(context).takeUnretainedValue()
            let newState = PowerManager.readPowerState()
            let oldShouldPause = mgr.currentState.shouldPausePlayback
            mgr.currentState = newState
            if newState.shouldPausePlayback != oldShouldPause {
                mgr.delegate?.powerStateDidChange(newState)
            }
        }, context).takeRetainedValue()

        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
    }

    deinit {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
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
