import Foundation

enum NativeWallpaperAssignmentStore {
    @discardableResult
    static func update(
        root: NSMutableDictionary,
        choiceID: String,
        videoURL: URL,
        displayUUIDs: Set<String>
    ) -> Set<String> {
        var changed = Set<String>()
        if let displays = root["Displays"] as? NSMutableDictionary {
            changed.formUnion(updateDisplays(
                displays, choiceID: choiceID, videoURL: videoURL, targets: displayUUIDs
            ))
        }
        if let spaces = root["Spaces"] as? NSMutableDictionary {
            for value in spaces.allValues {
                guard let space = value as? NSMutableDictionary,
                      let displays = space["Displays"] as? NSMutableDictionary
                else { continue }
                changed.formUnion(updateDisplays(
                    displays, choiceID: choiceID, videoURL: videoURL, targets: displayUUIDs
                ))
            }
        }
        return changed
    }

    private static func updateDisplays(
        _ displays: NSMutableDictionary,
        choiceID: String,
        videoURL: URL,
        targets: Set<String>
    ) -> Set<String> {
        var changed = Set<String>()
        for uuid in targets {
            guard let display = displays[uuid] as? NSMutableDictionary,
                  let desktop = display["Desktop"] as? NSMutableDictionary,
                  let content = desktop["Content"] as? NSMutableDictionary
            else { continue }
            content["Choices"] = [[
                "Configuration": Data(choiceID.utf8),
                "Files": [["relative": videoURL.absoluteString]],
                "Provider": WallpaperHostCapabilities.extensionBundleID,
            ]]
            content["Shuffle"] = NSNull()
            let now = Date()
            desktop["LastSet"] = now
            desktop["LastUse"] = now
            changed.insert(uuid)
        }
        return changed
    }
}
