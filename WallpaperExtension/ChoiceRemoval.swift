// Decides which library video a Settings "remove" request may delete.
//
// The request is a private WallpaperKit XPC object. Its choice descriptor
// (`rawValue.descriptor`, see ChoiceIDDescriptor in CodableShims) carries the
// provider that owns the choice and the choice's identifier. Removal goes ahead
// only when both are read from that descriptor, the provider is this extension,
// and the identifier is a video in the library. Scanning the request's
// description for `identifier: "` could pick up any field that happened to
// contain that text.

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

    /// The first value in the tree with a `provider` and a String
    /// `identifier`, read through `Mirror`.
    private static func findDescriptor(in value: Any, depth: Int) -> (provider: String, identifier: String)? {
        guard depth < 8 else { return nil }
        let children = Mirror(reflecting: value).children
        if let identifier = children.first(where: { $0.label == "identifier" })?.value as? String,
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
