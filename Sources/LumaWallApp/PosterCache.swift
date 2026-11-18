import AppKit
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

    /// Poster decoded to at most `maxPixelWidth` wide, or nil when `url` is
    /// nil or unreadable.
    func image(for url: URL?, maxPixelWidth: CGFloat = Width.card) -> NSImage? {
        guard let url else { return nil }
        let key = Key(url: url, width: Int(maxPixelWidth))
        if let entry = entries[key] {
            touch(key)
            return entry.image
        }
        guard let cgImage = Self.decode(url, maxPixelWidth: maxPixelWidth) else { return nil }
        let bytes = cgImage.width * cgImage.height * 4
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        entries[key] = Entry(image: image, bytes: bytes)
        order.append(key)
        totalBytes += bytes
        evict(keeping: key)
        return image
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

    private func touch(_ key: Key) {
        if let index = order.firstIndex(of: key) { order.remove(at: index) }
        order.append(key)
    }

    private func drop(_ key: Key) {
        if let entry = entries.removeValue(forKey: key) { totalBytes -= entry.bytes }
        order.removeAll { $0 == key }
    }

    /// Evicts least recently used posters until under both limits. The poster
    /// just loaded stays even if it alone exceeds the byte limit.
    private func evict(keeping newest: Key) {
        while (totalBytes > maxBytes || entries.count > maxCount), let oldest = order.first, oldest != newest {
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
        .task(id: PosterRequest(url: url, width: maxPixelWidth)) {
            if let url {
                image = await PosterCache.shared.image(for: url, maxPixelWidth: maxPixelWidth)
            } else {
                image = nil
            }
        }
    }
}

private struct PosterRequest: Equatable {
    let url: URL?
    let width: CGFloat
}
