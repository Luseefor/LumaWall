import AVFoundation
import AppKit
import CryptoKit
import Foundation
import LumaWallCore

enum NativeWallpaperDeployment {
    struct EntryInfo: Codable, Equatable, Sendable {
        let id: String
        var name: String
        var filename: String
        var duration: Double
        var fps: Double
        var resolution: CGSize
        var dateAdded: Date
        var contentHash: String?
        var audioStripped: Bool?
        /// Downscaled siblings for the reduced/minimal battery tiers, written
        /// by `ensureVariants` after deploy. Optional + tolerant decoding so
        /// pre-variant libraries keep loading (they backfill on next touch).
        var variants: [NativeVideoVariant]?

        // Custom decoding: `variants` postdates existing metadata.json files.
        // Synthesized decoding would throw on the missing key and force a full
        // re-deploy (re-copy + thumbnail) for every existing wallpaper.
        init(
            id: String,
            name: String,
            filename: String,
            duration: Double,
            fps: Double,
            resolution: CGSize,
            dateAdded: Date,
            contentHash: String? = nil,
            audioStripped: Bool? = nil,
            variants: [NativeVideoVariant]? = nil
        ) {
            self.id = id
            self.name = name
            self.filename = filename
            self.duration = duration
            self.fps = fps
            self.resolution = resolution
            self.dateAdded = dateAdded
            self.contentHash = contentHash
            self.audioStripped = audioStripped
            self.variants = variants
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            name = try container.decode(String.self, forKey: .name)
            filename = try container.decode(String.self, forKey: .filename)
            duration = try container.decode(Double.self, forKey: .duration)
            fps = try container.decode(Double.self, forKey: .fps)
            resolution = try container.decode(CGSize.self, forKey: .resolution)
            dateAdded = try container.decode(Date.self, forKey: .dateAdded)
            contentHash = try container.decodeIfPresent(String.self, forKey: .contentHash)
            audioStripped = try container.decodeIfPresent(Bool.self, forKey: .audioStripped)
            variants = try container.decodeIfPresent([NativeVideoVariant].self, forKey: .variants)
        }
    }

    /// Downscaled sibling for battery tiers. JSON shape (`filename`, `fps`,
    /// `resolution`) intentionally mirrors the extension's `VideoVariant` so
    /// the metadata.json the app writes decodes directly on that side.
    struct NativeVideoVariant: Codable, Equatable, Sendable {
        var filename: String
        var fps: Int
        var resolution: CGSize
    }

    static var videosFolderURL: URL {
        WallpaperHostCapabilities.extensionDocumentsURL.appendingPathComponent("videos", isDirectory: true)
    }

    /// Verified content hashes keyed by source path and a file fingerprint,
    /// kept in memory and in a JSON file. Restores call `ensureDeployed` once
    /// per display, and every launch used to SHA-256 each multi-GB source
    /// again to prove what the last launch already proved.
    @MainActor
    final class ContentHashStore {
        typealias Hasher = @Sendable (URL) async throws -> String

        /// Size and modification date alone miss a same-size replacement
        /// that keeps the old date. The inode catches a file swapped in, and
        /// the change time catches any rewrite in place, since setting the
        /// modification date back also bumps it.
        struct Fingerprint: Codable, Equatable {
            var device: Int64
            var inode: UInt64
            var size: Int64
            var mtime: TimeInterval
            var ctime: TimeInterval

            init?(url: URL) {
                var info = stat()
                guard stat(url.path, &info) == 0 else { return nil }
                func seconds(_ time: timespec) -> TimeInterval { TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1e9 }
                device = Int64(info.st_dev)
                inode = UInt64(info.st_ino)
                size = Int64(info.st_size)
                mtime = seconds(info.st_mtimespec)
                ctime = seconds(info.st_ctimespec)
            }
        }

        private struct Record: Codable {
            var fingerprint: Fingerprint
            var hash: String
        }

        private let fileURL: URL?
        private let hasher: Hasher
        private var records: [String: Record]?

