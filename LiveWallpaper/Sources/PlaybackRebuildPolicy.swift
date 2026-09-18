import Foundation

/// What `applyDecision(.play)` should do about the current engine.
enum PlaybackRebuildAction: Equatable {
    /// Engine and item are present and healthy — call `player.play()`.
    case play
    /// An engine exists but its current item is not attached yet or has
    /// failed. The engine's own retry/recreation paths own recovery; the
    /// app layer must NOT rebuild here — rebuilding in this state recursed
    /// forever (`setVideo → applyDecision → setVideo → …`, stack overflow).
    case waitForItem
    /// No engine at all and a video URL is available — full rebuild.
    case rebuild
    /// Nothing to do (no engine, no video selected).
    case noAction
}

/// Pure decision for the `.play` branch of the app layer's decision
/// application. On macOS 27, `AVPlayerLooper` no longer inserts its template
/// item into the queue synchronously, so a brand-new engine reports a nil
/// `currentItem` for a while — that state is "pending", not "broken".
enum PlaybackRebuildPolicy {
    static func action(
        hasEngine: Bool,
        hasCurrentItem: Bool,
        isCurrentItemFailed: Bool,
        hasVideoURL: Bool
    ) -> PlaybackRebuildAction {
        guard hasEngine else {
            return hasVideoURL ? .rebuild : .noAction
        }
        if hasCurrentItem, !isCurrentItemFailed {
            return .play
        }
        return .waitForItem
    }
}
