import Foundation

/// The System Settings tile for one library video.
///
/// It is marked not removable (`.none`), so Settings offers no Remove for
/// it. Settings' removal request never names the wallpaper (see
/// ChoiceRemoval), so a Remove there always failed; videos are removed in
/// the LumaWall app.
func makeVideoSettingsItem(
    bundleID: String,
    entryID: String,
    name: String,
    videoURL: URL,
    thumbnailURL: URL,
    contextMenu: ContextMenu
) -> SettingsItem {
    let choiceID = ChoiceID(
        id: entryID,
        descriptor: ChoiceIDDescriptor(
            provider: ChoiceProviderID(rawValue: bundleID),
            identifier: entryID,
            files: [videoURL],
            configuration: Data(entryID.utf8),
        ),
    )
    return SettingsItem(
        id: choiceID,
        localizedName: name,
        thumbnail: .image(url: thumbnailURL),
        choice: ChoiceDescriptor(
            id: choiceID,
            provider: ChoiceProviderID(rawValue: bundleID),
            identifier: entryID,
            name: name,
            localizedDescription: "Animated video wallpaper",
            thumbnail: .image(url: thumbnailURL),
            isDownloaded: true,
            options: [],
        ),
        contentBadge: .video,
        showInTopLevel: true,
        sortOrder: 0,
        disposability: .none,
        contextMenu: contextMenu,
    )
}
