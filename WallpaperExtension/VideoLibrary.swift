import AVFoundation
import Foundation
import ImageIO
import os

final class VideoLibrary: Sendable {
    static let shared = VideoLibrary()

    private let videosDir: URL
    private let indexURL: URL
    private let lock = OSAllocatedUnfairLock(initialState: [VideoEntry]())
    /// Orders overlapping scans. `NSLock` because publishing writes the
    /// index file while holding it, so index writes land in scan order.
    private let scanLock = NSLock()
    private nonisolated(unsafe) var scanRecord = LibraryScanRecord()

    private init() {
        let docs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents")
        self.videosDir = docs.appendingPathComponent("videos")
        self.indexURL = docs.appendingPathComponent("library.json")
        try? FileManager.default.createDirectory(at: videosDir, withIntermediateDirectories: true)
        // Once per process, before the first scan, so scans stay read-only.
        migrateLegacyVideo()
    }

    // MARK: - Public API

    /// All videos currently in the library.
    var entries: [VideoEntry] {
        lock.withLock { $0 }
    }

    /// Find a video entry by its UUID string.
    func entry(for id: String) -> VideoEntry? {
        lock.withLock { entries in
            entries.first { $0.id == id }
        }
    }

    /// URL to the video file for a given entry.
    func videoURL(for entry: VideoEntry) -> URL {
        videosDir
            .appendingPathComponent(entry.id)
            .appendingPathComponent(entry.filename)
    }

    /// URL to the video file for a given video ID.
    func videoURL(for id: String) -> URL? {
        guard let entry = entry(for: id) else { return nil }
        return videoURL(for: entry)
    }

    /// URL to a specific variant file within an entry's directory.
    func variantURL(for entryId: String, variant: VideoVariant) -> URL {
        videosDir
            .appendingPathComponent(entryId)
            .appendingPathComponent(variant.filename)
    }

    /// Select the best variant URL for a given playback policy (selection rules
    /// in `VariantSelection`). Falls back to the original file URL when the policy
    /// resolves to no variant. Returns `nil` only if the entry doesn't exist.
    func bestVariantURL(for id: String, policy: PlaybackPolicy, displayPixels: CGSize? = nil) -> URL? {
        guard let entry = entry(for: id) else { return nil }
        guard
            let chosen = VariantSelection.variant(
                for: policy,
                sourceFPS: VariantSelection.wholeFPS(entry.fps),
                sourceResolution: entry.resolution,
                // A copy listed in metadata but missing on disk would leave the
                // renderer retrying a dead URL; choose among files that exist,
                // and never a symlink out of the entry.
                variants: (entry.variants ?? []).filter {
                    LibraryEntryScan.isPlayable(variantURL(for: id, variant: $0))
                },
                displayPixels: displayPixels,
            )
        else {
            return videoURL(for: entry)
        }
        return variantURL(for: id, variant: chosen)
    }

    /// Scan the videos directory and rebuild the in-memory index. Reads the
    /// entry directories without changing them.
    func scan() {
        let token = scanLock.withLock { scanRecord.begin() }
        var discovered = [VideoEntry]()
        let fm = FileManager.default
        guard
            let subdirs = try? fm.contentsOfDirectory(
                at: videosDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles,
            )
        else {
            publish([], token: token)
            return
        }

        // Read-only: the app publishes and prunes entries, and may be
        // staging one right now (`LibraryEntryScan`).
        for dir in subdirs {
            switch LibraryEntryScan.read(directory: dir) {
            case let .entry(entry):
                guard PathSafety.contained(videoURL(for: entry), in: videosDir) else {
                    extensionLog("[VideoLibrary] Skipping \(entry.id): video path escapes library")
                    continue
                }
                discovered.append(entry)
            case let .skipped(reason):
                extensionLog("[VideoLibrary] Skipping \(dir.lastPathComponent): \(reason)")
            }
        }

        discovered.sort { $0.dateAdded < $1.dateAdded }
        publish(discovered, token: token)
    }

    /// Install a scan's listing unless a scan that started later already
    /// published.
    private func publish(_ listing: [VideoEntry], token: Int) {
        scanLock.lock()
        defer { scanLock.unlock() }
        guard scanRecord.finish(token) else {
            traceLog("[VideoLibrary] Dropped a scan superseded by a newer one")
            return
        }
        lock.withLock { $0 = listing }
        saveIndex(listing)
        traceLog("[VideoLibrary] Scanned: \(listing.count) video(s)")
    }

