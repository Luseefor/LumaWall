import Foundation

enum WallpaperStoreProbe {
    private static var storeURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
    }

    /// True when any Idle/screensaver choice is owned by the LumaWall wallpaper extension.
    static func screenSaverIsOurs() -> Bool {
        guard let data = try? Data(contentsOf: storeURL),
              let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        else { return false }
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
