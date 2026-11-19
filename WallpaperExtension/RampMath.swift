import Foundation

/// The pure math of the playback-rate ramps, separated from `VideoRenderer`'s
/// timers so the continuity invariants can be tested: a ramp starts at the live
/// rate, ends exactly on its target, and its duration shrinks in proportion to
/// the distance it still has to travel.
enum RampMath {
    /// 60 Hz. The timebase interpolates between rate changes, so stepping
    /// faster only adds wakeups nobody sees.
    static let stepInterval: TimeInterval = 1.0 / 60.0
    /// Seconds each step may slip so the system can coalesce its wakeups.
    static let stepLeeway: TimeInterval = 0.004

    /// Lock reveal: playback reaches full speed while the reveal is on screen.
    static let rampUpDuration: TimeInterval = 2.0
    /// Unlock: the ~6 s deceleration of Apple's built-in wallpapers.
    static let rampDownDuration: TimeInterval = 6.0
    /// Unlock on battery: the ramp keeps decoding, so keep it short.
    static let batteryRampDownDuration: TimeInterval = 2.0

    /// Seconds a full-distance ramp toward `target` (0 or 1) takes.
    static func fullDuration(toward target: Double, onBattery: Bool) -> TimeInterval {
        if target > 0 { return rampUpDuration }
        return onBattery ? batteryRampDownDuration : rampDownDuration
    }

    /// Whether a pause must stop decoding at once instead of easing out:
    /// critical thermal, or an activity the agent suspended (the process may
    /// be about to sleep). Display sleep is handled by the lifecycle's gate.
    static func cutsRampDown(thermalState: ProcessInfo.ThermalState, activityState: String) -> Bool {
        thermalState == .critical || activityState.contains("suspended")
    }

    /// Ease-in-out cubic: smooth acceleration then deceleration.
    /// t in [0, 1] → output in [0, 1].
    static func easeInOut(_ t: Double) -> Double {
        t < 0.5
            ? 4.0 * t * t * t
            : 1.0 - pow(-2.0 * t + 2.0, 3) / 2.0
    }

    /// Timer steps for a ramp covering `distance` (in rate units, 0…1) at
    /// `stepInterval`, scaled down from the full-distance duration.
    static func steps(distance: Double, fullDuration: TimeInterval, stepInterval: TimeInterval) -> Int {
        max(1, Int(fullDuration * distance / stepInterval))
    }

    /// The eased rate at `progress` (0…1) of a ramp from `start` to `target`.
    static func rate(from start: Double, to target: Double, progress: Double) -> Double {
        start + (target - start) * easeInOut(min(max(progress, 0), 1))
    }
}
