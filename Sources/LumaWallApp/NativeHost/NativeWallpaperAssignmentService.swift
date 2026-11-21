import AppKit
import CoreGraphics
import Foundation

/// The macOS wallpaper store, LumaWall's backup of it, and WallpaperAgent.
/// Tests swap in an in-memory fake.
@MainActor
protocol SystemWallpaperFiles {
    /// Runs `body` while holding a coordinated write on the store, so its
    /// reads and writes form one transaction for coordinating writers.
    /// `body` gets the URL the coordinator granted and reads and writes the
    /// store only through it.
    func coordinateStore(_ body: (URL) throws -> Void) throws
    func readStore(at url: URL) throws -> Data
    func writeStore(_ data: Data, to url: URL) throws
    func readBackup() throws -> Data?
    func writeBackup(_ data: Data) throws
    func restartWallpaperAgent()
}

/// Writes LumaWall's choices into the macOS wallpaper store
/// (`com.apple.wallpaper/Store/Index.plist`). Only native mode may do that:
/// with the setting off every assignment throws `nativeModeOff` before the
/// store is read. Restoring the user's original wallpaper is the one write
/// allowed with native mode off, since the user asks for it.
@MainActor
struct NativeWallpaperAssignmentService {
    enum AssignmentError: LocalizedError {
        case nativeModeOff
        case unsupportedSystem
        case unreadableStore
        case unknownDisplay
        case invalidStore
        case verificationFailed
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .nativeModeOff: "Native wallpaper mode is off."
            case .unsupportedSystem: "Native wallpaper assignment needs macOS 26 or later."
            case .unreadableStore: "The macOS wallpaper configuration could not be read."
            case .unknownDisplay: "That display is missing from the wallpaper configuration."
            case .invalidStore: "The macOS wallpaper configuration has an unsupported format."
            case .verificationFailed: "macOS did not retain the new wallpaper assignment."
            case .writeFailed(let detail): "LumaWall could not update the macOS wallpaper configuration. \(detail)"
            }
        }
    }

    /// Surfaces put back from the backup, and LumaWall surfaces the backup
    /// had no earlier wallpaper for.
    struct RestoreResult: Equatable {
        var restored: Int
        var missing: Int
    }

    let files: any SystemWallpaperFiles
    /// Folders whose files mark a surface as LumaWall's (see
    /// `NativeWallpaperAssignmentStore.isOurs`).
    let ownedFolders: [URL]
    let nativeModeEnabled: () -> Bool

    static var live: NativeWallpaperAssignmentService {
        NativeWallpaperAssignmentService(
            files: LiveSystemWallpaperFiles(),
            ownedFolders: NativeWallpaperAssignmentStore.lumaWallFolders,
            nativeModeEnabled: { NativeModeSetting.standard.isEnabled }
        )
    }

    /// True once LumaWall has written the wallpaper store, which saves a
    /// backup first. Only native mode writes it.
    nonisolated static var hasBackup: Bool {
        FileManager.default.fileExists(atPath: LiveSystemWallpaperFiles.backupURL.path)
    }

    static func stableUUID(for displayID: UInt32) -> String? {
        guard let value = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
            let text = CFUUIDCreateString(kCFAllocatorDefault, value)
        else { return nil }
        return (text as String).uppercased()
    }

    @discardableResult
    static func apply(
        entry: NativeWallpaperDeployment.EntryInfo,
        to displayIDs: Set<UInt32>
    ) throws -> Set<UInt32> {
        try apply(assignments: Dictionary(uniqueKeysWithValues: displayIDs.map { ($0, entry) }))
    }

    /// Returns the displays the store has no Desktop entry for. Throws
    /// `unknownDisplay` when that is all of them.
    @discardableResult
    static func apply(assignments: [UInt32: NativeWallpaperDeployment.EntryInfo]) throws -> Set<UInt32> {
        guard #available(macOS 26, *) else { throw AssignmentError.unsupportedSystem }
        var uuids: [String: UInt32] = [:]
        for displayID in assignments.keys {
            if let uuid = stableUUID(for: displayID) { uuids[uuid] = displayID }
        }
        let stableAssignments = assignments.reduce(into: [String: NativeWallpaperDeployment.EntryInfo]()) {
            if let uuid = stableUUID(for: $1.key) { $0[uuid] = $1.value }
        }
        guard !stableAssignments.isEmpty else {
            nativeHostLog.error("assignment: CoreGraphics returned no stable display UUID")
            throw AssignmentError.unknownDisplay
        }
        let missing = try live.apply(assignments: stableAssignments)
        let unresolved = Set(assignments.keys).subtracting(uuids.values)
        return unresolved.union(missing.compactMap { uuids[$0] })
    }

    static func applyLockScreen(entry: NativeWallpaperDeployment.EntryInfo) throws {
        guard #available(macOS 26, *) else { throw AssignmentError.unsupportedSystem }
        try live.applyLockScreen(entry: entry)
    }

    static func restoreOriginalWallpaper() throws -> RestoreResult {
        try live.restoreOriginalWallpaper()
    }

    /// Points each display (keyed by stable display UUID) at its entry, and
    /// returns the displays the store has no Desktop entry for. Throws
    /// `unknownDisplay`, writing nothing, when that is all of them.
    @discardableResult
    func apply(assignments: [String: NativeWallpaperDeployment.EntryInfo]) throws -> Set<String> {
        guard nativeModeEnabled() else { throw AssignmentError.nativeModeOff }
        nativeHostLog.info("assignment: begin for \(assignments.count) display(s)")
        var changed = Set<String>()
        try transact(savingBackup: true) { root in
            changed = []
            for (uuid, entry) in assignments {
                changed.formUnion(
                    NativeWallpaperAssignmentStore.update(
                        root: root,
                        choiceID: entry.id,
                        videoURL: NativeWallpaperDeployment.videoURL(for: entry),
                        displayUUIDs: [uuid]
                    ))
            }
            let missing = Set(assignments.keys).subtracting(changed)
            if !missing.isEmpty {
                let names = missing.sorted().joined(separator: ", ")
                let known = ((root["Displays"] as? NSDictionary)?.allKeys as? [String] ?? []).sorted().joined(separator: ", ")
                nativeHostLog.error(
                    "assign: no Desktop surface for display(s) [\(names, privacy: .public)]; store has [\(known, privacy: .public)]")
            }
            guard !changed.isEmpty else { throw AssignmentError.unknownDisplay }
        }
        nativeHostLog.info("assignment: verified; restarted WallpaperAgent")
        return Set(assignments.keys).subtracting(changed)
    }

    func applyLockScreen(entry: NativeWallpaperDeployment.EntryInfo) throws {
        guard nativeModeEnabled() else { throw AssignmentError.nativeModeOff }
        try transact(savingBackup: true) { root in
            NativeWallpaperAssignmentStore.updateIdleEverywhere(
                root: root,
                choiceID: entry.id,
                videoURL: NativeWallpaperDeployment.videoURL(for: entry)
            )
        }
    }

    /// Puts the user's own wallpaper back on every surface LumaWall took
    /// over, from the backup. Surfaces with no saved wallpaper stay as they
    /// are and are counted in `missing`.
    func restoreOriginalWallpaper() throws -> RestoreResult {
        let backup =
            try files.readBackup().flatMap {
                try? PropertyListSerialization.propertyList(from: $0, format: nil) as? NSDictionary
            } ?? [:]
        var result = RestoreResult(restored: 0, missing: 0)
        try transact(savingBackup: false) { root in
            let attempt = NativeWallpaperAssignmentStore.restoreOriginal(root: root, backup: backup, ownedFolders: ownedFolders)
            // A retry after a write that landed finds nothing left to restore;
            // keep what that write restored.
            if attempt.restored > 0 || result.restored == 0 { result = attempt }
        }
        if result.restored > 0 {
            nativeHostLog.info("restore original: \(result.restored) surface(s) restored, \(result.missing) without a backup")
        }
        return result
    }

    private enum Attempt { case nothingToWrite, written, conflict }

    /// Tries per change before giving up with `verificationFailed`.
    private static let maxAttempts = 3

    /// One coordinated read-merge-write of the store. `merge` edits a fresh
    /// parse; the surfaces it changed are written, then checked on disk.
    ///
    /// WallpaperAgent writes the file without coordinating. So the file is
    /// read again right before writing, and a change since the first read,
    /// a half-written file, or a write that doesn't survive the check makes
    /// the merge run again on the newer file. An older copy is never written
    /// back over someone else's change. A change the agent makes between
    /// that last read and the write is still lost; only the agent
    /// coordinating could close that.
    ///
    /// Restarts WallpaperAgent after a verified write and returns whether
    /// anything was written.
    @discardableResult
    private func transact(savingBackup: Bool, merge: (NSMutableDictionary) throws -> Void) throws -> Bool {
        var sawConflict = false
        // An earlier attempt's write may have landed even though its check
        // couldn't confirm it.
        var wrote = false
        for attempt in 1...Self.maxAttempts {
            var outcome = Attempt.nothingToWrite
            try files.coordinateStore { url in
                let before: Data
                let original: NSMutableDictionary
                let root: NSMutableDictionary
                do {
                    before = try readStoreData(at: url)
                    original = try parse(before)
                    root = try parse(before)
                } catch {
                    // After a conflict the agent may still be part-way through its write.
                    guard sawConflict, attempt < Self.maxAttempts else { throw error }
                    outcome = .conflict
                    return
                }
                try merge(root)
                let changed = NativeWallpaperAssignmentStore.changedSurfacePaths(from: original, to: root)
                guard !changed.isEmpty else { return }
                let encoded = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
                if savingBackup { try saveBackup(before) }
                guard try reread(at: url) == before else {
                    outcome = .conflict
                    return
                }
                do {
                    try files.writeStore(encoded, to: url)
                } catch {
                    logFailure("write", error)
                    repairAfterFailedWrite(before: before, written: encoded, at: url)
                    if WallpaperHostCapabilities.isPermissionError(error) { throw error }
                    throw AssignmentError.writeFailed(error.localizedDescription)
                }
                wrote = true
                let check = try reread(at: url).flatMap { try? parse($0) }
                let kept = check.map { NativeWallpaperAssignmentStore.contents(at: changed, in: $0, match: root) } ?? false
                outcome = kept ? .written : .conflict
            }
            switch outcome {
            case .nothingToWrite:
                guard wrote else { return false }
                files.restartWallpaperAgent()
                return true
            case .written:
                files.restartWallpaperAgent()
                return true
            case .conflict:
                sawConflict = true
                nativeHostLog.notice("assignment: the store changed under the write (attempt \(attempt)); merging again")
            }
        }
        nativeHostLog.error("assignment: store kept changing; gave up after \(Self.maxAttempts) attempts")
        throw AssignmentError.verificationFailed
    }

    /// After a failed write, puts back the copy this transaction read, but
    /// only when the file is a cut-off copy of LumaWall's own write: it
    /// doesn't parse, and it runs past the first byte where LumaWall's write
    /// differs from the file it read, which another writer wouldn't produce.
    /// Anything else stays. If the agent finishes a write of its own between
    /// this check and the put-back, that write is lost.
    private func repairAfterFailedWrite(before: Data, written: Data, at url: URL) {
        let shared = zip(before, written).prefix { $0 == $1 }.count
        guard let current = try? files.readStore(at: url), current.count > shared,
            (try? parse(current)) == nil, written.starts(with: current)
        else { return }
        try? files.writeStore(before, to: url)
    }

    /// Reads the store again inside a transaction. Nil when it can't be read
    /// right now; permission errors still reach the caller.
    private func reread(at url: URL) throws -> Data? {
        do { return try files.readStore(at: url) } catch {
            if WallpaperHostCapabilities.isPermissionError(error) { throw error }
            return nil
        }
    }

    private func readStoreData(at url: URL) throws -> Data {
        do { return try files.readStore(at: url) } catch {
            logFailure("read", error)
            // Callers switch every display to the overlay on a permission error.
            if WallpaperHostCapabilities.isPermissionError(error) { throw error }
            throw AssignmentError.unreadableStore
        }
    }

    private func parse(_ data: Data) throws -> NSMutableDictionary {
        let source = try PropertyListSerialization.propertyList(from: data, options: [.mutableContainersAndLeaves], format: nil)
        guard let root = source as? NSMutableDictionary else { throw AssignmentError.invalidStore }
        return root
    }

    /// Keeps, per surface, the last wallpaper that wasn't LumaWall's, so a
    /// later restore brings back the user's own choice rather than an older
    /// LumaWall one.
    private func saveBackup(_ original: Data) throws {
        do {
            let current = try PropertyListSerialization.propertyList(from: original, format: nil) as? NSDictionary ?? [:]
            let existing = try files.readBackup().flatMap {
                try? PropertyListSerialization.propertyList(from: $0, format: nil) as? NSDictionary
            }
            let merged = NativeWallpaperAssignmentStore.mergeBackup(
                existing: existing, current: current, ownedFolders: ownedFolders)
            try files.writeBackup(PropertyListSerialization.data(fromPropertyList: merged, format: .binary, options: 0))
        } catch {
            logFailure("backup", error)
            if WallpaperHostCapabilities.isPermissionError(error) { throw error }
            throw AssignmentError.writeFailed("Its safety backup could not be created: \(error.localizedDescription)")
        }
    }

    private func logFailure(_ stage: String, _ error: any Error) {
        // The description can name files and folders, so only the domain
        // and code are public.
        nativeHostLog.error(
            "assignment: \(stage, privacy: .public) failed \(LogRedaction.code(of: error), privacy: .public) description=\(error.localizedDescription, privacy: .private)"
        )
    }
}

