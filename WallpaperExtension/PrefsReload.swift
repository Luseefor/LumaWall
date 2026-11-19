import Foundation

/// The preferences the app writes for the extension (`lumawall-prefs.json`).
/// Optional fields were added after the first release; a file written by an
/// older app leaves them nil.
struct WallpaperPrefsFile: Codable, Equatable {
    var userPaused = false
    var alwaysPauseDesktop = false
    var pauseWhenOccluded = false
    var desktopOccluded = false
    var occludedDisplays: Set<UInt32>?
    var fullscreenDisplays: Set<UInt32>?
    var pausedDisplays: Set<UInt32>?
    var screenSaverIsOurs: Bool?
    var powerProfile: String?
}

/// What a re-read of the prefs file calls for.
enum PrefsReload: Equatable {
    /// Nothing the extension reads changed.
    case none
    /// Recompute every renderer's policy. `refreshPower`: read battery and
    /// brightness first, because a new power profile evaluated against a stale
    /// reading looks like it did nothing.
    case applyPolicies(refreshPower: Bool)

    static func between(_ old: WallpaperPrefsFile, _ new: WallpaperPrefsFile) -> PrefsReload {
        guard old != new else { return .none }
        return .applyPolicies(refreshPower: old.powerProfile != new.powerProfile)
    }
}

/// Collapses a burst of prefs notifications into one reload. The first
/// request schedules it and later ones ride along until it starts; it reads
/// the file as it runs, so it sees the last write.
struct ReloadCoalescer {
    private(set) var scheduled = false

    /// True when the caller should schedule a reload.
    mutating func request() -> Bool {
        guard !scheduled else { return false }
        scheduled = true
        return true
    }

    /// The reload is starting; a request from now on schedules another.
    mutating func begin() {
        scheduled = false
    }
}
