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
    let nativeModeEnabled: () -> Bool

    static var live: NativeWallpaperAssignmentService {
        NativeWallpaperAssignmentService(files: LiveSystemWallpaperFiles()) { NativeModeSetting.standard.isEnabled }
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

    static func apply(
        entry: NativeWallpaperDeployment.EntryInfo,
        to displayIDs: Set<UInt32>
    ) throws {
        try apply(assignments: Dictionary(uniqueKeysWithValues: displayIDs.map { ($0, entry) }))
    }

    static func apply(assignments: [UInt32: NativeWallpaperDeployment.EntryInfo]) throws {
        guard #available(macOS 26, *) else { throw AssignmentError.unsupportedSystem }
        let stableAssignments = assignments.reduce(into: [String: NativeWallpaperDeployment.EntryInfo]()) {
            if let uuid = stableUUID(for: $1.key) { $0[uuid] = $1.value }
        }
        guard !stableAssignments.isEmpty else {
            nativeHostLog.error("assignment: CoreGraphics returned no stable display UUID")
            throw AssignmentError.unknownDisplay
        }
        try live.apply(assignments: stableAssignments)
    }

    static func applyLockScreen(entry: NativeWallpaperDeployment.EntryInfo) throws {
        guard #available(macOS 26, *) else { throw AssignmentError.unsupportedSystem }
        try live.applyLockScreen(entry: entry)
    }

    static func restoreOriginalWallpaper() throws -> RestoreResult {
        try live.restoreOriginalWallpaper()
    }

    /// Points each display (keyed by stable display UUID) at its entry.
    func apply(assignments: [String: NativeWallpaperDeployment.EntryInfo]) throws {
        guard nativeModeEnabled() else { throw AssignmentError.nativeModeOff }
        nativeHostLog.info("assignment: begin for \(assignments.count) display(s)")
        let (original, root) = try readStore()
        var changed = Set<String>()
        for (uuid, entry) in assignments {
            changed.formUnion(
                NativeWallpaperAssignmentStore.update(
                    root: root,
                    choiceID: entry.id,
                    videoURL: NativeWallpaperDeployment.videoURL(for: entry),
                    displayUUIDs: [uuid]
                ))
        }
        guard changed == Set(assignments.keys) else {
            let missing = Set(assignments.keys).subtracting(changed).sorted().joined(separator: ", ")
            let known = ((root["Displays"] as? NSDictionary)?.allKeys as? [String] ?? []).sorted().joined(separator: ", ")
            nativeHostLog.error(
                "assign: no Desktop surface for display(s) [\(missing, privacy: .public)]; store has [\(known, privacy: .public)]")
            throw AssignmentError.unknownDisplay
        }
        try replaceStore(original: original, with: root)
        nativeHostLog.info("assignment: verified; restarted WallpaperAgent")
    }

    func applyLockScreen(entry: NativeWallpaperDeployment.EntryInfo) throws {
        guard nativeModeEnabled() else { throw AssignmentError.nativeModeOff }
        let (original, root) = try readStore()
        NativeWallpaperAssignmentStore.updateIdleEverywhere(
            root: root,
            choiceID: entry.id,
            videoURL: NativeWallpaperDeployment.videoURL(for: entry)
        )
        try replaceStore(original: original, with: root)
    }

    /// Puts the user's own wallpaper back on every surface LumaWall took
    /// over, from the backup. Surfaces with no saved wallpaper stay as they
    /// are and are counted in `missing`.
    func restoreOriginalWallpaper() throws -> RestoreResult {
        let (original, root) = try readStore()
        let backup = try files.readBackup().flatMap {
            try? PropertyListSerialization.propertyList(from: $0, format: nil) as? NSDictionary
        }
        let result = NativeWallpaperAssignmentStore.restoreOriginal(root: root, backup: backup ?? [:])
        guard result.restored > 0 else { return result }
        try replaceStore(original: original, with: root, savingBackup: false)
        nativeHostLog.info("restore original: \(result.restored) surface(s) restored, \(result.missing) without a backup")
        return result
    }

    private func readStore() throws -> (Data, NSMutableDictionary) {
        let original: Data
        do { original = try files.readStore() } catch {
            logFailure("read", error)
            throw AssignmentError.unreadableStore
        }
        let source = try PropertyListSerialization.propertyList(
            from: original,
            options: [.mutableContainersAndLeaves],
            format: nil
        )
        guard let root = source as? NSMutableDictionary else { throw AssignmentError.invalidStore }
        return (original, root)
    }

    /// Writes `root`, checks macOS kept it, puts `original` back if not, and
    /// restarts WallpaperAgent so it loads the new choices.
    private func replaceStore(original: Data, with root: NSMutableDictionary, savingBackup: Bool = true) throws {
        let encoded = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
        if savingBackup { try saveBackup(original) }
        do {
            try files.writeStore(encoded)
            guard try files.readStore() == encoded else { throw AssignmentError.verificationFailed }
        } catch {
            logFailure("write", error)
            try? files.writeStore(original)
            if let assignmentError = error as? AssignmentError { throw assignmentError }
            throw AssignmentError.writeFailed(error.localizedDescription)
        }
        files.restartWallpaperAgent()
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
            let merged = NativeWallpaperAssignmentStore.mergeBackup(existing: existing, current: current)
            try files.writeBackup(PropertyListSerialization.data(fromPropertyList: merged, format: .binary, options: 0))
        } catch {
            logFailure("backup", error)
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

    /// `Index.plist` is a live file owned by WallpaperAgent. Foundation's
    /// `.atomic` option creates and renames a sibling temporary file, which can
    /// fail while the agent is observing the directory. Coordinate the replace
    /// and write the already-encoded plist to the granted URL instead.
    func writeStore(_ data: Data) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var writeError: (any Error)?
        coordinator.coordinate(writingItemAt: Self.storeURL, options: .forReplacing, error: &coordinationError) { grantedURL in
            do {
                try data.write(to: grantedURL, options: [])
            } catch {
                writeError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
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
