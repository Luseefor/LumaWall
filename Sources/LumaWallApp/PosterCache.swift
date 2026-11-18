import AppKit
import AVFoundation
import SwiftUI

/// In-memory poster cache, limited by decoded bytes as well as count.
///
/// SwiftUI `body` must never do disk IO + image decode, so posters load
/// through this actor, off the main thread, and repeated `body` evaluations hit
/// memory. Posters are decoded at the width the view needs (ImageIO thumbnail),
/// not at source size: a 4K poster is about 32 MB decoded, a 640 px one about
/// 1 MB. The same file at two widths is cached as two entries.
actor PosterCache {
    static let shared = PosterCache()

    /// Pixel widths for the places posters are shown.
    enum Width {
        /// Library cards, tiles, display thumbnails (210-280 pt, 2x).
        static let card: CGFloat = 640
        /// Large previews such as the composition sheet.
        static let large: CGFloat = 1_280
    }

    private struct Key: Hashable {
        let url: URL
        let width: Int
    }

    private struct Entry {
        let image: NSImage
        let bytes: Int
    }

    private let maxBytes: Int
    private let maxCount: Int
    private var entries: [Key: Entry] = [:]
    /// Least recently used first.
    private var order: [Key] = []
    private(set) var totalBytes = 0

    init(maxBytes: Int = 96 * 1_024 * 1_024, maxCount: Int = 200) {
        self.maxBytes = maxBytes
        self.maxCount = maxCount
    }

    /// Poster decoded to at most `maxPixelWidth` wide. When the poster is nil,
    /// missing or unreadable and `fallbackVideo` is given, a still frame from
    /// that video at the same width stands in, cached under the video's URL.
    /// Returns nil when neither yields an image. Frame generation runs off the
    /// actor, so other loads proceed meanwhile.
    func image(for url: URL?, fallbackVideo: URL? = nil, maxPixelWidth: CGFloat = Width.card) async -> NSImage? {
        let width = Int(maxPixelWidth)
        let keys = [url, fallbackVideo].compactMap { $0 }.map { Key(url: $0, width: width) }
        for key in keys {
            if let entry = entries[key] {
                touch(key)
                return entry.image
            }
        }
        if let url, let cgImage = Self.decode(url, maxPixelWidth: maxPixelWidth) {
            return store(cgImage, for: Key(url: url, width: width))
        }
        guard let fallbackVideo, let frame = await Self.videoFrame(fallbackVideo, maxPixelWidth: maxPixelWidth) else { return nil }
        let key = Key(url: fallbackVideo, width: width)
        // Another caller may have stored this frame while we awaited.
        if let entry = entries[key] { return entry.image }
        return store(frame, for: key)
    }

    func contains(_ url: URL, maxPixelWidth: CGFloat) -> Bool {
        entries[Key(url: url, width: Int(maxPixelWidth))] != nil
    }

    /// Drops every cached size of `url`.
    func remove(_ url: URL) {
        for key in order where key.url == url { drop(key) }
    }

    func removeAll() {
        entries.removeAll()
        order.removeAll()
        totalBytes = 0
    }

    /// Caches `cgImage` unless it alone is over the byte budget, in which case
    /// the caller still gets the image but the cache holds nothing for it.
    private func store(_ cgImage: CGImage, for key: Key) -> NSImage {
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        let bytes = Self.decodedBytes(of: cgImage)
        guard bytes <= maxBytes else { return image }
        entries[key] = Entry(image: image, bytes: bytes)
        order.append(key)
        totalBytes += bytes
        evict()
        return image
    }

    /// Real memory of the decoded bitmap, including any row padding.
    nonisolated static func decodedBytes(of image: CGImage) -> Int {
        image.bytesPerRow * image.height
    }

    private func touch(_ key: Key) {
        if let index = order.firstIndex(of: key) { order.remove(at: index) }
        order.append(key)
    }

    private func drop(_ key: Key) {
        if let entry = entries.removeValue(forKey: key) { totalBytes -= entry.bytes }
        order.removeAll { $0 == key }
    }

    /// Evicts least recently used posters until under both limits.
    private func evict() {
        while totalBytes > maxBytes || entries.count > maxCount, let oldest = order.first {
            drop(oldest)
        }
    }

    /// The longest-edge pixel limit that makes the decoded image
    /// `targetWidth` wide, never larger than the source. Views aspect-fill by
    /// width, so a portrait poster needs the long edge scaled up with it.
    nonisolated static func maxPixelSize(sourceSize: CGSize, targetWidth: CGFloat) -> CGFloat {
        guard sourceSize.width > 0, sourceSize.height > 0 else { return targetWidth }
        let longEdge = max(sourceSize.width, sourceSize.height)
        let scale = min(targetWidth / sourceSize.width, 1)
        return (longEdge * scale).rounded()
    }

    /// A frame from near the start of `url`, at most `maxPixelWidth` wide.
    nonisolated private static func videoFrame(_ url: URL, maxPixelWidth: CGFloat) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // Fits inside the box, so a portrait video still gets its width.
        generator.maximumSize = CGSize(width: maxPixelWidth, height: maxPixelWidth * 4)
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let seconds = duration.isFinite && duration > 0 ? min(1, duration / 2) : 0
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        return try? await generator.image(at: time).image
    }

    nonisolated private static func decode(_ url: URL, maxPixelWidth: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize(sourceSize: CGSize(width: width, height: height), targetWidth: maxPixelWidth)
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// Async poster image that never blocks `body` on disk IO.
///
/// Loads via `PosterCache` in `.task(id:)` so URL changes cancel prior loads
/// and view reuse can't show a stale poster's image.
struct PosterImage: View {
    let url: URL?
    var contentMode: SwiftUI.ContentMode = .fill
    /// Original video to take a still from when the poster is missing or
    /// unreadable, so the card isn't blank for a wallpaper that plays fine.
    var fallbackVideo: URL?
    /// Decode width in pixels; see `PosterCache.Width`.
    var maxPixelWidth: CGFloat = PosterCache.Width.card

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                Theme.panelStrong
            }
        }
        .task(id: PosterRequest(url: url, fallbackVideo: fallbackVideo, width: maxPixelWidth)) {
            if url != nil || fallbackVideo != nil {
                image = await PosterCache.shared.image(for: url, fallbackVideo: fallbackVideo, maxPixelWidth: maxPixelWidth)
            } else {
                image = nil
            }
        }
    }
}

private struct PosterRequest: Equatable {
    let url: URL?
    let fallbackVideo: URL?
    let width: CGFloat
}
