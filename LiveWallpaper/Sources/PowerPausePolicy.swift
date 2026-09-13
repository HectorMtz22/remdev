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
        // ThermalState exposes no Comparable conformance in the SDK, so
        // enumerate the pressure levels at or above serious.
        return isLowPowerModeEnabled
            || thermalState == .serious || thermalState == .critical
    }
}