        init(fileURL: URL?, hasher: @escaping Hasher) {
            self.fileURL = fileURL
            self.hasher = hasher
        }

        func hash(for url: URL) async throws -> String {
            let key = url.standardizedFileURL.path
            let before = Fingerprint(url: url)
            if let before, let cached = loaded()[key], cached.fingerprint == before {
                return cached.hash
            }
            let hash = try await hasher(url)
            // A file that changed while it was read has no hash worth keeping.
            if let before, Fingerprint(url: url) == before {
                records?[key] = Record(fingerprint: before, hash: hash)
                save()
            }
            return hash
        }

        private func loaded() -> [String: Record] {
            if let records { return records }
            // A missing or unreadable file only costs one rehash per source.
            let decoded = fileURL
                .flatMap { try? Data(contentsOf: $0) }
                .flatMap { try? JSONDecoder().decode([String: Record].self, from: $0) }
            records = decoded ?? [:]
            return records ?? [:]
        }

        private func save() {
            guard let fileURL, let records else { return }
            // Sources deleted from disk would otherwise stay listed forever.
            let live = records.filter { FileManager.default.fileExists(atPath: $0.key) }
            self.records = live
            if let data = try? JSONEncoder().encode(live) {
                try? data.write(to: fileURL, options: .atomic)
            }
        }
    }

    @MainActor
    private static let hashStore = ContentHashStore(
        fileURL: (try? StorePaths.appSupportBase())?.appendingPathComponent("content-hashes.json"),
        hasher: { try await contentHash(for: $0) }
    )

    static func videoURL(for entry: EntryInfo) -> URL {
        videosFolderURL.appendingPathComponent(entry.id, isDirectory: true)
            .appendingPathComponent(entry.filename)
    }

    /// `displayPixels` are the connected displays' sizes in pixels; they
    /// decide whether the optional 1440p copy is worth encoding.
    @MainActor
    static func ensureDeployed(asset: WallpaperAsset, displayPixels: [CGSize]) async throws -> EntryInfo {
        let entryID = asset.id.rawValue.uuidString
        guard PathSafety.isValidEntryID(entryID) else {
            throw DeploymentError.invalidEntry
        }
        if !copyEncodingPrepared {
            copyEncodingPrepared = true
            Task.detached(priority: .utility) { await prepareCopyEncoding() }
        }
        // Concurrent applies of the same wallpaper (double-click, playlist +
        // manual racing) used to interleave remove-dir → copy and corrupt the
        // entry. Second callers await the running deploy instead of staging
        // over it. Keyed by entry so different wallpapers still deploy in
        // parallel; awaiting a Task value never blocks the actor.
        if let running = deploymentTasks[entryID] {
            return try await running.value
        }
        let task = Task<EntryInfo, Error> {
            try await deploy(asset: asset, entryID: entryID, displayPixels: displayPixels)
        }
        deploymentTasks[entryID] = task
        defer { deploymentTasks.removeValue(forKey: entryID) }
        return try await task.value
    }

    /// Set once the first deploy of this run has queued the cleanup of
    /// exports a previous run left behind.
    @MainActor
    private static var copyEncodingPrepared = false

    /// Deploys currently running per entry (see `ensureDeployed`).
    @MainActor
    private static var deploymentTasks: [String: Task<EntryInfo, Error>] = [:]

