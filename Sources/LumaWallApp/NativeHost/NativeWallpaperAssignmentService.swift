import AppKit
import CoreGraphics
import Foundation

/// The macOS wallpaper store, LumaWall's backup of it, and WallpaperAgent.
/// Tests swap in an in-memory fake.
@MainActor
protocol SystemWallpaperFiles {
    func readStore() throws -> Data
    func writeStore(_ data: Data) throws
    func readBackup() throws -> Data?
    func writeBackup(_ data: Data) throws
    func restartWallpaperAgent()
    /// Runs `body` while holding a coordinated write on the store, so its
    /// reads and writes form one transaction for coordinating writers.
    func coordinateStore(_ body: () throws -> Void) throws
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
            return true
        } isApplied: { check in
            changed.allSatisfy { uuid in
                guard let entry = assignments[uuid] else { return true }
                return NativeWallpaperAssignmentStore.shows(choiceID: entry.id, on: "Desktop", of: [uuid], in: check)
            }
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
            ) > 0
        } isApplied: { check in
            NativeWallpaperAssignmentStore.shows(choiceID: entry.id, on: "Idle", of: nil, in: check)
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
            result = NativeWallpaperAssignmentStore.restoreOriginal(root: root, backup: backup, ownedFolders: ownedFolders)
            return result.restored > 0
        } isApplied: { check in
            let copy = NSMutableDictionary(dictionary: check)
            return NativeWallpaperAssignmentStore.restoreOriginal(root: copy, backup: backup, ownedFolders: ownedFolders).restored == 0
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
    /// parse and returns false when nothing needs writing. WallpaperAgent
    /// writes the file without coordinating, so a change between LumaWall's
    /// read and write, or one that undoes LumaWall's right after, makes the
    /// merge run again on the newer file. An older copy is never written back
    /// over someone else's change. Restarts WallpaperAgent after a verified
    /// write and returns whether anything was written.
    @discardableResult
    private func transact(
        savingBackup: Bool,
        merge: (NSMutableDictionary) throws -> Bool,
        isApplied: (NSDictionary) -> Bool
    ) throws -> Bool {
        for attempt in 1...Self.maxAttempts {
            var outcome = Attempt.nothingToWrite
            try files.coordinateStore {
                let before = try readStoreData()
                let root = try parse(before)
                guard try merge(root) else { return }
                let encoded = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
                if savingBackup { try saveBackup(before) }
                guard (try? files.readStore()) == before else {
                    outcome = .conflict
                    return
                }
                do {
                    try files.writeStore(encoded)
                } catch {
                    logFailure("write", error)
                    repairAfterFailedWrite(before)
                    if WallpaperHostCapabilities.isPermissionError(error) { throw error }
                    throw AssignmentError.writeFailed(error.localizedDescription)
                }
                outcome = .written
            }
            switch outcome {
            case .nothingToWrite:
                return false
            case .conflict:
                nativeHostLog.notice("assignment: store changed before the write (attempt \(attempt)); merging again")
            case .written:
                if let check = try? parse(files.readStore()), isApplied(check) {
                    files.restartWallpaperAgent()
                    return true
                }
                nativeHostLog.notice("assignment: store changed after the write (attempt \(attempt)); merging again")
            }
        }
        nativeHostLog.error("assignment: store kept changing; gave up after \(Self.maxAttempts) attempts")
        throw AssignmentError.verificationFailed
    }

    /// After a failed write, puts back the copy this transaction read, but
    /// only when the file no longer parses (the write left it cut off). A file
    /// that parses is untouched or newer, and stays.
    private func repairAfterFailedWrite(_ before: Data) {
        if let current = try? files.readStore(), (try? parse(current)) != nil { return }
        try? files.writeStore(before)
    }

    private func readStoreData() throws -> Data {
        do { return try files.readStore() } catch {
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
        let cocoa = error as NSError
        nativeHostLog.error(
            "assignment: \(stage, privacy: .public) failed domain=\(cocoa.domain, privacy: .public) code=\(cocoa.code) description=\(cocoa.localizedDescription, privacy: .public)"
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

    func readStore() throws -> Data { try Data(contentsOf: Self.storeURL) }

    /// Holds a coordinated write on `Index.plist` while `body` reads,
    /// merges and writes it. `.forMerging` tells other coordinating
    /// processes the file is read and rewritten in place.
    func coordinateStore(_ body: () throws -> Void) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var bodyError: (any Error)?
        coordinator.coordinate(writingItemAt: Self.storeURL, options: .forMerging, error: &coordinationError) { _ in
            do { try body() } catch { bodyError = error }
        }
        if let coordinationError { throw coordinationError }
        if let bodyError { throw bodyError }
    }

    /// `Index.plist` is a live file owned by WallpaperAgent. Foundation's
    /// `.atomic` option creates and renames a sibling temporary file, which can
    /// fail while the agent is observing the directory, so this writes in
    /// place. Call it inside `coordinateStore`.
    func writeStore(_ data: Data) throws {
        try data.write(to: Self.storeURL, options: [])
    }

    func readBackup() throws -> Data? {
        guard FileManager.default.fileExists(atPath: Self.backupURL.path) else { return nil }
        return try Data(contentsOf: Self.backupURL)
    }

    func writeBackup(_ data: Data) throws {
        try FileManager.default.createDirectory(at: Self.backupURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: Self.backupURL, options: .atomic)
    }

    func restartWallpaperAgent() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["WallpaperAgent"]
        try? process.run()
    }
}
