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
            changed.formUnion(updateDisplays(
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
                changed.formUnion(updateDisplays(
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
        content["Choices"] = [[
            "Configuration": Data(choiceID.utf8),
            "Files": [["relative": videoURL.absoluteString]],
            "Provider": WallpaperHostCapabilities.extensionBundleID,
        ]]
        content["Shuffle"] = NSNull()
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
