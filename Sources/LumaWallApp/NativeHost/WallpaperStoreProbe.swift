import CryptoKit
import Foundation

@MainActor
enum WallpaperStoreProbe {
    private static var defaultStoreURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
    }

    /// Times the store was actually read and parsed. Tests use it to check the cache.
    private(set) static var parseCount = 0

    private struct Stamp: Equatable {
        var url: URL
        var size: Int
        var digest: Data
    }

    private static var cached: (stamp: Stamp, isOurs: Bool)?

    /// True when any Idle/screensaver choice is owned by the LumaWall wallpaper extension.
    ///
    /// The store lists every Space and runs to hundreds of KB. Playback policy
    /// asks on every power and workspace event, so the parsed answer is reused
    /// while the file's size and SHA-256 digest match (avoiding file-timestamp
    /// reads outside the app container).
    static func screenSaverIsOurs(storeURL: URL? = nil) -> Bool {
        let url = storeURL ?? defaultStoreURL
        guard let data = try? Data(contentsOf: url) else {
            cached = nil
            return false
        }
        let stamp = Stamp(url: url, size: data.count, digest: Data(SHA256.hash(data: data)))
        if let cached, cached.stamp == stamp { return cached.isOurs }
        parseCount += 1
        // Cache only a successful parse: a half-written plist must be retried.
        guard let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        else {
            cached = nil
            return false
        }
        let isOurs = containsOurChoice(root)
        cached = (stamp, isOurs)
        return isOurs
    }

    /// Display UUIDs where some Space shows a wallpaper that isn't
    /// LumaWall's. Read only when the health check suspects a display.
    /// Nil when the store can't be read, so nothing is known.
    static func displaysShowingOthers(storeURL: URL? = nil) -> Set<String>? {
        guard let data = try? Data(contentsOf: storeURL ?? defaultStoreURL),
            let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? NSDictionary
        else { return nil }
        return NativeWallpaperAssignmentStore.displaysShowingOthers(in: root)
    }

    private static func containsOurChoice(_ root: [String: Any]) -> Bool {
        let provider = WallpaperHostCapabilities.extensionBundleID
        if hasOurChoice(in: root["Idle"], provider: provider) { return true }
        if let spaces = root["Spaces"] as? [String: Any] {
            for value in spaces.values {
                guard let space = value as? [String: Any] else { continue }
                if hasOurChoice(in: space["Idle"], provider: provider) { return true }
            }
        }
        return false
    }

    private static func hasOurChoice(in node: Any?, provider: String) -> Bool {
        guard let idle = node as? [String: Any],
            let content = idle["Content"] as? [String: Any],
            let choices = content["Choices"] as? [[String: Any]]
        else { return false }
        return choices.contains { ($0["Provider"] as? String) == provider }
    }
}
