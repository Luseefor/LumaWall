import Foundation
import LumaWallCore

/// In-app previews (hero, tiles, menu bar) play the smallest deployed copy that
/// is still wide enough, instead of decoding the 4K original for a small view.
extension NativeWallpaperDeployment {
    /// Pixel widths callers ask for. The hero accepts the 1080p copy: it sits
    /// under a dark gradient, and decoding 4K for it cost more than the rest of
    /// the window together.
    enum PreviewSize {
        static let hero: CGFloat = 1_920
        static let sheet: CGFloat = 1_920
        static let thumbnail: CGFloat = 640
    }

    /// The narrowest variant whose width is at least `minPixelWidth`, or nil
    /// when none is wide enough. Width, not the long edge: every preview box
    /// is landscape, and aspect-filling one scales a portrait video by width,
    /// so a 1080-wide portrait copy would be blurry in a 1920-wide hero.
    static func previewVariant(_ variants: [NativeVideoVariant], minPixelWidth: CGFloat) -> NativeVideoVariant? {
        variants
            .filter { $0.resolution.width >= minPixelWidth }
            .min { $0.resolution.width < $1.resolution.width }
    }

    /// What a preview should show.
    enum PreviewPlan: Equatable {
        /// Play a deployed copy.
        case copy(NativeVideoVariant)
        /// Play the library original (hero and sheet only).
        case original
        /// Show the poster image instead of playing video.
        case poster
    }

    /// Decides what a preview of the given width shows. A thumbnail-size
    /// preview (`allowsOriginal == false`) with no wide-enough copy shows the
    /// poster: decoding a 4K original for a ~300 pt tile costs far more than
    /// the tile is worth.
    static func previewPlan(_ variants: [NativeVideoVariant], minPixelWidth: CGFloat, allowsOriginal: Bool) -> PreviewPlan {
        if let variant = previewVariant(variants, minPixelWidth: minPixelWidth) { return .copy(variant) }
        return allowsOriginal ? .original : .poster
    }

    /// Parsed metadata per entry, reused until metadata.json changes. Preview
    /// URLs are resolved inside SwiftUI view bodies, which re-run often.
    private struct MetadataStamp: Equatable {
        var modified: Date?
        var size: Int?
    }

    @MainActor
    private static var metadataCache: [String: (stamp: MetadataStamp, entry: EntryInfo?)] = [:]

    @MainActor
    private static func cachedEntry(id: String, videosFolderURL: URL) -> EntryInfo? {
        let metadata =
            videosFolderURL
            .appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent("metadata.json")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: metadata.path) else {
            metadataCache[metadata.path] = nil
            return nil
        }
        let stamp = MetadataStamp(
            modified: attributes[.modificationDate] as? Date,
            size: (attributes[.size] as? NSNumber)?.intValue
        )
        if let cached = metadataCache[metadata.path], cached.stamp == stamp { return cached.entry }
        let entry = try? entry(id: id, videosFolderURL: videosFolderURL)
        metadataCache[metadata.path] = (stamp, entry)
        return entry
    }

    /// File to play for a preview of a deployed wallpaper, or nil when the
    /// plan is not a copy that exists on disk.
    @MainActor
    private static func copyURL(
        entryID: String,
        minPixelWidth: CGFloat,
        allowsOriginal: Bool,
        videosFolderURL: URL
    ) -> (plan: PreviewPlan, url: URL?) {
        guard PathSafety.isValidEntryID(entryID),
            let entry = cachedEntry(id: entryID, videosFolderURL: videosFolderURL)
        else { return (allowsOriginal ? .original : .poster, nil) }
        let plan = previewPlan(entry.variants ?? [], minPixelWidth: minPixelWidth, allowsOriginal: allowsOriginal)
        guard case .copy(let variant) = plan else { return (plan, nil) }
        let url =
            videosFolderURL
            .appendingPathComponent(entryID, isDirectory: true)
            .appendingPathComponent(variant.filename)
        if FileManager.default.fileExists(atPath: url.path) { return (plan, url) }
        return (allowsOriginal ? .original : .poster, nil)
    }

    /// File to play for a hero or sheet preview. Falls back to `fallback` (the
    /// library original) when the wallpaper isn't deployed, has no wide-enough
    /// copy, or the copy is missing on disk.
    @MainActor
    static func previewURL(
        entryID: String,
        minPixelWidth: CGFloat,
        fallback: URL,
        videosFolderURL: URL = videosFolderURL
    ) -> URL {
        copyURL(entryID: entryID, minPixelWidth: minPixelWidth, allowsOriginal: true, videosFolderURL: videosFolderURL).url ?? fallback
    }

    /// File to play for a thumbnail-size preview (tiles, popover), or nil
    /// when the poster should be shown instead of decoding the original.
    @MainActor
    static func thumbnailPreviewURL(
        entryID: String,
        minPixelWidth: CGFloat = PreviewSize.thumbnail,
        videosFolderURL: URL = videosFolderURL
    ) -> URL? {
        copyURL(entryID: entryID, minPixelWidth: minPixelWidth, allowsOriginal: false, videosFolderURL: videosFolderURL).url
    }

    /// Preview file for a library asset.
    @MainActor
    static func previewURL(for asset: WallpaperAsset, minPixelWidth: CGFloat) -> URL {
        previewURL(entryID: asset.id.rawValue.uuidString, minPixelWidth: minPixelWidth, fallback: asset.mediaURL)
    }

    /// Thumbnail preview file for a library asset, nil to show the poster.
    @MainActor
    static func thumbnailPreviewURL(for asset: WallpaperAsset) -> URL? {
        thumbnailPreviewURL(entryID: asset.id.rawValue.uuidString)
    }
}
