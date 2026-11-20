// Decides which library video a Settings "remove" request may delete.
//
// On macOS 27.2 the host calls `removeChoiceRequestWithChoiceRequest:` with a
// WallpaperExtensionChoiceRequestXPC (the protocol's extended type encoding
// says so). Its `box` is an XPCBox<WallpaperChoiceRequest>, the same enum the
// add call takes: color, image(URL), imageFolder(URL), screenSaver(module
// URL) and three photo-library string IDs. It's WallpaperSettingsItem's
// optional `choiceRequest`, sent back to the provider when the item is
// removed. None of those cases names a choice or a provider, and
// SettingsProvider sets no `choiceRequest` on its items, so a removal from
// Settings carries nothing that identifies one of our videos. It is refused
// with an error; videos are removed in the app.
//
// A choice ID (WallpaperChoiceIDXPC) wraps a WallpaperChoice.ID whose
// `descriptor` (WallpaperChoiceDescriptor) holds `provider`
// (WallpaperChoiceProviderID, a `rawValue` String), `files` and
// `configuration`. SettingsProvider writes the video ID as the UTF-8
// `configuration`. If a request ever carries such a descriptor, removal goes
// ahead only when the provider is this extension and the configuration names
// a video in the library.

import Foundation

enum ChoiceRemoval {
    enum Target: Equatable {
        /// Delete the library video with this ID.
        case remove(String)
        /// Delete nothing and reply with `refusal.error`.
        case refuse(Refusal)
    }

    enum Refusal: Int, Equatable {
        case noRequest = 1
        /// The request holds no choice descriptor, as every
        /// WallpaperChoiceRequest case does.
        case noChoiceID
        case otherProvider
        case notInLibrary

        /// For the log.
        var reason: String {
            switch self {
            case .noRequest: "no request"
            case .noChoiceID: "the request names no choice (no choice ID or provider)"
            case .otherProvider: "choice belongs to another provider"
            case .notInLibrary: "choice isn't in the library"
            }
        }

        /// The reply to the host. Fixed text, no file names or paths.
        var error: NSError {
            NSError(
                domain: ChoiceRemoval.errorDomain, code: rawValue,
                userInfo: [
                    NSLocalizedDescriptionKey: "LumaWall can't remove this wallpaper here.",
                    NSLocalizedRecoverySuggestionErrorKey: "Remove it in the LumaWall app.",
                ])
        }
    }

    static let errorDomain = "app.lumawall.wallpaper.ChoiceRemoval"

    static func target(in request: Any?, ownProvider: String, isRegistered: (String) -> Bool) -> Target {
        guard let request else { return .refuse(.noRequest) }
        guard let descriptor = findDescriptor(in: request, depth: 0) else {
            return .refuse(.noChoiceID)
        }
        guard descriptor.provider == ownProvider else {
            return .refuse(.otherProvider)
        }
        guard isRegistered(descriptor.identifier) else {
            return .refuse(.notInLibrary)
        }
        return .remove(descriptor.identifier)
    }

    /// The first value in the tree shaped like a WallpaperChoiceDescriptor
    /// (`provider`, `files` and a non-empty UTF-8 `configuration`), read
    /// through `Mirror`.
    private static func findDescriptor(in value: Any, depth: Int) -> (provider: String, identifier: String)? {
        guard depth < 8 else { return nil }
        let children = Mirror(reflecting: value).children
        if children.contains(where: { $0.label == "files" }),
            let configuration = children.first(where: { $0.label == "configuration" })?.value as? Data,
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
