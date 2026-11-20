import Foundation

enum NativeWallpaperAssignmentStore {
    @discardableResult
    static func update(
        root: NSMutableDictionary,
        choiceID: String,
        videoURL: URL,
        displayUUIDs: Set<String>,
        includeLockScreen: Bool = false
    ) -> Set<String> {
        var changed = Set<String>()
        if let displays = root["Displays"] as? NSMutableDictionary {
            changed.formUnion(
                updateDisplays(
                    displays,
                    choiceID: choiceID,
                    videoURL: videoURL,
                    targets: displayUUIDs,
                    includeLockScreen: includeLockScreen
                ))
        }
        if let spaces = root["Spaces"] as? NSMutableDictionary {
            for value in spaces.allValues {
                guard let space = value as? NSMutableDictionary,
                    let displays = space["Displays"] as? NSMutableDictionary
                else { continue }
                changed.formUnion(
                    updateDisplays(
                        displays,
                        choiceID: choiceID,
                        videoURL: videoURL,
                        targets: displayUUIDs,
                        includeLockScreen: includeLockScreen
                    ))
            }
        }
        return changed
    }

    private static func updateDisplays(
        _ displays: NSMutableDictionary,
        choiceID: String,
        videoURL: URL,
        targets: Set<String>,
        includeLockScreen: Bool
    ) -> Set<String> {
        var changed = Set<String>()
        for uuid in targets {
            guard let display = displays[uuid] as? NSMutableDictionary else { continue }
            if updateSurface(display["Desktop"] as? NSMutableDictionary, choiceID: choiceID, videoURL: videoURL) {
                changed.insert(uuid)
            }
            if includeLockScreen {
                _ = updateSurface(display["Idle"] as? NSMutableDictionary, choiceID: choiceID, videoURL: videoURL)
            }
        }
        return changed
    }

    @discardableResult
    private static func updateSurface(
        _ surface: NSMutableDictionary?,
        choiceID: String,
        videoURL: URL
    ) -> Bool {
        guard let surface,
            let content = surface["Content"] as? NSMutableDictionary
        else { return false }
        content["Choices"] = [
            [
                "Configuration": Data(choiceID.utf8),
                "Files": [["relative": videoURL.absoluteString]],
                "Provider": WallpaperHostCapabilities.extensionBundleID,
            ]
        ]
        // Apple's wallpaper store uses the literal sentinel "$null". NSNull is
        // not a property-list value and makes PropertyListSerialization fail
        // with the misleading "error in the destination for the data" message.
        content["Shuffle"] = "$null"
        let now = Date()
        surface["LastSet"] = now
        surface["LastUse"] = now
        return true
    }

    static func updateIdleEverywhere(
        root: NSMutableDictionary,
        choiceID: String,
        videoURL: URL
    ) {
        func walkDisplays(_ displays: NSMutableDictionary) {
            for value in displays.allValues {
                guard let display = value as? NSMutableDictionary else { continue }
                _ = updateSurface(display["Idle"] as? NSMutableDictionary, choiceID: choiceID, videoURL: videoURL)
            }
        }
        if let displays = root["Displays"] as? NSMutableDictionary {
            walkDisplays(displays)
        }
        if let spaces = root["Spaces"] as? NSMutableDictionary {
            for value in spaces.allValues {
                guard let space = value as? NSMutableDictionary,
                    let displays = space["Displays"] as? NSMutableDictionary
                else { continue }
                walkDisplays(displays)
            }
        }
    }
}

// MARK: Backup and restore

extension NativeWallpaperAssignmentStore {
    /// Key paths to every surface in the store: any dictionary whose
    /// `Content` holds `Choices` (Desktop and Idle, per display and per Space).
    static func surfacePaths(in root: NSDictionary) -> [[String]] {
        var paths: [[String]] = []
        func walk(_ dictionary: NSDictionary, _ path: [String]) {
            if (dictionary["Content"] as? NSDictionary)?["Choices"] != nil {
                paths.append(path)
                return
            }
            for case let (key as String, child as NSDictionary) in dictionary {
                walk(child, path + [key])
            }
        }
        walk(root, [])
        return paths
    }

