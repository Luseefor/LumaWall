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

    /// Whether a fresh request is waiting. A regular file is removed either
    /// way, so one request clears once; a request that can't be removed
    /// doesn't count. Anything else at the path is left alone.
    static func consume(in documents: URL, now: Date = Date()) -> Bool {
        let path = documents.appendingPathComponent(fileName).path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
            attributes[.type] as? FileAttributeType == .typeRegular
        else { return false }
        // unlink(2) never recurses and removes a link, not its target.
        guard unlink(path) == 0, let modified = attributes[.modificationDate] as? Date else { return false }
        return isFresh(modified: modified, now: now)
    }
}

/// Which files a snapshot-cache clear may delete, and the deleting. Listing,
/// type checks and deletion all go through one handle on the directory,
/// opened without following a symlink, so swapping the directory mid-sweep
/// can't redirect it.
enum StillCacheSweep {
    /// The extension's own stills (named exactly as `StillCacheEntry`
    /// writes them) that are regular files directly in `directory`. Nil
    /// when `directory` isn't a real directory, such as a symlink.
    static func filesToClear(in directory: URL) -> [URL]? {
        withDirectory(directory) { handle in stills(in: handle).map { directory.appendingPathComponent($0) } }
    }

    /// Delete `filesToClear(in:)`. Returns how many went, or nil when the
    /// directory isn't a real directory.
    static func clear(in directory: URL) -> Int? {
        withDirectory(directory) { handle in stills(in: handle).filter { unlinkat(handle, $0, 0) == 0 }.count }
    }

    /// Unlink each of `files` by name in `directory`. unlinkat(2) without
    /// AT_REMOVEDIR fails on a directory, so a file swapped for one after
    /// the scan is never deleted recursively. Returns how many went.
    static func remove(_ files: [URL], in directory: URL) -> Int {
        withDirectory(directory) { handle in files.filter { unlinkat(handle, $0.lastPathComponent, 0) == 0 }.count } ?? 0
    }

    private static func withDirectory<T>(_ directory: URL, _ body: (Int32) -> T) -> T? {
        let handle = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard handle >= 0 else { return nil }
        defer { close(handle) }
        return body(handle)
    }

    /// Writer-named regular files in the directory `handle` is open on.
    private static func stills(in handle: Int32) -> [String] {
        let listing = dup(handle)
        guard listing >= 0, let stream = fdopendir(listing) else {
            if listing >= 0 { close(listing) }
            return []
        }
        defer { closedir(stream) }
        var names: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            var info = stat()
            guard isWriterName(name), fstatat(handle, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                info.st_mode & S_IFMT == S_IFREG
            else { continue }
            names.append(name)
        }
        return names.sorted()
    }

    /// A name the extension writes: the entry parses and prints back the
    /// same, and the choice hash is lowercase SHA-256 hex.
    private static func isWriterName(_ name: String) -> Bool {
        guard let entry = StillCacheEntry(fileName: name), entry.fileName == name else { return false }
        return entry.key.choiceHash.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }
}

/// Which confirmed lock hints count as a wake. A playlist that advances on
/// wake moves only on a lock-to-unlock change, so a repeated unlock hint
/// can't step it.
struct LockHintTracker {
    private var locked: Bool?

    /// Starts from the session's state, or unknown.
    init(sessionLocked: Bool?) {
        locked = sessionLocked
    }

    /// The Agent reported the lock screen. Kept until a confirmed unlock
    /// consumes it, so a lock hint missed while suspended still counts.
    mutating func noteAgentLocked() {
        locked = true
    }

    /// Record a confirmed hint. True when it unlocked a screen known to be
    /// locked.
    mutating func confirm(locked newValue: Bool) -> Bool {
        defer { locked = newValue }
        return locked == true && !newValue
    }
}
