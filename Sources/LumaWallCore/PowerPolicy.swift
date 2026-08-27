import Foundation

public enum PlaybackTier: Int, Comparable, Codable, Sendable {
    case full
    case reduced
    case minimal
    case staticFrame
    case paused

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
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

public enum PlaybackPolicy {
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
        if state.thermalState == .critical || state.batteryPercent < 10 { return .paused }
        if state.thermalState == .serious { return .minimal }
        if state.isOnBattery {
            switch state.profile {
            case .fullQuality: break
            case .batterySaver: return .minimal
            case .staticOnBattery: return .staticFrame
            case .automatic:
                if state.lowPowerMode || state.batteryPercent < 20 { return .minimal }
                return .reduced
            }
        }
        if state.lowPowerMode { return .minimal }
        if state.thermalState == .fair { return .reduced }
        return .full
    }
}