    /// LumaWall's library, whose posters the overlay sets as the desktop
    /// picture, and the wallpaper extension's container.
    static var lumaWallFolders: [URL] {
        [
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("LumaWall", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Containers/\(WallpaperHostCapabilities.extensionBundleID)", isDirectory: true),
        ]
    }

    /// True when the surface shows a LumaWall choice: the extension's, or an
    /// image from one of `ownedFolders` (the overlay's poster).
    static func isOurs(_ surface: NSDictionary, ownedFolders: [URL] = []) -> Bool {
        let choices = (surface["Content"] as? NSDictionary)?["Choices"] as? [NSDictionary] ?? []
        let prefixes = ownedFolders.map { $0.standardizedFileURL.path + "/" }
        return choices.contains { choice in
            if choice["Provider"] as? String == WallpaperHostCapabilities.extensionBundleID { return true }
            let files = choice["Files"] as? [NSDictionary] ?? []
            return files.contains { file in
                guard let relative = file["relative"] as? String, let url = URL(string: relative), url.isFileURL else {
                    return false
                }
                let path = url.standardizedFileURL.path
                return prefixes.contains { path.hasPrefix($0) }
            }
        }
    }

    /// The backup to save before writing `current`: the previous backup
    /// with every surface that isn't LumaWall's updated from `current`.
    static func mergeBackup(existing: NSDictionary?, current: NSDictionary, ownedFolders: [URL]) -> NSMutableDictionary {
        guard let existing else { return deepMutableCopy(current) }
        let merged = deepMutableCopy(existing)
        for path in surfacePaths(in: current) {
            guard let surface = value(at: path, in: current) as? NSDictionary, !isOurs(surface, ownedFolders: ownedFolders)
            else { continue }
            set(deepMutableCopy(surface), at: path, in: merged)
        }
        return merged
    }

    /// Replaces each LumaWall surface in `root` with the backup's surface at
    /// the same path, when the backup has one that isn't LumaWall's.
    static func restoreOriginal(
        root: NSMutableDictionary, backup: NSDictionary, ownedFolders: [URL]
    ) -> NativeWallpaperAssignmentService.RestoreResult {
        var result = NativeWallpaperAssignmentService.RestoreResult(restored: 0, missing: 0)
        for path in surfacePaths(in: root) {
            guard let surface = value(at: path, in: root) as? NSDictionary, isOurs(surface, ownedFolders: ownedFolders)
            else { continue }
            if let saved = value(at: path, in: backup) as? NSDictionary, !isOurs(saved, ownedFolders: ownedFolders) {
                set(deepMutableCopy(saved), at: path, in: root)
                result.restored += 1
            } else {
                result.missing += 1
            }
        }
        return result
    }

    private static func value(at path: [String], in root: NSDictionary) -> Any? {
        var node: Any? = root
        for key in path { node = (node as? NSDictionary)?[key] }
        return node
    }

    /// Sets `value` at `path`, creating missing parent dictionaries.
    private static func set(_ value: Any, at path: [String], in root: NSMutableDictionary) {
        guard let last = path.last else { return }
        var node = root
        for key in path.dropLast() {
            if let child = node[key] as? NSMutableDictionary {
                node = child
            } else {
                let child = NSMutableDictionary()
                node[key] = child
                node = child
            }
        }
        node[last] = value
    }

    private static func deepMutableCopy(_ dictionary: NSDictionary) -> NSMutableDictionary {
        let copy = CFPropertyListCreateDeepCopy(
            kCFAllocatorDefault, dictionary, CFOptionFlags(CFPropertyListMutabilityOptions.mutableContainersAndLeaves.rawValue))
        return copy as? NSMutableDictionary ?? NSMutableDictionary(dictionary: dictionary)
    }
}
