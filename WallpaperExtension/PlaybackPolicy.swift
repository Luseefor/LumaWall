import Foundation

/// Central decision-maker for wallpaper playback behavior.
/// Replaces scattered shouldPause boolean checks with a graduated policy system.
enum PlaybackPolicy: Int, Comparable {
    case full = 0
    case reduced = 1
    case minimal = 2
    case paused = 3

    static func < (lhs: PlaybackPolicy, rhs: PlaybackPolicy) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Below this brightness, the screen is effectively invisible to the user
    /// even though `screensDidSleepNotification` hasn't fired. We treat this
    /// as paused so the renderer stops burning battery.
    static let brightnessPauseThreshold: Float = 0.05

    /// Mirrors of `LumaWallCore.PlaybackPolicyThresholds` (the extension cannot
    /// import LumaWallCore). Keep in sync — drift reintroduces per-host
    /// pause/resume divergence.
    ///
    /// Tier mapping note: this host has 4 tiers (no `.staticFrame`); the app
    /// host has 5. `.minimal` plays motion on both hosts (reduced budget here,
    /// reduced budget + lower-res variant selection). `staticOnBattery` maps to
    /// `.paused` here (hold last frame) vs `.staticFrame` in-app (show poster).
    /// Both are still UX; do not "fix" one side without updating the other + tests.
    static let batteryCriticalLevel = 10
    static let batteryLowLevel = 20

    /// Evaluate all conditions and return the most restrictive applicable policy.
    ///
    /// `alwaysPauseDesktop`: when true, wallpaper only plays on the lock screen.
    /// On the desktop (unlocked), it pauses with a ramp animation.
    ///
    /// `screenSaverIsOurs`: a LumaWall choice is the active screensaver, so idle
    /// presentation means WE are what's on screen — play full, like the lock screen.
    /// Without it, idle means a foreign screensaver covers us — pause.
    ///
    /// Lock screen never reduces FPS by itself — only power/thermal conditions do.
    static func compute(
        presentationMode: String,
        activityState: String,
        userPaused: Bool,
        alwaysPauseDesktop: Bool,
        pauseWhenOccluded: Bool,
        desktopOccluded: Bool,
        displayHasFullscreenApp: Bool = false,
        screenSaverIsOurs: Bool,
        thermalState: ProcessInfo.ThermalState,
        isOnBattery: Bool,
        batteryLevel: Int,
        isGameModeActive: Bool,
        isLowPowerModeEnabled: Bool = false,
        displayBrightness: Float = 1.0,
        powerProfile: String = "automatic",
    ) -> PlaybackPolicy {
        var worst: PlaybackPolicy = .full

        // Presentations where the wallpaper fills the screen with nothing over it:
        // the lock screen, and the screensaver when the screensaver is ours.
        let fullScreenPresentation = presentationMode == "locked"
            || (presentationMode == "idle" && screenSaverIsOurs)

        // --- paused tier ---
        if userPaused { worst = max(worst, .paused) }
        if thermalState == .critical { worst = max(worst, .paused) }
        if batteryLevel < Self.batteryCriticalLevel { worst = max(worst, .paused) }
        if activityState.contains("suspended") { worst = max(worst, .paused) }
        if presentationMode == "idle", !screenSaverIsOurs { worst = max(worst, .paused) }
        if isGameModeActive { worst = max(worst, .paused) }
        // User dimmed the backlight to ~zero. The display is technically still
        // "awake" so `screensDidSleep` doesn't fire and the WallpaperAgent never
        // switches to "idle", but the user can't see any of it.
        if displayBrightness < Self.brightnessPauseThreshold {
            worst = max(worst, .paused)
        }
        // Desktop occlusion is irrelevant on full-screen presentations — the
        // wallpaper is fully visible there regardless of desktop window state.
        if pauseWhenOccluded, desktopOccluded, !fullScreenPresentation { worst = max(worst, .paused) }
        // A fullscreen app owning the display pauses unconditionally: the wallpaper
        // is invisible (or a menu bar sliver) and the app wants the hardware.
        // Catches what Game Mode can't — gamepolicyd never recognizes Wine games.
        if displayHasFullscreenApp, !fullScreenPresentation { worst = max(worst, .paused) }
        if alwaysPauseDesktop, !fullScreenPresentation { worst = max(worst, .paused) }

        // --- minimal tier ---
        if thermalState == .serious { worst = max(worst, .minimal) }
        // User-selected battery behavior. Thermal, visibility, sleep, and Game
        // Mode protections above always remain in force, even in Full Quality.
        if isOnBattery {
            switch powerProfile {
            case "fullQuality":
                break
            case "batterySaver":
                worst = max(worst, .minimal)
            case "staticOnBattery":
                worst = max(worst, .paused)
            default:
                if batteryLevel < Self.batteryLowLevel {
                    worst = max(worst, .minimal)
                } else {
                    worst = max(worst, .reduced)
                }
            }
        }
        if isLowPowerModeEnabled { worst = max(worst, .minimal) }

        // --- reduced tier ---
        if thermalState == .fair { worst = max(worst, .reduced) }

        return worst
    }

}
