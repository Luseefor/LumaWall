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

        var errorDescription: String? {
            switch self {
            case .unsupportedSystem: "Native wallpaper assignment needs macOS 26 or later."
            case .unreadableStore: "The macOS wallpaper configuration could not be read."
            case .unknownDisplay: "That display is missing from the wallpaper configuration."
            case .invalidStore: "The macOS wallpaper configuration has an unsupported format."
            case .verificationFailed: "macOS did not retain the new wallpaper assignment."
            }
        }
    }

    private static var storeURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
    }

    private static var backupURL: URL {
        storeURL.deletingLastPathComponent().appendingPathComponent("Index.lumawall-backup.plist")
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
        guard !stableAssignments.isEmpty else { throw AssignmentError.unknownDisplay }

        let original: Data
        do { original = try Data(contentsOf: storeURL) }
        catch { throw AssignmentError.unreadableStore }

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
        guard changed == Set(stableAssignments.keys) else { throw AssignmentError.unknownDisplay }

        let encoded = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
        try original.write(to: backupURL, options: .atomic)
        do {
            try encoded.write(to: storeURL, options: .atomic)
            let check = try Data(contentsOf: storeURL)
            guard check == encoded else { throw AssignmentError.verificationFailed }
        } catch {
            try? original.write(to: storeURL, options: .atomic)
            throw error
        }

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
        try original.write(to: backupURL, options: .atomic)
        try encoded.write(to: storeURL, options: .atomic)
        restartWallpaperAgent()
    }

    private static func restartWallpaperAgent() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["WallpaperAgent"]
        try? process.run()
    }
}
