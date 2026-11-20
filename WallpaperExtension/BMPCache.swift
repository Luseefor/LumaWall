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

/// Serializes every write, copy and eviction in the cache directory.
private let stillStore = StillCacheStore()

/// The cached still of `videoURL` to seed a new renderer on a display of the
/// given pixel size, or nil when none is cached. Never another wallpaper's.
///
/// - Parameter videoID: per-context choice identifier. Each display's acquire
///   passes its own choice so the right cached frame is shown during transitions.
///   Reading the process-wide "current" selection here would race across displays.
func loadCachedSnapshotImage(forChoice videoID: String?, videoURL: URL, pixelWidth: Int, pixelHeight: Int) -> CGImage? {
    guard let cacheDir = WallpaperState.shared.cacheDirectoryURL else { return nil }

    let gained = cacheDir.startAccessingSecurityScopedResource()
    defer { if gained { cacheDir.stopAccessingSecurityScopedResource() } }

    let image = stillStore.load(
        in: cacheDir,
        choiceHash: StillCache.choiceHash(stillIdentifier(videoID, videoURL)),
        version: stillVersion(of: videoURL),
        size: StillSize(width: pixelWidth, height: pixelHeight),
    )
    traceLog(
        "  [InitContent] cached still for \(videoURL.lastPathComponent) at \(pixelWidth)x\(pixelHeight): \(image.map { "\($0.width)x\($0.height)" } ?? "none")"
    )
    return image
}

/// A cached still of the file `videoURL` under any choice, for a renderer
/// that has lost track of which choice it plays but knows the file.
func loadCachedStill(ofVideo videoURL: URL, pixelWidth: Int, pixelHeight: Int) -> CGImage? {
    guard let cacheDir = WallpaperState.shared.cacheDirectoryURL else { return nil }
    let gained = cacheDir.startAccessingSecurityScopedResource()
    defer { if gained { cacheDir.stopAccessingSecurityScopedResource() } }
    return stillStore.load(
        in: cacheDir, choiceHash: nil, version: stillVersion(of: videoURL), size: StillSize(width: pixelWidth, height: pixelHeight))
}

/// Make sure the Agent's cache directory holds a BMP of the video's first
/// frame for this display size. See StillCacheStore for how entries are
/// kept, shared between sizes and evicted.
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

    let report = await stillStore.write(
        in: cacheDir,
        choiceHash: StillCache.choiceHash(stillIdentifier(videoID, videoURL)),
        version: stillVersion(of: videoURL),
        size: StillSize(width: displayPixelWidth, height: displayPixelHeight),
    ) {
        await firstFrameBMP(of: videoURL)
    }
    traceLog("  [BMPCache] \(displayPixelWidth)x\(displayPixelHeight) for \(videoID ?? "?"): \(report.outcome), \(report.created) written")
    guard report.created > 0 else { return }

    let versionURL = cacheDir.appendingPathComponent("cacheVersion.db")
    do {
        try Data("{\"version\":2}".utf8).write(to: versionURL, options: .atomic)
    } catch {
        traceLog("  [BMPCache] cacheVersion.db failed: \(error)")
    }
}

private func firstFrameBMP(of videoURL: URL) async -> Data? {
    guard let image = await firstFrameImage(of: videoURL) else { return nil }
    traceLog("  [BMPCache] Rendering \(image.width)x\(image.height) BGR24")
    return StillCache.encodeBMP(image)
}

/// The video's first frame, oriented as it plays.
func firstFrameImage(of videoURL: URL) async -> CGImage? {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: videoURL))
    generator.appliesPreferredTrackTransform = true
    do {
        return try await generator.image(at: .zero).image
    } catch {
        traceLog("  [BMPCache] Failed to get video frame: \(error)")
        return nil
    }
}

/// Writes keyed the id-less case by file name, so loads must too.
private func stillIdentifier(_ videoID: String?, _ videoURL: URL) -> String {
    videoID ?? videoURL.lastPathComponent
}

private func stillVersion(of videoURL: URL) -> String {
    let values = try? videoURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
    return StillCache.version(path: videoURL.standardizedFileURL.path, modified: values?.contentModificationDate, size: values?.fileSize)
}
