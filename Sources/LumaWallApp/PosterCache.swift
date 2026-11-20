import AppKit
import AVFoundation
import LumaWallCore
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

    /// Makes a still from a video at a pixel width; nil when it can't.
    /// Throwing `MediaProbeError.serviceUnavailable` means the media service
    /// was busy or went away, not that the video can't be read: the cache
    /// tries again and doesn't remember it as a failure.
    typealias FrameGenerator = @Sendable (URL, CGFloat) async throws -> CGImage?

    private enum FrameOutcome {
        case frame(CGImage)
        case failed
        case busy
    }

    /// A poster that failed to decode, with the file's state at the time, so
    /// a poster written or replaced later no longer matches and is tried again.
    private struct FailedPoster: Hashable {
        let key: Key
        let stamp: PosterStamp
        /// Hash of the file's first and last few KB. A file rewritten in place
        /// can keep its size, modification time and inode, but not its content.
        let content: Int
    }

    /// Kept apart from poster failures: the frame generation for a video is
    /// shared by every request that names it, whatever its poster is.
    private struct PosterStamp: Hashable {
        let modified: Date?
        let size: Int?
        let fileNumber: Int?
    }

    /// What `remove` and `removeAll` had done when work for a request began.
    private struct Epoch: Equatable {
        let clears: Int
        let removals: Int
    }

    private struct InFlight {
        let id: Int
        let task: Task<FrameOutcome, Never>
    }

    private let maxBytes: Int
    private let maxCount: Int
    private let maxFailures = 256
    private let frameGenerator: FrameGenerator
    /// Waits before each retry of a still the media service was too busy for.
    private let retryDelays: [Duration]
    private var inFlightFrames: [Key: InFlight] = [:]
    private var nextTaskID = 0
    /// `removeAll` count, and how often `remove` ran for each URL. Work that
    /// began before either changed finished for a file that may be different
    /// now, so it must not record a failure or cache a frame.
    private var clears = 0
    private var removals: [URL: Int] = [:]
    /// Oldest first; bounded so a library full of broken files can't grow them.
    private var failedPosters: [FailedPoster] = []
    private var failedFrames: [Key] = []
    private var entries: [Key: Entry] = [:]
    /// Least recently used first.
    private var order: [Key] = []
    private(set) var totalBytes = 0

    init(
        maxBytes: Int = 96 * 1_024 * 1_024,
        maxCount: Int = 200,
        frameGenerator: @escaping FrameGenerator = { try await PosterCache.videoFrame($0, maxPixelWidth: $1) },
        retryDelays: [Duration] = [.seconds(1), .seconds(3), .seconds(8)]
    ) {
        self.maxBytes = maxBytes
        self.maxCount = maxCount
        self.frameGenerator = frameGenerator
        self.retryDelays = retryDelays
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
        // The poster is checked first, so one that appears later shows up
        // even while the video's still is known to fail.
        if let url {
            let posterKey = Key(url: url, width: width)
            let stamp = Self.stamp(of: url)
            // Read the content only when a failure already matches the cheap
            // stamp, so a poster that has not failed costs no extra IO.
            let known = failedPosters.contains { $0.key == posterKey && $0.stamp == stamp }
            let content = known ? Self.contentHash(of: url) : 0
            if !failedPosters.contains(where: { $0.key == posterKey && $0.stamp == stamp && $0.content == content }) {
                if let cgImage = Self.decode(url, maxPixelWidth: maxPixelWidth) {
                    return store(cgImage, for: posterKey)
                }
                remember(FailedPoster(key: posterKey, stamp: stamp, content: known ? content : Self.contentHash(of: url)))
            }
        }
        guard let fallbackVideo else { return nil }
        let key = Key(url: fallbackVideo, width: width)
        if failedFrames.contains(key) { return nil }
        let startedAt = epoch(of: fallbackVideo)
        var outcome = await frame(for: fallbackVideo, key: key, maxPixelWidth: maxPixelWidth)
        // A busy service is retried a few times; past that the request
        // returns nil without a remembered failure, so the next one tries.
        for delay in retryDelays {
            guard case .busy = outcome, !Task.isCancelled else { break }
            try? await Task.sleep(for: delay)
            // While this waited, another request may have cached the frame or
            // found it can't be made, or `remove` may have run.
            if Task.isCancelled || startedAt != epoch(of: fallbackVideo) { break }
            if let entry = entries[key] {
                touch(key)
                return entry.image
            }
            if failedFrames.contains(key) { return nil }
            outcome = await frame(for: fallbackVideo, key: key, maxPixelWidth: maxPixelWidth)
        }
        let frame: CGImage?
        switch outcome {
        case .frame(let image): frame = image
        case .failed, .busy: frame = nil
        }
        // `remove` ran while we waited: the file may be different now, so
        // neither the failure nor the frame describes it.
        guard startedAt == epoch(of: fallbackVideo) else { return frame.map(Self.image) }
        guard let frame else {
            if case .failed = outcome { remember(key) }
            return nil
        }
        // Another caller may have stored this frame while we awaited.
        if let entry = entries[key] { return entry.image }
        return store(frame, for: key)
    }

    /// One generation per video and width: concurrent requests await the same
    /// task. The entry is cleared only by the task that owns it, so a task that
    /// `remove` already replaced can't clear its successor.
    private func frame(for video: URL, key: Key, maxPixelWidth: CGFloat) async -> FrameOutcome {
        if let running = inFlightFrames[key] { return await running.task.value }
        let generate = frameGenerator
        let task = Task.detached { () -> FrameOutcome in
            do {
                return try await generate(video, maxPixelWidth).map(FrameOutcome.frame) ?? .failed
            } catch MediaProbeError.serviceUnavailable {
                return .busy
            } catch {
                return .failed
            }
        }
        nextTaskID += 1
        let id = nextTaskID
        inFlightFrames[key] = InFlight(id: id, task: task)
        let frame = await task.value
        if inFlightFrames[key]?.id == id { inFlightFrames[key] = nil }
        return frame
    }

    private func epoch(of url: URL) -> Epoch {
        Epoch(clears: clears, removals: removals[url, default: 0])
    }

    private func remember(_ failed: FailedPoster) {
        guard !failedPosters.contains(failed) else { return }
        failedPosters.append(failed)
        if failedPosters.count > maxFailures { failedPosters.removeFirst(failedPosters.count - maxFailures) }
    }

    private func remember(_ key: Key) {
        guard !failedFrames.contains(key) else { return }
        failedFrames.append(key)
        if failedFrames.count > maxFailures { failedFrames.removeFirst(failedFrames.count - maxFailures) }
    }

    func contains(_ url: URL, maxPixelWidth: CGFloat) -> Bool {
        entries[Key(url: url, width: Int(maxPixelWidth))] != nil
    }

    /// Drops every cached size of `url`.
    func remove(_ url: URL) {
        removals[url, default: 0] += 1
        for key in order where key.url == url { drop(key) }
        for key in inFlightFrames.keys where key.url == url { inFlightFrames[key] = nil }
        failedPosters.removeAll { $0.key.url == url }
        failedFrames.removeAll { $0.url == url }
    }

    func removeAll() {
        clears += 1
        removals.removeAll()
        inFlightFrames.removeAll()
        entries.removeAll()
        order.removeAll()
        failedPosters.removeAll()
        failedFrames.removeAll()
        totalBytes = 0
    }

    /// Caches `cgImage` unless it alone is over the byte budget, in which case
    /// the caller still gets the image but the cache holds nothing for it.
    private func store(_ cgImage: CGImage, for key: Key) -> NSImage {
        let image = Self.image(cgImage)
        let bytes = Self.decodedBytes(of: cgImage)
        guard bytes <= maxBytes else { return image }
        entries[key] = Entry(image: image, bytes: bytes)
        order.append(key)
        totalBytes += bytes
        evict()
        return image
    }

    nonisolated private static func image(_ cgImage: CGImage) -> NSImage {
        NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    nonisolated private static func stamp(of url: URL) -> PosterStamp {
        // Not `URL.resourceValues`, which can return values cached on the URL.
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return PosterStamp(
            modified: attributes?[.modificationDate] as? Date,
            size: (attributes?[.size] as? NSNumber)?.intValue,
            fileNumber: (attributes?[.systemFileNumber] as? NSNumber)?.intValue
        )
    }

    /// Hash of the first and last 4 KB; 0 when the file can't be read.
    nonisolated private static func contentHash(of url: URL) -> Int {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return 0 }
        defer { try? handle.close() }
        let span = 4_096
        var hasher = Hasher()
        if let head = try? handle.read(upToCount: span) { hasher.combine(head) }
        if let end = try? handle.seekToEnd(), end > UInt64(span) {
            try? handle.seek(toOffset: max(end - UInt64(span), UInt64(span)))
            if let tail = try? handle.read(upToCount: span) { hasher.combine(tail) }
        }
        return hasher.finalize()
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

    /// A frame from near the start of `url`, at most `maxPixelWidth` wide,
    /// read by the sandboxed media service. Throws only
    /// `MediaProbeError.serviceUnavailable`: the service refused the request
    /// as over its limit, timed out, or its connection dropped.
    nonisolated static func videoFrame(_ url: URL, maxPixelWidth: CGFloat) async throws -> CGImage? {
        // Fits inside the box, so a portrait video still gets its width.
        let box = CGSize(width: maxPixelWidth, height: maxPixelWidth * 4)
        do {
            return try await MediaServiceClient.shared.posterFrame(fileAt: url, maxPixelSize: box, nearStart: true).makeImage()
        } catch MediaProbeError.serviceUnavailable {
            throw MediaProbeError.serviceUnavailable
        } catch {
            return nil
        }
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
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize(sourceSize: CGSize(width: width, height: height), targetWidth: maxPixelWidth),
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
                let loaded = await PosterCache.shared.image(for: url, fallbackVideo: fallbackVideo, maxPixelWidth: maxPixelWidth)
                // A cancelled load (the request changed) can finish after the
                // new one and would blank the poster it showed.
                if !Task.isCancelled { image = loaded }
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
