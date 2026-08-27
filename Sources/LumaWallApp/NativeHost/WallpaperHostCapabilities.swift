import Darwin
import Foundation

enum WallpaperHostMode: String, Sendable {
    case native
    case overlay
}

enum WallpaperHostCapabilities {
    static let extensionBundleID = "app.lumawall.personal.wallpaper"
    static let frameworkPath =
        "/System/Library/PrivateFrameworks/WallpaperExtensionKit.framework/WallpaperExtensionKit"

    static var preferredMode: WallpaperHostMode {
        if UserDefaults.standard.bool(forKey: "lumawall.forceOverlay") {
            return .overlay
        }
        guard #available(macOS 26, *) else { return .overlay }
        // The framework binary lives in the dyld shared cache, not on disk, so
        // a file-existence check always fails. Preflight loadability instead.
        guard dlopen_preflight(frameworkPath) else { return .overlay }
        guard hasEmbeddedWallpaperExtension || UserDefaults.standard.bool(forKey: "lumawall.forceNative") else {
            return .overlay
        }
        return .native
    }

    static var hasEmbeddedWallpaperExtension: Bool {
        let fm = FileManager.default
        let roots = [
            Bundle.main.builtInPlugInsURL,
            Bundle.main.bundleURL.appendingPathComponent("Contents/Extensions", isDirectory: true)
        ].compactMap { $0 }
        for root in roots {
            guard let contents = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil
            ) else { continue }
            if contents.contains(where: { url in
                url.pathExtension == "appex"
                    && (Bundle(url: url)?.bundleIdentifier == extensionBundleID
                        || url.deletingPathExtension().lastPathComponent.contains("Wallpaper"))
            }) {
                return true
            }
        }
        return false
    }

    static var extensionDocumentsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Containers/\(extensionBundleID)/Data/Documents",
                isDirectory: true
            )
    }
}
