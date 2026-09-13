import Foundation

/// Pure predicate for the combined energy-pause condition driving the
/// coordinator's `.power` reason: low battery (≤ threshold), Low Power Mode
/// enabled, or thermal pressure ≥ serious.
/// Foundation-only so the SPM test target can compile it (PowerManager.swift
/// imports IOKit and cannot join that target).
enum PowerPausePolicy {
    static let lowBatteryThresholdPercent = 20

    static func shouldPause(
        batteryPercentRemaining: Int?,
        isLowPowerModeEnabled: Bool,
        thermalState: ProcessInfo.ThermalState
    ) -> Bool {
        if let pct = batteryPercentRemaining,
           pct <= lowBatteryThresholdPercent {
            return true
        }
        return isLowPowerModeEnabled
            || thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
    }
}
