import CoreGraphics
import Foundation
import ServiceManagement

/// Whether the login session's screen is locked right now.
public enum SessionLock {
    /// Lock and unlock notifications only report changes. An app launched
    /// while the screen is already locked reads the current state here.
    public static var isLocked: Bool {
        isLocked(in: CGSessionCopyCurrentDictionary() as? [String: Any])
    }

    public static func isLocked(in session: [String: Any]?) -> Bool {
        (session?["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false
    }
}

public enum LaunchAtLogin {
    public static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @discardableResult
    public static func setEnabled(_ enabled: Bool) throws -> Bool {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
        return isEnabled
    }
}

public enum CacheCleaner {
    public static func clearMemory() {
        URLCache.shared.removeAllCachedResponses()
    }

    /// Empties `<caches>/LumaWall` and deletes the library's `Scratch`
    /// folder. Both are opened without following symlinks, so a folder
    /// swapped for a link loses the link, not the files it points at.
    /// Returns how many items were removed.
    public static func clearDisk(
        preservingLibraryRoot root: URL,
        cachesURL: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    ) throws -> Int {
        var removed = 0
        if let caches = try? TrustedDirectory(url: cachesURL).subdirectory("LumaWall") {
            for item in try caches.entries() where (try? caches.removeItem(named: item.name)) != nil {
                removed += 1
            }
        }
        if (try? TrustedDirectory(url: root).removeItem(named: "Scratch")) != nil {
            removed += 1
        }
        return removed
    }
}
