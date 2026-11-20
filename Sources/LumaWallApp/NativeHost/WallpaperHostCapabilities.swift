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

    /// The host to use now. With native mode off this never probes the
    /// system, so nothing native runs.
    static func preferredMode(nativeModeEnabled: Bool) -> WallpaperHostMode {
        mode(
            nativeModeEnabled: nativeModeEnabled,
            forceOverlay: UserDefaults.standard.bool(forKey: "lumawall.forceOverlay"),
            nativeAvailable: { nativeHostIsAvailable }
        )
    }

    static func mode(
        nativeModeEnabled: Bool,
        forceOverlay: Bool,
        nativeAvailable: () -> Bool
    ) -> WallpaperHostMode {
        guard nativeModeEnabled, !forceOverlay, nativeAvailable() else { return .overlay }
        return .native
    }

    private static var nativeHostIsAvailable: Bool {
        guard #available(macOS 26, *) else { return false }
        // The framework binary lives in the dyld shared cache, not on disk, so
        // a file-existence check always fails. Preflight loadability instead.
        guard dlopen_preflight(frameworkPath) else { return false }
        guard hasEmbeddedWallpaperExtension || UserDefaults.standard.bool(forKey: "lumawall.forceNative") else {
            return false
        }
        return nativeStorageIsAccessible()
    }

    static func nativeStorageIsAccessible(at url: URL = extensionDocumentsURL) -> Bool {
        do {
            _ = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            return true
        } catch {
            // A missing container can be created on first deployment. A protected
            // container must use overlay playback instead of requesting broad disk access.
            return !isPermissionError(error)
        }
    }

    static func isPermissionError(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain,
            [CocoaError.fileReadNoPermission.rawValue, CocoaError.fileWriteNoPermission.rawValue].contains(error.code)
        {
            return true
        }
        if error.domain == NSPOSIXErrorDomain, error.code == Int(EPERM) || error.code == Int(EACCES) {
            return true
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isPermissionError(underlying)
        }
        return false
    }

    static var hasEmbeddedWallpaperExtension: Bool {
        let fm = FileManager.default
        let roots = [
            Bundle.main.builtInPlugInsURL,
            Bundle.main.bundleURL.appendingPathComponent("Contents/Extensions", isDirectory: true),
        ].compactMap { $0 }
        for root in roots {
            guard
                let contents = try? fm.contentsOfDirectory(
                    at: root,
                    includingPropertiesForKeys: nil
                )
            else { continue }
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
