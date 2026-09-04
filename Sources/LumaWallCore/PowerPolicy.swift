import CoreGraphics
import Foundation

/// Playback tiers, ordered from most to least work. Semantics are shared by
/// both hosts and must stay unified:
/// - `.full` / `.reduced` / `.minimal`: motion plays (reduced/minimal cap the
///   decode budget; the native host additionally picks lower-res variants).
/// - `.staticFrame`: no motion; the overlay shows the poster still.
/// - `.paused`: no motion; holds the last decoded frame for instant resume.
public enum PlaybackTier: Int, Comparable, Codable, Sendable {
    case full
    case reduced
    case minimal
    case staticFrame
    case paused

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Shared numeric thresholds for playback policy decisions.
///
/// The wallpaper extension (`WallpaperExtension/PlaybackPolicy.swift`) cannot
/// import LumaWallCore, so it mirrors these values. Keep them in sync —
/// `PowerPolicyTests` pins the Core side; match any change on the extension side.
/// Drift here is what made pause/resume flap (e.g. 0.92 occlusion pausing on
/// maximized windows) or diverge per-host (batterySaver hiding overlay video
/// while native kept playing).
public enum PlaybackPolicyThresholds: Sendable {
    /// Below this battery %, always pause regardless of profile.
    public static let batteryCritical = 10
    /// Below this battery % on automatic, drop to minimal.
    public static let batteryLow = 20
    /// A display counts as occluded only at near-total coverage. Lower values
    /// (e.g. 0.92) fire on maximized windows with menu bar/dock visible (~96%).
    public static let occlusionCovered: CGFloat = 0.985
    /// A single window owns the display only at full coverage + matching size.
    public static let fullscreenCoverage: CGFloat = 0.99
    /// Width/height tolerance (points) for fullscreen size match.
    public static let fullscreenWidthTolerance: CGFloat = 2
    public static let fullscreenHeightTolerance: CGFloat = 4
}

/// Capability protocol for playback-policy resolution.
///
/// Lets the app resolve tiers through an injectable decision-maker (protocol-first:
/// test with a stub instead of toggling real power/thermal state), while the
/// concrete `PlaybackPolicy` below remains the production implementation.
public protocol PlaybackPolicyDeciding: Sendable {
    /// Resolve the most restrictive applicable tier for the given conditions.
    static func resolve(_ state: PlaybackConditions) -> PlaybackTier
}

public enum PowerProfile: String, Codable, CaseIterable, Sendable {
    case automatic
    case fullQuality
    case batterySaver
    case staticOnBattery
}

public struct PlaybackConditions: Sendable {
    public var profile: PowerProfile
    public var isOnBattery: Bool
    public var batteryPercent: Int
    public var lowPowerMode: Bool
    public var thermalState: ProcessInfo.ThermalState
    public var displayIsAsleep: Bool
    public var sessionIsLocked: Bool
    public var displayIsObscured: Bool
    public var userPaused: Bool
    public var hideDesktopVideo: Bool
    /// Native host can keep live video on the lock screen while the desktop stays still.
    public var allowLiveOnLock: Bool
    public var gameModeActive: Bool
    public var reduceMotion: Bool

    public init(
        profile: PowerProfile = .automatic,
        isOnBattery: Bool = false,
        batteryPercent: Int = 100,
        lowPowerMode: Bool = false,
        thermalState: ProcessInfo.ThermalState = .nominal,
        displayIsAsleep: Bool = false,
        sessionIsLocked: Bool = false,
        displayIsObscured: Bool = false,
        userPaused: Bool = false,
        hideDesktopVideo: Bool = false,
        allowLiveOnLock: Bool = false,
        gameModeActive: Bool = false,
        reduceMotion: Bool = false
    ) {
        self.profile = profile
        self.isOnBattery = isOnBattery
        self.batteryPercent = batteryPercent
        self.lowPowerMode = lowPowerMode
        self.thermalState = thermalState
        self.displayIsAsleep = displayIsAsleep
        self.sessionIsLocked = sessionIsLocked
        self.displayIsObscured = displayIsObscured
        self.userPaused = userPaused
        self.hideDesktopVideo = hideDesktopVideo
        self.allowLiveOnLock = allowLiveOnLock
        self.gameModeActive = gameModeActive
        self.reduceMotion = reduceMotion
    }
}

public enum PlaybackPolicy: PlaybackPolicyDeciding {
    public static func resolve(_ state: PlaybackConditions) -> PlaybackTier {
        if state.userPaused || state.displayIsAsleep || state.displayIsObscured || state.gameModeActive {
            return .paused
        }
        if state.reduceMotion { return .staticFrame }
        if state.sessionIsLocked {
            if state.allowLiveOnLock, state.hideDesktopVideo { return .full }
            return .paused
        }
        if state.hideDesktopVideo { return .staticFrame }
        if state.thermalState == .critical || state.batteryPercent < PlaybackPolicyThresholds.batteryCritical { return .paused }
        if state.thermalState == .serious { return .minimal }
        if state.isOnBattery {
            switch state.profile {
            case .fullQuality: break
            case .batterySaver: return .minimal
            case .staticOnBattery: return .staticFrame
            case .automatic:
                if state.lowPowerMode || state.batteryPercent < PlaybackPolicyThresholds.batteryLow { return .minimal }
                return .reduced
            }
        }
        if state.lowPowerMode { return .minimal }
        if state.thermalState == .fair { return .reduced }
        return .full
    }
}
