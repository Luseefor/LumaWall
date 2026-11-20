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
// Settings carries nothing that identifies one of our videos. Video items
// are marked not removable (VideoSettingsItem), so Settings doesn't offer
// Remove; a request that arrives anyway is refused with an error. Videos
// are removed in the app.
//
// A choice ID (WallpaperChoiceIDXPC) wraps a WallpaperChoice.ID whose
// `descriptor` (WallpaperChoiceDescriptor) holds `provider`
// (WallpaperChoiceProviderID, a `rawValue` String), `files` and
// `configuration`. SettingsProvider writes the video ID as the UTF-8
// `configuration`. If a request ever carries such a descriptor, removal goes
// ahead only when the provider is this extension and the configuration names
// a video in the library. Only that exact path is read.

import Foundation

enum ChoiceRemoval {
    enum Target: Equatable {
        /// Delete the library video with this ID.
        case remove(String)
        /// Delete nothing and reply with `refusal.error`.
        case refuse(Refusal)
    }

    /// Why a remove request deleted nothing.
    enum Refusal: Int, Equatable {
        case noRequest = 1
        /// The request holds no choice descriptor, as every
        /// WallpaperChoiceRequest case does.
        case noChoiceID
        case otherProvider
        case notInLibrary
        /// The video was registered but its folder couldn't be deleted.
        case deleteFailed

        /// For the log.
        var reason: String {
            switch self {
            case .noRequest: "no request"
            case .noChoiceID: "the request names no choice (no choice ID or provider)"
            case .otherProvider: "choice belongs to another provider"
            case .notInLibrary: "choice isn't in the library"
            case .deleteFailed: "the video's folder couldn't be deleted"
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
        guard let descriptor = findDescriptor(in: request) else {
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

    /// The descriptor of a WallpaperChoiceIDXPC, read through `Mirror`
    /// along its one path: `box` (XPCBox) → `rawValue` (WallpaperChoice.ID)
    /// → `descriptor`, whose `provider` is a `rawValue` String, `files` a
    /// URL array and `configuration` non-empty UTF-8. No other field is
    /// searched, so a look-alike value nested elsewhere doesn't count.
    private static func findDescriptor(in request: Any) -> (provider: String, identifier: String)? {
        guard let box = child("box", of: request), let id = child("rawValue", of: box),
            let descriptor = child("descriptor", of: id),
            child("files", of: descriptor) is [URL],
            let configuration = child("configuration", of: descriptor) as? Data,
            let identifier = String(data: configuration, encoding: .utf8), !identifier.isEmpty,
            let providerID = child("provider", of: descriptor),
            let provider = child("rawValue", of: providerID) as? String
        else { return nil }
        return (provider, identifier)
    }

    private static func child(_ label: String, of value: Any) -> Any? {
        Mirror(reflecting: value).children.first { $0.label == label }?.value
    }
}