    @MainActor
    private static func deploy(asset: WallpaperAsset, entryID: String, displayPixels: [CGSize]) async throws -> EntryInfo {
        let hash = try await hashStore.hash(for: asset.mediaURL)
        if let existing = try entry(id: entryID),
           FileManager.default.fileExists(atPath: videoURL(for: existing).path),
           existing.contentHash == hash {
            // Libraries missing any planned copy (pre-variant ones, or ones
            // made before the 1440p copy existed) backfill in the background.
            if needsVariants(existing, displayPixels: displayPixels) {
                Task.detached {
                    await ensureVariants(
                        for: entryID,
                        contentHash: hash,
                        sourceURL: asset.mediaURL,
                        sourceFPS: existing.fps,
                        sourceSize: existing.resolution,
                        displayPixels: displayPixels
                    )
                }
            }
            return existing
        }

        // Stage the (potentially large) video file off the main actor. The old
        // code copied gigabytes on MainActor, stalling the UI + watchdog.
        let staged = try await Task.detached(priority: .utility) {
            let fm = FileManager.default
            try fm.createDirectory(at: videosFolderURL, withIntermediateDirectories: true)
            let dir = videosFolderURL.appendingPathComponent(entryID, isDirectory: true)
            // Under the entry lock, so a copy of the previous source that is
            // being published finishes first and can't land after the reset.
            try entryLock.withLock {
                if fm.fileExists(atPath: dir.path) {
                    try fm.removeItem(at: dir)
                }
            }
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let filename = PathSafety.isSafeComponent(asset.mediaURL.lastPathComponent)
                ? asset.mediaURL.lastPathComponent
                : "Wallpaper.mov"
            let dest = dir.appendingPathComponent(filename)
            try fm.copyItem(at: asset.mediaURL, to: dest)
            return (dir: dir, dest: dest, filename: filename)
        }.value

        let probe = try await probe(url: staged.dest)
        let entry = EntryInfo(
            id: entryID,
            name: asset.name,
            filename: staged.filename,
            duration: probe.duration,
            fps: probe.fps,
            resolution: probe.resolution,
            dateAdded: asset.createdAt,
            contentHash: hash,
            audioStripped: false
        )
        let data = try JSONEncoder().encode(entry)
        try data.write(to: staged.dir.appendingPathComponent("metadata.json"), options: .atomic)
        await generateThumbnail(for: staged.dest, in: staged.dir)
        notifyLibraryChanged()
        Task.detached {
            await ensureVariants(
                for: entryID,
                contentHash: hash,
                sourceURL: staged.dest,
                sourceFPS: probe.fps,
                sourceSize: probe.resolution,
                displayPixels: displayPixels
            )
        }
        return entry
    }

    static func entry(id: String, videosFolderURL: URL = videosFolderURL) throws -> EntryInfo? {
        let metadataURL = videosFolderURL
            .appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent("metadata.json")
        let data: Data
        do {
            data = try Data(contentsOf: metadataURL)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
        return try JSONDecoder().decode(EntryInfo.self, from: data)
    }

    static func notifyLibraryChanged() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(
            center,
            CFNotificationName("app.lumawall.personal.libraryChanged" as CFString),
            nil,
            nil,
            true
        )
    }

    private struct Probe {
        let duration: Double
        let fps: Double
        let resolution: CGSize
    }

    private static func probe(url: URL) async throws -> Probe {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw DeploymentError.noVideoTrack
        }
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let transformed = naturalSize.applying(transform)
        let resolution = CGSize(width: abs(transformed.width), height: abs(transformed.height))
        let fps = Double(try await track.load(.nominalFrameRate))
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        guard duration.isFinite, duration > 0 else { throw DeploymentError.invalidDuration }
        return Probe(duration: duration, fps: fps, resolution: resolution)
    }

    private static func contentHash(for url: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let data = try handle.read(upToCount: 1_024 * 1_024), !data.isEmpty {
                try Task.checkCancellation()
                hasher.update(data: data)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }

    @MainActor
    private static func generateThumbnail(for videoURL: URL, in directory: URL) async {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 360)
        guard let cgImage = try? await generator.image(at: .zero).image else { return }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { return }
        try? jpeg.write(to: directory.appendingPathComponent("thumbnail.jpg"), options: .atomic)
    }

    enum DeploymentError: LocalizedError {
        case invalidEntry, noVideoTrack, invalidDuration
        var errorDescription: String? {
            switch self {
            case .invalidEntry: "Could not prepare that wallpaper for the system host."
            case .noVideoTrack: "That file has no video track."
            case .invalidDuration: "That video duration is invalid."
            }
        }
    }
}
