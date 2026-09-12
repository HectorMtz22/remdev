import XCTest
@testable import PlaybackCoordinator

private final class DecisionRecorder: PlaybackCoordinatorDelegate {
    private(set) var records: [(decision: PlaybackDecision, reason: PlaybackReason?)] = []

    func playbackCoordinatorDidChangeDecision(
        _ coordinator: PlaybackCoordinator,
        decision: PlaybackDecision,
        reason: PlaybackReason?
    ) {
        records.append((decision, reason))
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
        XCTAssertNil(coordinator.strongestReason)
        XCTAssertTrue(recorder.records.isEmpty)
    }

    func testOcclusionAlonePauses() {
        coordinator.setReason(.occlusion)
        XCTAssertEqual(coordinator.decision, .pause)
        XCTAssertEqual(coordinator.strongestReason, .occlusion)
    }

    func testPowerAlonePauses() {
        coordinator.setReason(.power)
        XCTAssertEqual(coordinator.decision, .pause)
        XCTAssertEqual(coordinator.strongestReason, .power)
    }

    func testIdleAlonePauses() {
        coordinator.setReason(.idle)
        XCTAssertEqual(coordinator.decision, .pause)
        XCTAssertEqual(coordinator.strongestReason, .idle)
    }

    func testManualAlonePauses() {
        coordinator.setReason(.manual)
        XCTAssertEqual(coordinator.decision, .pause)
        XCTAssertEqual(coordinator.strongestReason, .manual)
    }

    func testSleepAloneTearsDown() {
        coordinator.setReason(.sleep)
        XCTAssertEqual(coordinator.decision, .teardown)
        XCTAssertEqual(coordinator.strongestReason, .sleep)
    }

    func testScreenOffAloneTearsDown() {
        coordinator.setReason(.screenOff)
        XCTAssertEqual(coordinator.decision, .teardown)
        XCTAssertEqual(coordinator.strongestReason, .screenOff)
    }

    // MARK: - Reason stacking (stronger wins)

    func testPowerWinsOverOcclusion() {
        coordinator.setReason(.occlusion)
        coordinator.setReason(.power)
        XCTAssertEqual(coordinator.decision, .pause)
        XCTAssertEqual(coordinator.strongestReason, .power)
    }

    func testManualWinsOverOcclusion() {
        coordinator.setReason(.occlusion)
        coordinator.setReason(.manual)
        XCTAssertEqual(coordinator.decision, .pause)
        XCTAssertEqual(coordinator.strongestReason, .manual)
    }

    func testSleepWinsOverOcclusion() {
        coordinator.setReason(.occlusion)
        coordinator.setReason(.sleep)
        XCTAssertEqual(coordinator.decision, .teardown)
        XCTAssertEqual(coordinator.strongestReason, .sleep)
    }

    func testScreenOffWinsOverIdle() {
        coordinator.setReason(.idle)
        coordinator.setReason(.screenOff)
        XCTAssertEqual(coordinator.decision, .teardown)
        XCTAssertEqual(coordinator.strongestReason, .screenOff)
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
        XCTAssertNil(coordinator.strongestReason)
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

    // MARK: - Manual precedence

    func testManualBlocksWeakerReasonsFromResuming() {
        coordinator.setReason(.manual)
        coordinator.setReason(.occlusion)
        XCTAssertEqual(coordinator.decision, .pause)

        coordinator.clearReason(.occlusion)
        XCTAssertEqual(coordinator.decision, .pause)
        XCTAssertEqual(coordinator.strongestReason, .manual)

        coordinator.setReason(.power)
        coordinator.clearReason(.power)
        XCTAssertEqual(coordinator.decision, .pause)
        XCTAssertEqual(coordinator.strongestReason, .manual)

        coordinator.clearReason(.manual)
        XCTAssertEqual(coordinator.decision, .play)
    }

    func testManualSurvivesSleepBeingCleared() {
        coordinator.setReason(.manual)
        coordinator.setReason(.sleep)
        XCTAssertEqual(coordinator.decision, .teardown)

        coordinator.clearReason(.sleep)
        XCTAssertEqual(coordinator.decision, .pause)
        XCTAssertEqual(coordinator.strongestReason, .manual)
    }

    // MARK: - Delegate notifications

    func testDelegateNotifiedOnSetAndClearWithDecisionAndReason() {
        coordinator.setReason(.occlusion)
        coordinator.clearReason(.occlusion)

        XCTAssertEqual(recorder.records.count, 2)
        XCTAssertEqual(recorder.records[0].decision, .pause)
        XCTAssertEqual(recorder.records[0].reason, .occlusion)
        XCTAssertEqual(recorder.records[1].decision, .play)
        XCTAssertNil(recorder.records[1].reason)
    }

    func testSettingSameReasonAgainDoesNotNotify() {
        coordinator.setReason(.power)
        coordinator.setReason(.power)
        XCTAssertEqual(recorder.records.count, 1)
    }

    func testClearingInactiveReasonDoesNotNotify() {
        coordinator.clearReason(.idle)
        XCTAssertEqual(recorder.records.count, 0)
    }

    func testClearAllWithNoReasonsDoesNotNotify() {
        coordinator.clearAllReasons()
        XCTAssertEqual(recorder.records.count, 0)
    }
}
