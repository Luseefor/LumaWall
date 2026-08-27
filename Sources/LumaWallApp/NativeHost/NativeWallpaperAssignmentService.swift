import AppKit
import CoreGraphics
import Foundation

@MainActor
enum NativeWallpaperAssignmentService {
    enum AssignmentError: LocalizedError {
        case unsupportedSystem
        case unreadableStore
        case unknownDisplay
        case invalidStore
        case verificationFailed
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedSystem: "Native wallpaper assignment needs macOS 26 or later."
            case .unreadableStore: "The macOS wallpaper configuration could not be read."
            case .unknownDisplay: "That display is missing from the wallpaper configuration."
            case .invalidStore: "The macOS wallpaper configuration has an unsupported format."
            case .verificationFailed: "macOS did not retain the new wallpaper assignment."
            case .writeFailed(let detail): "LumaWall could not update the macOS wallpaper configuration. \(detail)"
            }
        }
    }

    private static var storeURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
    }

    private static var backupURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LumaWall/Backups", isDirectory: true)
            .appendingPathComponent("WallpaperIndex.plist")
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
        nativeHostLog.info("assignment: begin for \(assignments.count) display(s)")
        let stableAssignments = assignments.reduce(into: [String: NativeWallpaperDeployment.EntryInfo]()) {
            if let uuid = stableUUID(for: $1.key) { $0[uuid] = $1.value }
        }
        guard !stableAssignments.isEmpty else {
            nativeHostLog.error("assignment: CoreGraphics returned no stable display UUID")
            throw AssignmentError.unknownDisplay
        }

        let original: Data
        do { original = try Data(contentsOf: storeURL) }
        catch {
            logFailure("read", error)
            throw AssignmentError.unreadableStore
        }

        let source = try PropertyListSerialization.propertyList(
            from: original,
            options: [.mutableContainersAndLeaves],
            format: nil
        )
        guard let root = source as? NSMutableDictionary else { throw AssignmentError.invalidStore }
        var changed = Set<String>()
        for (uuid, entry) in stableAssignments {
            changed.formUnion(NativeWallpaperAssignmentStore.update(
                root: root,
                choiceID: entry.id,
                videoURL: NativeWallpaperDeployment.videoURL(for: entry),
                displayUUIDs: [uuid]
            ))
        }
        guard changed == Set(stableAssignments.keys) else {
            let missing = Set(stableAssignments.keys).subtracting(changed).sorted().joined(separator: ", ")
            let known = ((root["Displays"] as? NSDictionary)?.allKeys as? [String] ?? []).sorted().joined(separator: ", ")
            nativeHostLog.error("assign: no Desktop surface for display(s) [\(missing, privacy: .public)]; store has [\(known, privacy: .public)]")
            throw AssignmentError.unknownDisplay
        }

        let encoded = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
        nativeHostLog.info("assignment: matched all displays; writing \(encoded.count) bytes")
        try saveBackup(original)
        do {
            try writeCoordinated(encoded, to: storeURL)
            let check = try Data(contentsOf: storeURL)
            guard check == encoded else { throw AssignmentError.verificationFailed }
        } catch {
            logFailure("write", error)
            try? writeCoordinated(original, to: storeURL)
            if let assignmentError = error as? AssignmentError { throw assignmentError }
            throw AssignmentError.writeFailed(error.localizedDescription)
        }

        nativeHostLog.info("assignment: verified; restarting WallpaperAgent")
        restartWallpaperAgent()
    }

    static func applyLockScreen(entry: NativeWallpaperDeployment.EntryInfo) throws {
        guard #available(macOS 26, *) else { throw AssignmentError.unsupportedSystem }
        let original: Data
        do { original = try Data(contentsOf: storeURL) }
        catch { throw AssignmentError.unreadableStore }
        let source = try PropertyListSerialization.propertyList(
            from: original,
            options: [.mutableContainersAndLeaves],
            format: nil
        )
        guard let root = source as? NSMutableDictionary else { throw AssignmentError.invalidStore }
        NativeWallpaperAssignmentStore.updateIdleEverywhere(
            root: root,
            choiceID: entry.id,
            videoURL: NativeWallpaperDeployment.videoURL(for: entry)
        )
        let encoded = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
        try saveBackup(original)
        do {
            try writeCoordinated(encoded, to: storeURL)
            let check = try Data(contentsOf: storeURL)
            guard check == encoded else { throw AssignmentError.verificationFailed }
        } catch {
            try? writeCoordinated(original, to: storeURL)
            if let assignmentError = error as? AssignmentError { throw assignmentError }
            throw AssignmentError.writeFailed(error.localizedDescription)
        }
        restartWallpaperAgent()
    }

    /// `Index.plist` is a live file owned by WallpaperAgent. Foundation's
    /// `.atomic` option creates and renames a sibling temporary file, which can
    /// fail while the agent is observing the directory. Coordinate the replace
    /// and write the already-encoded plist to the granted URL instead.
    private static func writeCoordinated(_ data: Data, to url: URL) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var writeError: (any Error)?
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { grantedURL in
            do {
                try data.write(to: grantedURL, options: [])
            } catch {
                writeError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
    }

    private static func saveBackup(_ data: Data) throws {
        let folder = backupURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: backupURL, options: .atomic)
        } catch {
            logFailure("backup", error)
            throw AssignmentError.writeFailed("Its safety backup could not be created: \(error.localizedDescription)")
        }
    }

    private static func logFailure(_ stage: String, _ error: any Error) {
        let cocoa = error as NSError
        nativeHostLog.error(
            "assignment: \(stage, privacy: .public) failed domain=\(cocoa.domain, privacy: .public) code=\(cocoa.code) description=\(cocoa.localizedDescription, privacy: .public)"
        )
    }

    private static func restartWallpaperAgent() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["WallpaperAgent"]
        try? process.run()
    }
}
