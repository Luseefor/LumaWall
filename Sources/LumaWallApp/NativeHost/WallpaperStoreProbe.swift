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
        var modified: Date
        var size: Int
    }

    private static var cached: (stamp: Stamp, isOurs: Bool)?

    /// True when any Idle/screensaver choice is owned by the LumaWall wallpaper extension.
    ///
    /// The store lists every Space and runs to hundreds of KB. Playback policy
    /// asks on every power and workspace event, so the answer is reused until
    /// the file's modification date or size changes.
    static func screenSaverIsOurs(storeURL: URL? = nil) -> Bool {
        let url = storeURL ?? defaultStoreURL
        // attributesOfItem reads fresh; URL.resourceValues caches per URL value.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date,
              let size = (attributes[.size] as? NSNumber)?.intValue
        else {
            cached = nil
            return false
        }
        let stamp = Stamp(url: url, modified: modified, size: size)
        if let cached, cached.stamp == stamp { return cached.isOurs }
        parseCount += 1
        let isOurs = (try? Data(contentsOf: url))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, options: [], format: nil) as? [String: Any] }
            .map(containsOurChoice) ?? false
        cached = (stamp, isOurs)
        return isOurs
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
