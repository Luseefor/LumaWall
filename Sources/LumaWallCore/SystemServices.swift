import Foundation
import ServiceManagement

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
