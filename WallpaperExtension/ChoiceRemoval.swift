// Decides which library video a Settings "remove" request may delete.
//
// A choice ID (WallpaperChoiceIDXPC) wraps a WallpaperChoice.ID whose
// `descriptor` holds `provider` (WallpaperChoiceProviderID, a `rawValue`
// String), `files` and `configuration`, per WallpaperTypes' Swift metadata on
// macOS 27.2. SettingsProvider writes the video ID as the UTF-8
// `configuration`. Removal goes ahead only when the provider is this extension
// and the configuration names a video in the library. Scanning the request's
// description for `identifier: "` could pick up any field that contained that
// text. A request that holds no descriptor, such as the add-style
// WallpaperChoiceRequest enum, deletes nothing.

import Foundation

enum ChoiceRemoval {
    enum Target: Equatable {
        /// Delete the library video with this ID.
        case remove(String)
        /// Delete nothing; the reason is logged.
        case refuse(String)
    }

    static func target(in request: Any, ownProvider: String, isRegistered: (String) -> Bool) -> Target {
        guard let descriptor = findDescriptor(in: request, depth: 0) else {
            return .refuse("no choice descriptor in request")
        }
        guard descriptor.provider == ownProvider else {
            return .refuse("choice belongs to another provider")
        }
        guard isRegistered(descriptor.identifier) else {
            return .refuse("choice isn't in the library")
        }
        return .remove(descriptor.identifier)
    }

    /// The first value in the tree with a `provider` and a non-empty UTF-8
    /// `configuration`, read through `Mirror`.
    private static func findDescriptor(in value: Any, depth: Int) -> (provider: String, identifier: String)? {
        guard depth < 8 else { return nil }
        let children = Mirror(reflecting: value).children
        if let configuration = children.first(where: { $0.label == "configuration" })?.value as? Data,
            let identifier = String(data: configuration, encoding: .utf8), !identifier.isEmpty,
            let provider = children.first(where: { $0.label == "provider" }).flatMap({ firstString(in: $0.value, depth: 0) })
        {
            return (provider, identifier)
        }
        for child in children {
            if let found = findDescriptor(in: child.value, depth: depth + 1) { return found }
        }
        return nil
    }

    /// A provider ID is a String or wraps one (`ChoiceProviderID.rawValue`).
    private static func firstString(in value: Any, depth: Int) -> String? {
        if let string = value as? String { return string }
        guard depth < 3 else { return nil }
        for child in Mirror(reflecting: value).children {
            if let found = firstString(in: child.value, depth: depth + 1) { return found }
        }
        return nil
    }
}
