import AVFoundation
import Foundation
import ImageIO

/// Removes reproducible WallpaperAgent snapshots while preserving every source
/// video and user assignment. The Agent regenerates the right poster on demand.
func clearWallpaperSnapshotCache() {
    guard let cacheDir = WallpaperState.shared.cacheDirectoryURL else { return }
    let gained = cacheDir.startAccessingSecurityScopedResource()
    defer { if gained { cacheDir.stopAccessingSecurityScopedResource() } }
    guard gained,
          let contents = try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil)
    else { return }
    for file in contents where file.pathExtension == "bmp" {
        try? FileManager.default.removeItem(at: file)
    }
    extensionLog("[BMPCache] Cleared generated wallpaper snapshots")
}

/// Concurrent misses for one wallpaper version share one decode.
private let stillFlights = StillCacheFlights()

/// The cached still to seed a new renderer for `videoURL` on a display of the
/// given pixel size, or nil when the cache is empty. See `StillCache.lookup`
/// for the order it falls back in.
///
/// - Parameter videoID: per-context choice identifier. Each display's acquire
///   passes its own choice so the right cached frame is shown during transitions.
///   Reading the process-wide "current" selection here would race across displays.
func loadCachedSnapshotImage(forChoice videoID: String?, videoURL: URL, pixelWidth: Int, pixelHeight: Int) -> CGImage? {
    guard let cacheDir = WallpaperState.shared.cacheDirectoryURL else { return nil }

    let gained = cacheDir.startAccessingSecurityScopedResource()
    defer { if gained { cacheDir.stopAccessingSecurityScopedResource() } }

    guard let file = StillCache.lookup(
        scanStills(in: cacheDir),
        choiceHash: StillCache.choiceHash(stillIdentifier(videoID, videoURL)),
        version: stillVersion(of: videoURL),
        width: pixelWidth, height: pixelHeight,
    ) else { return nil }

    let url = cacheDir.appendingPathComponent(file.entry.fileName)
    guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
          let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
        traceLog("  [InitContent] Failed to decode cached BMP: \(url.lastPathComponent)")
        return nil
    }

    traceLog("  [InitContent] Loaded cached snapshot: \(url.lastPathComponent) (\(cgImage.width)x\(cgImage.height))")
    return cgImage
}

/// Make sure the Agent's cache directory holds a BMP of the video's first
/// frame for this display size. Entries are kept per wallpaper, video version
/// and size; a size the video is already cached at in another size is a copy,
/// not a decode. Older versions of the wallpaper are removed, and the
/// directory is kept under `StillCache.byteBudget`.
func writeBMPSnapshot(videoURL: URL, videoID: String? = nil, displayPixelWidth: Int, displayPixelHeight: Int) async {
    guard let cacheDir = WallpaperState.shared.cacheDirectoryURL else {
        traceLog("  [BMPCache] No cacheDirectoryURL, skipping")
        return
    }

    let gained = cacheDir.startAccessingSecurityScopedResource()
    defer { if gained { cacheDir.stopAccessingSecurityScopedResource() } }

    guard gained else {
        traceLog("  [BMPCache] Failed to acquire security-scoped access")
        return
    }

    let choiceHash = StillCache.choiceHash(stillIdentifier(videoID, videoURL))
    let version = stillVersion(of: videoURL)
    let group = "\(choiceHash)-\(version)"
    let first = StillSize(width: displayPixelWidth, height: displayPixelHeight)
    guard stillFlights.join(group, size: first) else {
        traceLog("  [BMPCache] \(displayPixelWidth)x\(displayPixelHeight) for \(videoID ?? "?") joined a write in flight")
        return
    }

    var kept: Set<StillCacheEntry> = []
    var created = false
    var size: StillSize? = first
    while let next = size {
        let entry = StillCacheEntry(choiceHash: choiceHash, width: next.width, height: next.height, version: version)
        switch await writeStill(entry, videoURL: videoURL, in: cacheDir) {
        case .hit: kept.insert(entry)
        case .created: kept.insert(entry); created = true
        case .failed: break
        }
        size = stillFlights.next(group)
    }
    guard created else { return }

    for stale in StillCache.evictions(scanStills(in: cacheDir), keeping: kept, budget: StillCache.byteBudget) {
        try? FileManager.default.removeItem(at: cacheDir.appendingPathComponent(stale.fileName))
        traceLog("  [BMPCache] Removed \(stale.fileName)")
    }

    let versionURL = cacheDir.appendingPathComponent("cacheVersion.db")
    do {
        try Data("{\"version\":2}".utf8).write(to: versionURL, options: .atomic)
    } catch {
        traceLog("  [BMPCache] cacheVersion.db failed: \(error)")
    }
}

private enum StillWrite { case hit, created, failed }

private func writeStill(_ entry: StillCacheEntry, videoURL: URL, in cacheDir: URL) async -> StillWrite {
    let url = cacheDir.appendingPathComponent(entry.fileName)
    switch StillCache.source(for: entry, in: scanStills(in: cacheDir)) {
    case .existing:
        markUsed(url)
        traceLog("  [BMPCache] \(entry.width)x\(entry.height) already cached, skipping")
        return .hit
    case let .copy(from: sibling):
        do {
            // An APFS clone: no decode, and no extra blocks until either changes.
            try FileManager.default.copyItem(at: cacheDir.appendingPathComponent(sibling.fileName), to: url)
        } catch {
            if FileManager.default.fileExists(atPath: url.path) { markUsed(url); return .hit }
            traceLog("  [BMPCache] Copy for \(entry.width)x\(entry.height) failed: \(error)")
            return .failed
        }
        markUsed(url)
        traceLog("  [BMPCache] Copied \(sibling.width)x\(sibling.height) → \(entry.fileName)")
        return .created
    case .decode:
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: videoURL))
        generator.appliesPreferredTrackTransform = true
        let image: CGImage
        do {
            image = try await generator.image(at: .zero).image
        } catch {
            traceLog("  [BMPCache] Failed to get video frame: \(error)")
            return .failed
        }
        traceLog("  [BMPCache] Rendering \(image.width)x\(image.height) BGR24")
        guard let bmp = StillCache.encodeBMP(image) else {
            traceLog("  [BMPCache] CGContext render failed")
            return .failed
        }
        do {
            try bmp.write(to: url, options: .atomic)
        } catch {
            traceLog("  [BMPCache] Write failed: \(error)")
            return .failed
        }
        traceLog("  [BMPCache] Wrote \(bmp.count) bytes → \(entry.fileName)")
        return .created
    }
}

/// The parseable stills in the cache directory with their sizes and dates.
private func scanStills(in cacheDir: URL) -> [StillCacheFile] {
    let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
    guard let contents = try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: keys) else {
        return []
    }
    return contents.compactMap { url in
        guard let entry = StillCacheEntry(fileName: url.lastPathComponent) else { return nil }
        let values = try? url.resourceValues(forKeys: Set(keys))
        return StillCacheFile(entry: entry, bytes: values?.fileSize ?? 0, modified: values?.contentModificationDate ?? .distantPast)
    }
}

/// Eviction drops the least recently used first, so a hit counts as a use.
private func markUsed(_ url: URL) {
    try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
}

/// Writes keyed the id-less case by file name, so loads must too.
private func stillIdentifier(_ videoID: String?, _ videoURL: URL) -> String {
    videoID ?? videoURL.lastPathComponent
}

private func stillVersion(of videoURL: URL) -> UInt64 {
    StillCache.version(modified: try? videoURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
}