    /// Add a video file to the library, copying it into the managed directory.
    /// Returns the new entry's ID.
    @discardableResult
    func addVideo(from sourceURL: URL, name: String? = nil) -> String? {
        let id = UUID().uuidString
        let dir = videosDir.appendingPathComponent(id)
        let fm = FileManager.default

        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let destURL = dir.appendingPathComponent(sourceURL.lastPathComponent)
            try fm.copyItem(at: sourceURL, to: destURL)

            let entry = VideoEntry(
                id: id,
                name: name ?? sourceURL.deletingPathExtension().lastPathComponent,
                filename: sourceURL.lastPathComponent,
                duration: 0,
                fps: 0,
                resolution: .zero,
                dateAdded: Date(),
            )
            let metadataURL = dir.appendingPathComponent("metadata.json")
            try JSONEncoder().encode(entry).write(to: metadataURL)

            lock.withLock { $0.append(entry) }
            saveIndex(entries)
            extensionLog("[VideoLibrary] Added: \(id)")
            return id
        } catch {
            extensionLog("[VideoLibrary] Failed to add video: \(error)")
            try? fm.removeItem(at: dir)
            return nil
        }
    }

    /// Remove a video from the library.
    func removeVideo(id: String) {
        let dir = videosDir.appendingPathComponent(id)
        // Only ever delete a valid UUID directory that resolves inside the
        // library. A malformed id must not reach removeItem at all.
        guard PathSafety.isValidEntryID(id), PathSafety.contained(dir, in: videosDir) else {
            extensionLog("[VideoLibrary] Refusing to remove unsafe id: \(id)")
            return
        }
        try? FileManager.default.removeItem(at: dir)
        lock.withLock { entries in
            entries.removeAll { $0.id == id }
        }
        saveIndex(entries)
        extensionLog("[VideoLibrary] Removed: \(id)")
    }

    /// Update metadata for a video entry (e.g., after probing duration/fps/resolution).
    func updateMetadata(for id: String, duration: Double, fps: Double, resolution: CGSize) {
        lock.withLock { entries in
            guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
            entries[idx].duration = duration
            entries[idx].fps = fps
            entries[idx].resolution = resolution
        }
        let metadataURL =
            videosDir
            .appendingPathComponent(id)
            .appendingPathComponent("metadata.json")
        if let entry = entry(for: id) {
            try? JSONEncoder().encode(entry).write(to: metadataURL)
        }
        saveIndex(entries)
    }

    // MARK: - Thumbnail Generation

    /// Generate a JPEG thumbnail for a video entry, saved alongside the video.
    func generateThumbnail(for entry: VideoEntry) async -> URL? {
        let url = videoURL(for: entry)
        let thumbnailURL =
            videosDir
            .appendingPathComponent(entry.id)
            .appendingPathComponent("thumbnail.jpg")

        if FileManager.default.fileExists(atPath: thumbnailURL.path) {
            return thumbnailURL
        }

        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 270)

        let cgImage: CGImage
        do {
            cgImage = try await generator.image(at: .zero).image
        } catch {
            extensionLog("[VideoLibrary] Thumbnail failed for \(entry.id): \(error)")
            return nil
        }

        guard
            let dest = CGImageDestinationCreateWithURL(
                thumbnailURL as CFURL, "public.jpeg" as CFString, 1, nil,
            )
        else { return nil }
        CGImageDestinationAddImage(
            dest, cgImage,
            [
                kCGImageDestinationLossyCompressionQuality: 0.85
            ] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }

        return thumbnailURL
    }

    // MARK: - Private

    private func saveIndex(_ entries: [VideoEntry]) {
        try? JSONEncoder().encode(entries).write(to: indexURL, options: .atomic)
    }

    /// Migrate legacy single-file `wallpaper.{mp4,mov,m4v}` from Documents root into the library.
    private func migrateLegacyVideo() {
        let docs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents")
        let extensions = ["mp4", "mov", "m4v"]
        let fm = FileManager.default

        for ext in extensions {
            let legacyURL = docs.appendingPathComponent("wallpaper.\(ext)")
            guard fm.fileExists(atPath: legacyURL.path) else { continue }

            let id = UUID().uuidString
            let dir = videosDir.appendingPathComponent(id)
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                let destURL = dir.appendingPathComponent("wallpaper.\(ext)")
                try fm.moveItem(at: legacyURL, to: destURL)

                let entry = VideoEntry(
                    id: id,
                    name: "Wallpaper",
                    filename: "wallpaper.\(ext)",
                    duration: 0,
                    fps: 0,
                    resolution: .zero,
                    dateAdded: Date(),
                )
                let metadataURL = dir.appendingPathComponent("metadata.json")
                try JSONEncoder().encode(entry).write(to: metadataURL)
                extensionLog("[VideoLibrary] Migrated legacy wallpaper.\(ext) → \(id)")
            } catch {
                extensionLog("[VideoLibrary] Migration failed: \(error)")
                try? fm.removeItem(at: dir)
            }
            break
        }
    }
}
