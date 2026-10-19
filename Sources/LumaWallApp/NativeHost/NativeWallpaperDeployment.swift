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

    /// Content-hash cache keyed by file path. Restores call `ensureDeployed`
    /// once per display, and without this each of them re-hashes the same
    /// multi-GB source, stalling multi-monitor restores and burning battery
    /// to prove what the first hash already proved. Entries are validated by
    /// size + mtime; only touched on MainActor (all callers are).
    @MainActor
    private static var hashCache: [String: (size: UInt64, mtime: Date, hash: String)] = [:]

    @MainActor
    private static func cachedContentHash(for url: URL) async throws -> String {
        let key = url.standardizedFileURL.path
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.uint64Value
        let mtime = attributes?[.modificationDate] as? Date
        if let size, let mtime,
           let cached = hashCache[key], cached.size == size, cached.mtime == mtime {
            return cached.hash
        }
        let hash = try await contentHash(for: url)
        if let size, let mtime {
            hashCache[key] = (size: size, mtime: mtime, hash: hash)
        }
        return hash
    }

    static func videoURL(for entry: EntryInfo) -> URL {
        videosFolderURL.appendingPathComponent(entry.id, isDirectory: true)
            .appendingPathComponent(entry.filename)
    }

    @MainActor
    static func ensureDeployed(asset: WallpaperAsset) async throws -> EntryInfo {
        let entryID = asset.id.rawValue.uuidString
        guard PathSafety.isValidEntryID(entryID) else {
            throw DeploymentError.invalidEntry
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
            try await deploy(asset: asset, entryID: entryID)
        }
        deploymentTasks[entryID] = task
        defer { deploymentTasks.removeValue(forKey: entryID) }
        return try await task.value
    }

    /// Deploys currently running per entry (see `ensureDeployed`).
    @MainActor
    private static var deploymentTasks: [String: Task<EntryInfo, Error>] = [:]

    @MainActor
    private static func deploy(asset: WallpaperAsset, entryID: String) async throws -> EntryInfo {
        let hash = try await cachedContentHash(for: asset.mediaURL)
        if let existing = entry(id: entryID),
           FileManager.default.fileExists(atPath: videoURL(for: existing).path),
           existing.contentHash == hash {
            // Pre-variant libraries backfill in the background so Battery
            // Saver / Automatic start working without a manual re-apply.
            if (existing.variants ?? []).isEmpty {
                Task.detached {
                    await ensureVariants(
                        for: entryID,
                        sourceURL: asset.mediaURL,
                        sourceFPS: existing.fps,
                        sourceSize: existing.resolution
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
            if fm.fileExists(atPath: dir.path) {
                try fm.removeItem(at: dir)
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
                sourceURL: staged.dest,
                sourceFPS: probe.fps,
                sourceSize: probe.resolution
            )
        }
        return entry
    }

    static func entry(id: String) -> EntryInfo? {
        let metadataURL = videosFolderURL
            .appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent("metadata.json")
        guard let data = try? Data(contentsOf: metadataURL) else { return nil }
        return try? JSONDecoder().decode(EntryInfo.self, from: data)
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

    /// Transcoded-sibling work currently running, keyed "entryID/filename".
    /// Restores fan out one `ensureVariants` per display and tier switches can
    /// overlap them; without this two workers transcode the same multi-GB
    /// source at once and race the move into place. Lock-guarded: this runs on
    /// detached tasks, not MainActor.
    private static let variantWorkLock = NSLock()
    nonisolated(unsafe) private static var variantWorkInFlight = Set<String>()

    private static func claimVariantWork(_ key: String) -> Bool {
        variantWorkLock.lock()
        defer { variantWorkLock.unlock() }
        return variantWorkInFlight.insert(key).inserted
    }

    private static func finishVariantWork(_ key: String) {
        variantWorkLock.lock()
        defer { variantWorkLock.unlock() }
        variantWorkInFlight.remove(key)
    }

    /// Transcode the reduced (1080p) / minimal (720p) siblings the battery
    /// tiers play, and record them in metadata.json. Idempotent: skips tiers
    /// whose file already exists, drops stale entries, regenerates missing
    /// ones. Runs detached in the background. A multi-GB 4K transcode must
    /// never block applying the wallpaper.
    ///
    /// Without these files the extension's variant selector always falls back
    /// to the full file, so Automatic-on-battery and Battery Saver resolve a
    /// cheaper tier and then play the exact same bytes ("does nothing").
    static func ensureVariants(for entryID: String, sourceURL: URL, sourceFPS: Double, sourceSize: CGSize) async {
        guard PathSafety.isValidEntryID(entryID) else { return }
        let fm = FileManager.default
        let dir = videosFolderURL.appendingPathComponent(entryID, isDirectory: true)
        guard fm.fileExists(atPath: dir.path) else { return }
        let sourceMax = max(sourceSize.width, sourceSize.height)
        // Tiers above the source size are pointless (upscaling a transcode).
        let specs: [(filename: String, preset: String, maxDim: CGFloat)] = [
            ("Wallpaper.reduced.mov", AVAssetExportPreset1920x1080, 1920),
            ("Wallpaper.minimal.mov", AVAssetExportPreset1280x720, 1280),
        ].filter { sourceMax > $0.maxDim }
        guard !specs.isEmpty else { return }
        var variants = entry(id: entryID)?.variants ?? []
        // Drop entries whose file went missing so they regenerate below.
        variants.removeAll { fm.fileExists(atPath: dir.appendingPathComponent($0.filename).path) == false }
        var changed = false
        for spec in specs {
            if variants.contains(where: { $0.filename == spec.filename }) { continue }
            let workKey = entryID + "/" + spec.filename
            guard claimVariantWork(workKey) else { continue }
            let variant = await transcode(
                sourceURL: sourceURL,
                dir: dir,
                filename: spec.filename,
                preset: spec.preset,
                sourceFPS: sourceFPS
            )
            finishVariantWork(workKey)
            guard let variant else { continue }
            variants.removeAll { $0.filename == spec.filename }
            variants.append(variant)
            changed = true
        }
        guard changed else { return }
        if var entry = entry(id: entryID) {
            entry.variants = variants
            if let data = try? JSONEncoder().encode(entry) {
                try? data.write(to: dir.appendingPathComponent("metadata.json"), options: .atomic)
            }
            notifyLibraryChanged()
        }
    }

    private static func transcode(sourceURL: URL, dir: URL, filename: String, preset: String, sourceFPS: Double) async -> NativeVideoVariant? {
        let source = AVURLAsset(url: sourceURL)
        guard let export = AVAssetExportSession(asset: source, presetName: preset) else { return nil }
        let temp = dir.appendingPathComponent("\(filename).\(UUID().uuidString).tmp.mov")
        do {
            try await export.export(to: temp, as: .mov)
            let probed = AVURLAsset(url: temp)
            var resolution = CGSize.zero
            if let track = try? await probed.loadTracks(withMediaType: .video).first,
               let natural = try? await track.load(.naturalSize),
               let transform = try? await track.load(.preferredTransform) {
                let transformed = natural.applying(transform)
                resolution = CGSize(width: abs(transformed.width), height: abs(transformed.height))
            }
            guard resolution.width > 0, resolution.height > 0 else {
                try? FileManager.default.removeItem(at: temp)
                return nil
            }
            let dest = dir.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: dest.path) {
                try? FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: temp, to: dest)
            return NativeVideoVariant(filename: filename, fps: Int(sourceFPS.rounded()), resolution: resolution)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            return nil
        }
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
