import Foundation

@MainActor
enum NativeWallpaperPrefsBridge {
    private static var prefsURL: URL {
        WallpaperHostCapabilities.extensionDocumentsURL.appendingPathComponent("lumawall-prefs.json")
    }

    private struct PrefsFile: Codable, Equatable {
        var userPaused: Bool
        var alwaysPauseDesktop: Bool
        var pauseWhenOccluded: Bool
        var desktopOccluded: Bool
        var occludedDisplays: Set<UInt32>?
        var fullscreenDisplays: Set<UInt32>?
        var pausedDisplays: Set<UInt32>?
        var screenSaverIsOurs: Bool?
        var powerProfile: String?
    }

    /// Last values actually written. Policy re-evaluates on a 30s timer plus
    /// every workspace event; without coalescing, every tick rewrites the file
    /// and pings the extension even when nothing changed.
    private static var lastWritten: PrefsFile?

    static func write(
        userPaused: Bool,
        pauseWhenOccluded: Bool,
        alwaysPauseDesktop: Bool,
        pausedDisplays: Set<UInt32>,
        occludedDisplays: Set<UInt32> = [],
        fullscreenDisplays: Set<UInt32> = [],
        desktopOccluded: Bool = false,
        screenSaverIsOurs: Bool? = nil,
        powerProfile: String? = nil
    ) {
        let fm = FileManager.default
        try? fm.createDirectory(
            at: WallpaperHostCapabilities.extensionDocumentsURL,
            withIntermediateDirectories: true
        )
        let file = PrefsFile(
            userPaused: userPaused,
            alwaysPauseDesktop: alwaysPauseDesktop,
            pauseWhenOccluded: pauseWhenOccluded,
            desktopOccluded: desktopOccluded,
            occludedDisplays: occludedDisplays,
            fullscreenDisplays: fullscreenDisplays,
            pausedDisplays: pausedDisplays,
            screenSaverIsOurs: screenSaverIsOurs,
            powerProfile: powerProfile
        )
        guard let data = try? JSONEncoder().encode(file) else { return }
        // The extension reloads this file at init, so skipping an identical
        // rewrite loses nothing — and spares a Darwin-notify round trip plus
        // a full policy recompute on every unchanged evaluation.
        guard file != lastWritten else { return }
        try? data.write(to: prefsURL, options: .atomic)
        lastWritten = file
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(
            center,
            CFNotificationName("app.lumawall.personal.prefsChanged" as CFString),
            nil,
            nil,
            true
        )
    }
}
