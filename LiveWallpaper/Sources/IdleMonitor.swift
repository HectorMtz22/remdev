import Foundation
import CoreGraphics

protocol IdleMonitorDelegate: AnyObject {
    func idleMonitorDidBecomeIdle()
    func idleMonitorDidBecomeActive()
}

/// Watches system-wide user input and reports when it goes idle for the
/// configured threshold. Idle time is measured live via
/// `CGEventSource.secondsSinceLastEventType(.combinedSessionState, …)`,
/// taking the minimum across all input event types — any of them resets
/// the system's idle clock, so the minimum is the true idle seconds.
///
/// The delegate drives the timer: `start()` while playback is wanted
/// (decision == .play, or while paused solely by idle so activity can
/// resume), `stop()` otherwise. `stop()` also resets the idle state so a
/// later restart re-evaluates against the fresh system idle clock — after
/// a user's manual Play clears `.idle`, the wallpaper only re-pauses once
/// idle time newly exceeds the threshold again (clicking Play is itself
/// input, so the live measurement reads ~0 immediately after).
final class IdleMonitor {
    weak var delegate: IdleMonitorDelegate?

    /// Seconds between polls; idle detection latency is bounded by this.
    private static let pollInterval: TimeInterval = 30

    /// Input event types that count as user activity.
    private static let eventTypes: [CGEventType] = [
        .mouseMoved, .leftMouseDragged, .rightMouseDragged, .scrollWheel,
        .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown,
        .flagsChanged
    ]

    private var threshold: TimeInterval = 0 // 0 = disabled
    private var timer: Timer?
    private(set) var isIdle = false

    var isEnabled: Bool { threshold > 0 }

    /// Threshold in minutes; 0 disables the monitor.
    func setThreshold(minutes: Int) {
        let newThreshold = TimeInterval(minutes) * 60
        guard newThreshold != threshold else { return }
        threshold = newThreshold
        // Re-arm: a disabled threshold stops polling; an enabled one
        // re-evaluates immediately against the current idle time.
        if !isEnabled {
            stop()
        } else {
            reevaluate()
        }
    }

    /// Begins polling (no-op if already running or disabled).
    func start() {
        guard isEnabled, timer == nil else { return }
        timer = Timer.scheduledTimer(
            withTimeInterval: Self.pollInterval,
            repeats: true
        ) { [weak self] _ in
            self?.reevaluate()
        }
        reevaluate()
    }

    /// Stops polling and forgets the idle state.
    func stop() {
        timer?.invalidate()
        timer = nil
        isIdle = false
    }

    /// Checks current system idle time against the threshold and notifies
    /// the delegate only on a state transition.
    func reevaluate() {
        guard isEnabled else { return }
        let nowIdle = Self.currentIdleSeconds() >= threshold
        guard nowIdle != isIdle else { return }
        isIdle = nowIdle
        if nowIdle {
            delegate?.idleMonitorDidBecomeIdle()
        } else {
            delegate?.idleMonitorDidBecomeActive()
        }
    }

    /// Minimum idle seconds across all input event types: any input event
    /// of these kinds resets its own counter, so the smallest value is
    /// seconds since the last input of any kind.
    private static func currentIdleSeconds() -> TimeInterval {
        eventTypes
            .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
            .min() ?? 0
    }
}
