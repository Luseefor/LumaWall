import AppKit
import SwiftUI

/// In-memory poster thumbnail cache.
///
/// SwiftUI `body` must never do disk IO + image decode (`NSImage(contentsOf:)`
/// blocks the main thread per tile, per stats tick). This actor memoizes
/// decoded posters in an `NSCache` (thread-safe, system-evictable) so repeated
/// `body` evaluations hit memory.
actor PosterCache {
    static let shared = PosterCache()

    private let cache = NSCache<NSURL, NSImage>()

    init() {
        cache.countLimit = 200
    }

    /// Cached poster image, or nil when `url` is nil/unreadable.
    func image(for url: URL?) -> NSImage? {
        guard let url else { return nil }
        let key = url as NSURL
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = NSImage(contentsOf: url) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    func remove(_ url: URL) {
        cache.removeObject(forKey: url as NSURL)
    }

    func removeAll() {
        cache.removeAllObjects()
    }
}

/// Async poster image that never blocks `body` on disk IO.
///
/// Loads via `PosterCache` in `.task(id:)` so URL changes cancel prior loads
/// and view reuse can't show a stale poster's image.
struct PosterImage: View {
    let url: URL?
    var contentMode: SwiftUI.ContentMode = .fill

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
        .task(id: url) {
            if let url {
                image = await PosterCache.shared.image(for: url)
            } else {
                image = nil
            }
        }
    }
}