struct LiveSystemWallpaperFiles: SystemWallpaperFiles {
    nonisolated static var storeURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
    }

    nonisolated static var backupURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LumaWall/Backups", isDirectory: true)
            .appendingPathComponent("WallpaperIndex.plist")
    }

    /// Holds a coordinated write on `Index.plist` while `body` reads,
    /// merges and writes it through the granted URL. `.forMerging` tells
    /// other coordinating processes the file is read and rewritten in place.
    func coordinateStore(_ body: (URL) throws -> Void) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var bodyError: (any Error)?
        coordinator.coordinate(writingItemAt: Self.storeURL, options: .forMerging, error: &coordinationError) { grantedURL in
            do { try body(grantedURL) } catch { bodyError = error }
        }
        if let coordinationError { throw coordinationError }
        if let bodyError { throw bodyError }
    }

    func readStore(at url: URL) throws -> Data { try Data(contentsOf: url) }

    /// `Index.plist` is a live file owned by WallpaperAgent. Foundation's
    /// `.atomic` option creates and renames a sibling temporary file, which can
    /// fail while the agent is observing the directory, so this writes in
    /// place. Call it inside `coordinateStore`.
    func writeStore(_ data: Data, to url: URL) throws {
        Self.storeChangeCount += 1
        try data.write(to: url, options: [])
    }

    func readBackup() throws -> Data? {
        guard FileManager.default.fileExists(atPath: Self.backupURL.path) else { return nil }
        return try Data(contentsOf: Self.backupURL)
    }

    func writeBackup(_ data: Data) throws {
        try FileManager.default.createDirectory(at: Self.backupURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: Self.backupURL, options: .atomic)
    }

    /// Bumped on every store write and agent restart. The extension health
    /// check (ADR 0003) waits out the re-acquire that follows.
    static var storeChangeCount = 0

    func restartWallpaperAgent() {
        Self.storeChangeCount += 1
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["WallpaperAgent"]
        try? process.run()
    }
}
