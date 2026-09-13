import XCTest
import Foundation
@testable import PlaybackCoordinator

final class PowerPausePolicyTests: XCTestCase {
    private func shouldPause(
        battery: Int?,
        lowPowerMode: Bool,
        thermal: ProcessInfo.ThermalState
    ) -> Bool {
        PowerPausePolicy.shouldPause(
            batteryPercentRemaining: battery,
            isLowPowerModeEnabled: lowPowerMode,
            thermalState: thermal
        )
    }

    func testNoSignalsDoesNotPause() {
        XCTAssertFalse(shouldPause(battery: nil, lowPowerMode: false, thermal: .nominal))
    }

    func testUnknownBatteryDoesNotPause() {
        XCTAssertFalse(shouldPause(battery: nil, lowPowerMode: false, thermal: .nominal))
        XCTAssertFalse(shouldPause(battery: 100, lowPowerMode: false, thermal: .nominal))
    }

    func testLowBatteryAtThresholdPauses() {
        XCTAssertTrue(shouldPause(battery: 20, lowPowerMode: false, thermal: .nominal))
    }

    func testBatteryJustAboveThresholdDoesNotPause() {
        XCTAssertFalse(shouldPause(battery: 21, lowPowerMode: false, thermal: .nominal))
    }

    func testLowPowerModePauses() {
        XCTAssertTrue(shouldPause(battery: 100, lowPowerMode: true, thermal: .nominal))
    }

    func testSeriousThermalPauses() {
        XCTAssertTrue(shouldPause(battery: 100, lowPowerMode: false, thermal: .serious))
    }

    func testCriticalThermalPauses() {
        XCTAssertTrue(shouldPause(battery: 100, lowPowerMode: false, thermal: .critical))
    }

    func testFairThermalDoesNotPause() {
        XCTAssertFalse(shouldPause(battery: 100, lowPowerMode: false, thermal: .fair))
    }

    func testAnySingleSignalPauses() {
        XCTAssertTrue(shouldPause(battery: 10, lowPowerMode: false, thermal: .nominal)
                      || shouldPause(battery: nil, lowPowerMode: true, thermal: .nominal)
                      || shouldPause(battery: nil, lowPowerMode: false, thermal: .critical))
    }

    func testCombinedSignalsPause() {
        XCTAssertTrue(shouldPause(battery: 5, lowPowerMode: true, thermal: .critical))
    }
}
