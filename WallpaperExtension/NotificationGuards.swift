// Checks for actions triggered by Darwin and distributed notifications. Any
// local process can post those, so a notification is only a hint: each
// action confirms it against state another process can't fake as easily.

import CoreGraphics
import Foundation

/// loginwindow's `com.apple.screenIsLocked` / `screenIsUnlocked`, confirmed
/// against the login session before the extension acts on them.
enum ScreenLockHint {
    /// Act on a hint only when the session agrees with it. When the session
    /// can't be read, the Agent's presentation mode still arrives on its own.
    static func shouldApply(claimsLocked: Bool, sessionLocked: Bool?) -> Bool {
        sessionLocked == claimsLocked
    }

    /// Whether the login session's screen is locked, or nil when there is
    /// no session dictionary to read.
    static func isLocked(session: [String: Any]?) -> Bool? {
        guard let session else { return nil }
        return (session["CGSSessionScreenIsLocked"] as? Bool) == true
    }

    static func sessionIsLocked() -> Bool? {
        isLocked(session: CGSessionCopyCurrentDictionary() as? [String: Any])
    }
}

/// The app's request to clear the snapshot cache. The app writes this file
/// in the extension's Documents folder, then posts `clearCaches`; the
/// extension clears only when the file is there and fresh. The app side is
/// `NativeWallpaperDeployment.requestSnapshotCacheClear`.
enum CacheClearRequest {
    static let fileName = "clear-caches.request"
    /// How long after it's written a request counts.
    static let maxAge: TimeInterval = 30

    static func isFresh(modified: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(modified)
        // A little slack for clock skew between the write and the check.
        return age >= -5 && age <= maxAge
    }

    /// Whether a fresh request is waiting. Removes the request either way,
    /// so one request clears once.
    static func consume(in documents: URL, now: Date = Date()) -> Bool {
        let path = documents.appendingPathComponent(fileName).path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return false }
        try? FileManager.default.removeItem(atPath: path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
            let modified = attributes[.modificationDate] as? Date
        else { return false }
        return isFresh(modified: modified, now: now)
    }
}

/// Which files a snapshot-cache clear may delete.
enum StillCacheSweep {
    /// The extension's own stills (named as `StillCacheEntry` names them)
    /// that are regular files directly in `directory`. Nil when `directory`
    /// isn't a real directory, such as a symlink to somewhere else.
    static func filesToClear(in directory: URL) -> [URL]? {
        let manager = FileManager.default
        guard (try? manager.attributesOfItem(atPath: directory.path))?[.type] as? FileAttributeType == .typeDirectory,
            let names = try? manager.contentsOfDirectory(atPath: directory.path)
        else { return nil }
        return names.sorted().compactMap { name in
            guard StillCacheEntry(fileName: name) != nil else { return nil }
            let url = directory.appendingPathComponent(name)
            guard (try? manager.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeRegular else {
                return nil
            }
            return url
        }
    }
}
