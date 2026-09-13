import Foundation

// MARK: - Types

/// Reasons that can hold playback back, ordered highest priority first.
/// `manual` is not a plain reason — the user's pause intent is modeled as a
/// `userPaused` override that survives signal churn.
enum PlaybackReason: Int, CaseIterable, Comparable {
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
        decision: PlaybackDecision
    )
}

// MARK: - Coordinator

/// Owns the pause/resume/teardown decision. Signals set and clear reasons;
/// the user's Play/Pause toggle is a separate override. Evaluation order:
/// teardown reasons (sleep/screenOff) dominate the action — a decode pipeline
/// cannot survive system sleep — then the user's pause override, then any
/// active reason, then play.
///
/// Pure logic — Foundation only, no AppKit — so it is unit-testable.
final class PlaybackCoordinator {
    private(set) var activeReasons: Set<PlaybackReason> = []
    private(set) var userPaused = false
    private(set) var decision: PlaybackDecision = .play
    weak var delegate: PlaybackCoordinatorDelegate?

    var strongestReason: PlaybackReason? {
        activeReasons.min()
    }

    // MARK: Evaluation

    func evaluate() -> PlaybackDecision {
        if activeReasons.contains(.sleep) || activeReasons.contains(.screenOff) {
            return .teardown
        }
        if userPaused {
            return .pause
        }
        return activeReasons.isEmpty ? .play : .pause
    }

    // MARK: User override

    func userPause() {
        guard !userPaused else { return }
        userPaused = true
        notifyIfNeeded()
    }

    /// Resumes playback and suppresses currently-active weaker pause reasons
    /// (power/idle/occlusion) so they must re-assert via a fresh signal —
    /// matching the old behavior where a manual Play cleared auto-pause flags.
    func userResume() {
        guard userPaused else { return }
        userPaused = false
        activeReasons.subtract([.power, .idle, .occlusion])
        notifyIfNeeded()
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
        delegate?.playbackCoordinatorDidChangeDecision(self, decision: decision)
    }
}
