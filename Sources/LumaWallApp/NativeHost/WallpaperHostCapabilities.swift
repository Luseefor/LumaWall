import Foundation

enum WallpaperHostMode: String, Sendable {
    case native
    case overlay
}

enum WallpaperHostCapabilities {
    static let extensionBundleID = "app.lumawall.personal.wallpaper"
    static let frameworkPath =
        "/System/Library/PrivateFrameworks/WallpaperExtensionKit.framework/WallpaperExtensionKit"

    /// Native WallpaperExtensionKit host when the OS and packaged extension both allow it.
    /// Lower macOS and SwiftPM/overlay-only builds keep the desktop video overlay.
    static var preferredMode: WallpaperHostMode {
        if UserDefaults.standard.bool(forKey: "lumawall.forceOverlay") {
            return .overlay
        }
        guard #available(macOS 26, *) else { return .overlay }
        guard FileManager.default.fileExists(atPath: frameworkPath) else { return .overlay }
        guard hasEmbeddedWallpaperExtension || UserDefaults.standard.bool(forKey: "lumawall.forceNative") else {
            return .overlay
        }
        return .native
    }

    static var hasEmbeddedWallpaperExtension: Bool {
        guard let plugins = Bundle.main.builtInPlugInsURL else { return false }
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: plugins,
            includingPropertiesForKeys: nil
        ) else { return false }
        return contents.contains { url in
            url.pathExtension == "appex"
                && (Bundle(url: url)?.bundleIdentifier == extensionBundleID
                    || url.deletingPathExtension().lastPathComponent.contains("Wallpaper"))
        }
    }

    static var extensionDocumentsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Containers/\(extensionBundleID)/Data/Documents",
                isDirectory: true
            )
    }
}
