import Foundation

// MARK: - Types

/// Reasons that can hold playback back, ordered highest priority first.
enum PlaybackReason: Int, CaseIterable, Comparable {
    case manual = 0
    case sleep = 1
    case screenOff = 2
    case power = 3
    case idle = 4
    case occlusion = 5

    static func < (lhs: PlaybackReason, rhs: PlaybackReason) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// What the app layer should do about playback right now.
enum PlaybackDecision: Equatable {
    case play
    case pause
    case teardown
}

protocol PlaybackCoordinatorDelegate: AnyObject {
    func playbackCoordinatorDidChangeDecision(
        _ coordinator: PlaybackCoordinator,
        decision: PlaybackDecision,
        reason: PlaybackReason?
    )
}

// MARK: - Coordinator

/// Owns the pause/resume/teardown decision. Signals set and clear reasons;
/// the coordinator evaluates the strongest active reason and reports the
/// resulting decision to its delegate when it changes.
///
/// Pure logic — Foundation only, no AppKit — so it is unit-testable.
final class PlaybackCoordinator {
    private(set) var activeReasons: Set<PlaybackReason> = []
    private(set) var decision: PlaybackDecision = .play
    weak var delegate: PlaybackCoordinatorDelegate?

    var strongestReason: PlaybackReason? {
        activeReasons.min()
    }

    // MARK: Evaluation

    /// Teardown-level reasons (sleep, screenOff) dominate the action even when a
    /// stronger reason like `manual` is active — a decode pipeline cannot survive
    /// system sleep. Manual precedence governs pause-vs-resume only.
    func evaluate() -> PlaybackDecision {
        if activeReasons.contains(.sleep) || activeReasons.contains(.screenOff) {
            return .teardown
        }
        return activeReasons.isEmpty ? .play : .pause
    }

    // MARK: Signals

    func setReason(_ reason: PlaybackReason) {
        guard activeReasons.insert(reason).inserted else { return }
        notifyIfNeeded()
    }

    func clearReason(_ reason: PlaybackReason) {
        guard activeReasons.remove(reason) != nil else { return }
        notifyIfNeeded()
    }

    func clearAllReasons() {
        guard !activeReasons.isEmpty else { return }
        activeReasons.removeAll()
        notifyIfNeeded()
    }

    // MARK: Notifications

    private func notifyIfNeeded() {
        let newDecision = evaluate()
        guard newDecision != decision else { return }
        decision = newDecision
        delegate?.playbackCoordinatorDidChangeDecision(self, decision: decision, reason: strongestReason)
    }
}
