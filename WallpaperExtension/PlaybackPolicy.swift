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
    /// A tier and the condition that set it.
    struct Decision: Equatable {
        let tier: PlaybackPolicy
        /// Nil at Full.
        let reason: PlaybackStatusReason?
    }

    static let brightnessPauseThreshold: Float = 0.05

    /// Mirrors of `LumaWallCore.PlaybackPolicyThresholds` (the extension cannot
    /// import LumaWallCore). Keep in sync. Drift reintroduces per-host
    /// pause/resume divergence.
    ///
    /// Tier mapping note: this host has 4 tiers (no `.staticFrame`); the app
    /// host has 5. `.minimal` plays motion on both hosts (reduced budget here,
    /// reduced budget + lower-res variant selection). `staticOnBattery` maps to
    /// `.paused` here (hold last frame) vs `.staticFrame` in-app (show poster).
    /// Both are still UX; do not "fix" one side without updating the other + tests.
    /// Power profiles are manual overrides and apply on any power source (mirrors
    /// `LumaWallCore.PlaybackPolicy`): gating them on `isOnBattery` left the menu
    /// dead on AC power / battery-less desktops ("nothing changes").
    /// `fullQuality` also skips the Low Power Mode and fair-thermal
    /// downgrades; hard protections (pauses, serious/critical thermal) still win.
    /// `staticOnBattery` accumulates past serious thermal to `.paused` here,
    /// matching Core where Static returns before the serious-thermal downgrade.
    static let batteryCriticalLevel = 10
    static let batteryLowLevel = 20

    /// Evaluate all conditions and return the most restrictive applicable policy.
    ///
    /// `alwaysPauseDesktop`: when true, wallpaper only plays on the lock screen.
    /// On the desktop (unlocked), it pauses with a ramp animation.
    ///
    /// `screenSaverIsOurs`: a LumaWall choice is the active screensaver, so idle
    /// presentation means WE are what's on screen. Play full, like the lock screen.
    /// Without it, idle means a foreign screensaver covers us, so the video pauses.
    ///
    /// Lock screen never reduces FPS by itself. Only power/thermal conditions do.
    static func decide(
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
    ) -> Decision {
        var worst: PlaybackPolicy = .full
        var reason: PlaybackStatusReason?
        // The first condition to reach a tier names it, so the reason is the
        // one behind the tier the display plays, in the order checked below.
        func raise(_ tier: PlaybackPolicy, _ why: PlaybackStatusReason) {
            guard tier > worst else { return }
            worst = tier
            reason = why
        }

        // Presentations where the wallpaper fills the screen with nothing over it:
        // the lock screen, and the screensaver when the screensaver is ours.
        let fullScreenPresentation =
            presentationMode == "locked"
            || (presentationMode == "idle" && screenSaverIsOurs)

        // --- paused tier ---
        if userPaused { raise(.paused, .userPause) }
        if thermalState == .critical { raise(.paused, .thermal) }
        if batteryLevel < Self.batteryCriticalLevel { raise(.paused, .batteryCritical) }
        if activityState.contains("suspended") { raise(.paused, .suspended) }
        if presentationMode == "idle", !screenSaverIsOurs { raise(.paused, .screensaver) }
        if isGameModeActive { raise(.paused, .gameMode) }
        // User dimmed the backlight to ~zero. The display is technically still
        // "awake" so `screensDidSleep` doesn't fire and the WallpaperAgent never
        // switches to "idle", but the user can't see any of it.
        if displayBrightness < Self.brightnessPauseThreshold {
            raise(.paused, .displayDimmed)
        }
        // Desktop occlusion is irrelevant on full-screen presentations. The
        // wallpaper is fully visible there regardless of desktop window state.
        if pauseWhenOccluded, desktopOccluded, !fullScreenPresentation { raise(.paused, .covered) }
        // A fullscreen app owning the display pauses unconditionally: the wallpaper
        // is invisible (or a menu bar sliver) and the app wants the hardware.
        // Fullscreen pause also catches games Game Mode misses. gamepolicyd never recognizes Wine games.
        if displayHasFullscreenApp, !fullScreenPresentation { raise(.paused, .fullscreenApp) }
        if alwaysPauseDesktop, !fullScreenPresentation { raise(.paused, .desktopPaused) }

        // --- minimal tier ---
        if thermalState == .serious { raise(.minimal, .thermal) }
        // User-selected battery behavior. Thermal, visibility, sleep, and Game
        // Mode protections above always remain in force, even in Full Quality.
        // Profiles are manual overrides: they apply on any power source so the
        // menu stays usable on AC / battery-less desktops. `fullQuality` skips
        // the battery, Low Power, and fair-thermal downgrades below.
        let forcesFullQuality = powerProfile == "fullQuality"
        switch powerProfile {
        case "batterySaver":
            raise(.minimal, .batteryTier)
        case "staticOnBattery":
            raise(.paused, .batteryStatic)
        case "fullQuality":
            break
        default:
            if isOnBattery {
                if batteryLevel < Self.batteryLowLevel {
                    raise(.minimal, .batteryTier)
                } else {
                    raise(.reduced, .batteryTier)
                }
            }
        }
        if !forcesFullQuality, isLowPowerModeEnabled { raise(.minimal, .lowPowerMode) }

        // --- reduced tier ---
        if !forcesFullQuality, thermalState == .fair { raise(.reduced, .thermal) }

        return Decision(tier: worst, reason: reason)
    }

    /// `decide` without the reason.
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
        decide(
            presentationMode: presentationMode,
            activityState: activityState,
            userPaused: userPaused,
            alwaysPauseDesktop: alwaysPauseDesktop,
            pauseWhenOccluded: pauseWhenOccluded,
            desktopOccluded: desktopOccluded,
            displayHasFullscreenApp: displayHasFullscreenApp,
            screenSaverIsOurs: screenSaverIsOurs,
            thermalState: thermalState,
            isOnBattery: isOnBattery,
            batteryLevel: batteryLevel,
            isGameModeActive: isGameModeActive,
            isLowPowerModeEnabled: isLowPowerModeEnabled,
            displayBrightness: displayBrightness,
            powerProfile: powerProfile,
        ).tier
    }

    /// The tier for a preview surface (the System Settings picker), which the
    /// user is looking at whatever the desktop shows. The desktop rules
    /// (presentation, occlusion, fullscreen apps, the desktop and per-display
    /// pauses) don't reach it. The hard pauses (user pause, critical thermal
    /// or battery, Game Mode, zero brightness) and the power tiers do, and
    /// Full picks the copy that fits the preview's viewport. Display sleep
    /// reaches every renderer separately.
    static func preview(
        userPaused: Bool,
        thermalState: ProcessInfo.ThermalState,
        isOnBattery: Bool,
        batteryLevel: Int,
        isGameModeActive: Bool,
        isLowPowerModeEnabled: Bool = false,
        displayBrightness: Float = 1.0,
        powerProfile: String = "automatic",
    ) -> PlaybackPolicy {
        compute(
            presentationMode: "default",
            activityState: "active",
            userPaused: userPaused,
            alwaysPauseDesktop: false,
            pauseWhenOccluded: false,
            desktopOccluded: false,
            screenSaverIsOurs: false,
            thermalState: thermalState,
            isOnBattery: isOnBattery,
            batteryLevel: batteryLevel,
            isGameModeActive: isGameModeActive,
            isLowPowerModeEnabled: isLowPowerModeEnabled,
            displayBrightness: displayBrightness,
            powerProfile: powerProfile,
        )
    }
}
