import Foundation

@MainActor
enum NativeWallpaperPrefsBridge {
    private static var prefsURL: URL {
        WallpaperHostCapabilities.extensionDocumentsURL.appendingPathComponent("lumawall-prefs.json")
    }

    private struct PrefsFile: Codable {
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
        try? data.write(to: prefsURL, options: .atomic)
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
