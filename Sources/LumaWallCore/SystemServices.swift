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

    public static func clearDisk(preservingLibraryRoot root: URL) throws -> Int {
        let fm = FileManager.default
        var removed = 0
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LumaWall", isDirectory: true)
        if fm.fileExists(atPath: caches.path) {
            let items = try fm.contentsOfDirectory(at: caches, includingPropertiesForKeys: nil)
            for item in items {
                try? fm.removeItem(at: item)
                removed += 1
            }
        }
        let tmp = root.appendingPathComponent("Scratch", isDirectory: true)
        if fm.fileExists(atPath: tmp.path) {
            try? fm.removeItem(at: tmp)
            removed += 1
        }
        return removed
    }
}
