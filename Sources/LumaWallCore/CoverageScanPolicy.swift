import Foundation

/// Decides when the window list must be fetched and analysed again.
public enum CoverageScanPolicy {
    /// Quiet period that merges a burst of workspace notifications into one scan.
    public static let debounce: TimeInterval = 0.25

    /// Whether the 30 s fallback timer needs a fresh scan. Coverage only
    /// changes playback when someone can see the desktop and a wallpaper plays.
    public static func fallbackScanNeeded(
        userPausedEverywhere: Bool,
        displaysAsleep: Bool,
        sessionLocked: Bool,
        hasAssignedWallpaper: Bool
    ) -> Bool {
        hasAssignedWallpaper && !userPausedEverywhere && !displaysAsleep && !sessionLocked
    }

    public enum PowerChange: Equatable, Sendable {
        case none
        /// Only the charge level moved.
        case percentOnly
        /// AC and battery swapped; automations and the menu-bar rule depend on it.
        case sourceSwitched
    }

    public static func powerChange(from old: PowerStatus, to new: PowerStatus) -> PowerChange {
        if old.isOnBattery != new.isOnBattery { return .sourceSwitched }
        return old.percent != new.percent ? .percentOnly : .none
    }
}
