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
    /// when none is wide enough.
    static func previewVariant(_ variants: [NativeVideoVariant], minPixelWidth: CGFloat) -> NativeVideoVariant? {
        variants
            .filter { $0.resolution.width >= minPixelWidth }
            .min { $0.resolution.width < $1.resolution.width }
    }

    /// File to play for a preview of a deployed wallpaper. Falls back to
    /// `fallback` (the library original) when the wallpaper isn't deployed,
    /// has no wide-enough copy, or the copy is missing on disk.
    static func previewURL(
        entryID: String,
        minPixelWidth: CGFloat,
        fallback: URL,
        videosFolderURL: URL = videosFolderURL
    ) -> URL {
        guard PathSafety.isValidEntryID(entryID),
              let entry = try? entry(id: entryID, videosFolderURL: videosFolderURL),
              let variant = previewVariant(entry.variants ?? [], minPixelWidth: minPixelWidth)
        else { return fallback }
        let url = videosFolderURL
            .appendingPathComponent(entryID, isDirectory: true)
            .appendingPathComponent(variant.filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : fallback
    }

    /// Preview file for a library asset.
    static func previewURL(for asset: WallpaperAsset, minPixelWidth: CGFloat) -> URL {
        previewURL(entryID: asset.id.rawValue.uuidString, minPixelWidth: minPixelWidth, fallback: asset.mediaURL)
    }
}
