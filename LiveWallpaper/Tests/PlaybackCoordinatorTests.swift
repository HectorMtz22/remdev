import XCTest
@testable import PlaybackCoordinator

private final class DecisionRecorder: PlaybackCoordinatorDelegate {
    private(set) var decisions: [PlaybackDecision] = []

    func playbackCoordinatorDidChangeDecision(
        _ coordinator: PlaybackCoordinator,
        decision: PlaybackDecision
    ) {
        decisions.append(decision)
    }
}

final class PlaybackCoordinatorTests: XCTestCase {
    private var coordinator: PlaybackCoordinator!
    private var recorder: DecisionRecorder!

    override func setUp() {
        super.setUp()
        coordinator = PlaybackCoordinator()
        recorder = DecisionRecorder()
        coordinator.delegate = recorder
    }

    // MARK: - Single reasons

    func testNoReasonsDecidesPlay() {
        XCTAssertEqual(coordinator.decision, .play)
        XCTAssertTrue(coordinator.activeReasons.isEmpty)
        XCTAssertFalse(coordinator.userPaused)
        XCTAssertTrue(recorder.decisions.isEmpty)
    }

    func testOcclusionAlonePauses() {
        coordinator.setReason(.occlusion)
        XCTAssertEqual(coordinator.decision, .pause)
    }

    func testPowerAlonePauses() {
        coordinator.setReason(.power)
        XCTAssertEqual(coordinator.decision, .pause)
    }

    func testIdleAlonePauses() {
        coordinator.setReason(.idle)
        XCTAssertEqual(coordinator.decision, .pause)
    }

    func testSleepAloneTearsDown() {
        coordinator.setReason(.sleep)
        XCTAssertEqual(coordinator.decision, .teardown)
    }

    func testScreenOffAloneTearsDown() {
        coordinator.setReason(.screenOff)
        XCTAssertEqual(coordinator.decision, .teardown)
    }

    // MARK: - Reason stacking

    func testPowerWinsOverOcclusion() {
        coordinator.setReason(.occlusion)
        coordinator.setReason(.power)
        XCTAssertEqual(coordinator.decision, .pause)
        XCTAssertEqual(coordinator.strongestReason, .power)
    }

    func testSleepWinsOverOcclusion() {
        coordinator.setReason(.occlusion)
        coordinator.setReason(.sleep)
        XCTAssertEqual(coordinator.decision, .teardown)
    }

    func testScreenOffWinsOverIdle() {
        coordinator.setReason(.idle)
        coordinator.setReason(.screenOff)
        XCTAssertEqual(coordinator.decision, .teardown)
    }

    // MARK: - Clearing

    func testClearingStrongestReasonFallsBackToWeaker() {
        coordinator.setReason(.sleep)
        coordinator.setReason(.occlusion)
        XCTAssertEqual(coordinator.decision, .teardown)

        coordinator.clearReason(.sleep)
        XCTAssertEqual(coordinator.decision, .pause)
        XCTAssertEqual(coordinator.strongestReason, .occlusion)

        coordinator.clearReason(.occlusion)
        XCTAssertEqual(coordinator.decision, .play)
    }

    func testClearAllReasonsResumesPlayback() {
        coordinator.setReason(.power)
        coordinator.setReason(.idle)
        coordinator.setReason(.occlusion)
        XCTAssertEqual(coordinator.decision, .pause)

        coordinator.clearAllReasons()
        XCTAssertEqual(coordinator.decision, .play)
        XCTAssertTrue(coordinator.activeReasons.isEmpty)
    }

    // MARK: - User pause override

    func testUserPauseOverridesPlayDecision() {
        coordinator.userPause()
        XCTAssertEqual(coordinator.decision, .pause)
        XCTAssertTrue(coordinator.userPaused)
    }

    func testUserPauseBeatsWeakerPauseReasons() {
        coordinator.setReason(.power)
        coordinator.userPause()
        XCTAssertEqual(coordinator.decision, .pause)

        coordinator.clearReason(.power)
        XCTAssertEqual(coordinator.decision, .pause)
        XCTAssertEqual(coordinator.strongestReason, nil)
    }

    func testUserResumeWhileOccludedPlays() {
        coordinator.setReason(.occlusion)
        XCTAssertEqual(coordinator.decision, .pause)

        coordinator.userPause()
        XCTAssertEqual(coordinator.decision, .pause)

        coordinator.userResume()
        XCTAssertEqual(coordinator.decision, .play)
        XCTAssertNil(coordinator.strongestReason)
    }

    func testUserResumeSuppressesActiveWeakerPauseReasons() {
        coordinator.setReason(.occlusion)
        coordinator.setReason(.power)
        coordinator.userPause()

        coordinator.userResume()
        XCTAssertEqual(coordinator.decision, .play)
        XCTAssertTrue(coordinator.activeReasons.isEmpty,
                      "weaker pause reasons must be suppressed on resume")

        // They must re-assert via a fresh signal
        coordinator.setReason(.power)
        XCTAssertEqual(coordinator.decision, .pause)
    }

    func testUserPauseDoesNotSuppressTeardownReasons() {
        coordinator.setReason(.sleep)
        XCTAssertEqual(coordinator.decision, .teardown)

        coordinator.userPause()
        XCTAssertEqual(coordinator.decision, .teardown)

        coordinator.userResume()
        XCTAssertEqual(coordinator.decision, .teardown)
    }

    func testUserPauseSurvivesClearAllReasons() {
        coordinator.userPause()
        coordinator.setReason(.power)
        coordinator.clearAllReasons()
        XCTAssertEqual(coordinator.decision, .pause,
                       "manual pause must survive a setVideo-style rebuild")
    }

    func testUserResumeAfterSleepPlaysAgain() {
        coordinator.setReason(.sleep)
        coordinator.userPause()
        coordinator.clearReason(.sleep)
        XCTAssertEqual(coordinator.decision, .pause)

        coordinator.userResume()
        XCTAssertEqual(coordinator.decision, .play)
    }

    // MARK: - Delegate notifications

    func testDelegateNotifiedOnSetAndClear() {
        coordinator.setReason(.occlusion)
        coordinator.clearReason(.occlusion)

        XCTAssertEqual(recorder.decisions, [.pause, .play])
    }

    func testSettingSameReasonAgainDoesNotNotify() {
        coordinator.setReason(.power)
        coordinator.setReason(.power)
        XCTAssertEqual(recorder.decisions.count, 1)
    }

    func testClearingInactiveReasonDoesNotNotify() {
        coordinator.clearReason(.idle)
        XCTAssertEqual(recorder.decisions.count, 0)
    }

    func testClearAllWithNoReasonsDoesNotNotify() {
        coordinator.clearAllReasons()
        XCTAssertEqual(recorder.decisions.count, 0)
    }

    func testUserPauseWhenAlreadyPausedByReasonDoesNotNotify() {
        coordinator.setReason(.occlusion)
        coordinator.userPause()
        XCTAssertEqual(recorder.decisions, [.pause])
    }

    func testUserResumeWhenAlreadyPlayingDoesNotNotify() {
        coordinator.userResume()
        XCTAssertEqual(recorder.decisions.count, 0)
    }
}
