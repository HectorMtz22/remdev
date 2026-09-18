import XCTest
import Foundation
@testable import PlaybackCoordinator

final class PlaybackRebuildPolicyTests: XCTestCase {
    private func action(
        hasEngine: Bool,
        hasCurrentItem: Bool = true,
        isCurrentItemFailed: Bool = false,
        hasVideoURL: Bool = true
    ) -> PlaybackRebuildAction {
        PlaybackRebuildPolicy.action(
            hasEngine: hasEngine,
            hasCurrentItem: hasCurrentItem,
            isCurrentItemFailed: isCurrentItemFailed,
            hasVideoURL: hasVideoURL
        )
    }

    /// Regression for the macOS 27 crash: AVPlayerLooper no longer inserts
    /// its item synchronously, so a freshly built engine can report a nil
    /// currentItem. Rebuilding in that state recursed forever
    /// (setVideo → applyDecision → setVideo → …) until the stack overflowed.
    func testEngineWithoutCurrentItemWaitsInsteadOfRebuilding() {
        XCTAssertEqual(
            action(hasEngine: true, hasCurrentItem: false),
            .waitForItem
        )
    }

    /// A failed item is the engine's own recovery job (retries + player
    /// recreation); rebuilding from applyDecision would loop when the asset
    /// fails instantly.
    func testEngineWithFailedCurrentItemWaitsInsteadOfRebuilding() {
        XCTAssertEqual(
            action(hasEngine: true, isCurrentItemFailed: true),
            .waitForItem
        )
    }

    func testEngineWithHealthyCurrentItemPlays() {
        XCTAssertEqual(
            action(hasEngine: true, isCurrentItemFailed: false),
            .play
        )
    }

    func testNoEngineWithVideoRebuilds() {
        XCTAssertEqual(action(hasEngine: false), .rebuild)
    }

    func testNoEngineWithoutVideoDoesNothing() {
        XCTAssertEqual(
            action(hasEngine: false, hasVideoURL: false),
            .noAction
        )
    }
}
