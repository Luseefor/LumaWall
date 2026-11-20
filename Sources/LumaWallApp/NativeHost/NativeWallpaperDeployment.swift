import AVFoundation
import AppKit
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
            let decoded =
                fileURL
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

    /// `surfaces` are the displays the wallpaper is going on, with their
    /// tiers; they decide whether the optional 1440p copy is worth encoding
    /// and which battery copy to encode first.
    @MainActor
    static func ensureDeployed(asset: WallpaperAsset, surfaces: [Surface]) async throws -> EntryInfo {
        let entryID = asset.id.rawValue.uuidString
        guard PathSafety.isValidEntryID(entryID) else {
            throw DeploymentError.invalidEntry
        }
        // A removed wallpaper is refused whatever the mode.
        guard !removedEntries.contains(entryID) else { throw DeploymentError.removed }
        guard NativeModeSetting.isEnabledNow else { throw NativeWallpaperAssignmentService.AssignmentError.nativeModeOff }
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
            return try await checkedNotRemoved(running, entryID: entryID)
        }
        let task = Task<EntryInfo, Error> {
            try await deploy(asset: asset, entryID: entryID, surfaces: surfaces)
        }
        deploymentTasks[entryID] = task
        defer { deploymentTasks.removeValue(forKey: entryID) }
        return try await checkedNotRemoved(task, entryID: entryID)
    }

    /// Wallpapers removed this session. Removal marks the ID before its
    /// first suspension, so a restore or apply that read the library earlier
    /// can't deploy it again, and one already deploying can't go on to
    /// assign it. Entry IDs are UUIDs and never come back.
    @MainActor
    static var removedEntries: Set<String> = []

    /// The deploy's entry, unless its wallpaper was removed while it ran.
    /// Callers assign the entry right after this returns, without
    /// suspending. A deploy that failed because the removal deleted its
    /// files also throws `removed`, so it isn't taken for native mode
    /// failing.
    @MainActor
    private static func checkedNotRemoved(_ deploy: Task<EntryInfo, Error>, entryID: String) async throws -> EntryInfo {
        let entry: EntryInfo
        do {
            entry = try await deploy.value
        } catch {
            if removedEntries.contains(entryID) { throw DeploymentError.removed }
            throw error
        }
        guard !removedEntries.contains(entryID) else { throw DeploymentError.removed }
        return entry
    }

    /// Set once the first deploy of this run has queued the cleanup of
    /// exports a previous run left behind.
    @MainActor
    private static var copyEncodingPrepared = false

    /// Deploys currently running per entry (see `ensureDeployed`).
    @MainActor
    private static var deploymentTasks: [String: Task<EntryInfo, Error>] = [:]

    /// Entries with a deploy running now.
    @MainActor
    static var deployingEntryIDs: Set<String> { Set(deploymentTasks.keys) }

    /// Returns once no deploy of `entryID` is running; its result is ignored.
    @MainActor
    static func waitForDeployment(of entryID: String) async {
        if let running = deploymentTasks[entryID] { _ = try? await running.value }
    }

    @MainActor
    private static func deploy(asset: WallpaperAsset, entryID: String, surfaces: [Surface]) async throws -> EntryInfo {
        let displayPixels = surfaces.map(\.pixelSize)
        playbackChanged(entryID: entryID, surfaces: surfaces)
        let hash = try await hashStore.hash(for: asset.mediaURL)
        // Hashing a large file takes a while; native mode may be off by now.
        guard NativeModeSetting.isEnabledNow else { throw NativeWallpaperAssignmentService.AssignmentError.nativeModeOff }
        if let existing = try entry(id: entryID),
            isRegularFile(existing.filename, inEntry: entryID),
            existing.contentHash == hash
        {
            // Libraries missing any planned copy (pre-variant ones, or ones
            // made before the 1440p copy existed) backfill in the background.
            if needsVariants(existing, displayPixels: displayPixels) {
                // Encode from the deployed original, not the library file:
                // the library file can change after the hash check, and only
                // deploy replaces the deployed one, under entryLock and
                // followed by metadata carrying the new hash, which makes
                // publication reject a copy made from the old one.
                let deployed = videoURL(for: existing)
                Task.detached {
                    await ensureVariants(
                        for: entryID,
                        contentHash: hash,
                        sourceURL: deployed,
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
        let filename =
            PathSafety.isSafeComponent(asset.mediaURL.lastPathComponent)
            ? asset.mediaURL.lastPathComponent
            : "Wallpaper.mov"
        try FileManager.default.createDirectory(at: videosFolderURL, withIntermediateDirectories: true)
        let stagingFolder = try makeStagingFolder(appropriateFor: videosFolderURL)
        beginStaging(stagingFolder)
        defer {
            let deleted = (try? FileManager.default.removeItem(at: stagingFolder)) != nil
            endStaging(stagingFolder, deleted: deleted)
        }
        let staged = try await Task.detached(priority: .utility) {
            try stageDeployment(source: asset.mediaURL, entryID: entryID, filename: filename, stagingFolderURL: stagingFolder)
        }.value
        let probe = try await probe(url: staged.videoURL)
        // The copy and probe take a while too. Nothing is published yet; the
        // staging folder goes with the defer above.
        guard NativeModeSetting.isEnabledNow else { throw NativeWallpaperAssignmentService.AssignmentError.nativeModeOff }
        let entry = EntryInfo(
            id: entryID,
            name: asset.name,
            filename: staged.filename,
            duration: probe.duration,
            fps: probe.fps,
            resolution: probe.resolution,
            dateAdded: asset.createdAt,
            contentHash: staged.hash,
            audioStripped: false
        )
        let data = try JSONEncoder().encode(entry)
        try data.write(to: staged.directoryURL.appendingPathComponent("metadata.json"), options: .atomic)
        await generateThumbnail(for: staged.videoURL, in: staged.directoryURL)
        try await Task.detached(priority: .utility) {
            try publishDeployment(staged, stagingFolderURL: stagingFolder)
        }.value
        notifyLibraryChanged()
        scheduleSweep()
        let deployed = videoURL(for: entry)
        Task.detached {
            await ensureVariants(
                for: entryID,
                contentHash: staged.hash,
                sourceURL: deployed,
                sourceFPS: entry.fps,
                sourceSize: entry.resolution,
                displayPixels: displayPixels
            )
        }
        return entry
    }

    /// The entry's metadata.json, read without following a symlink: the
    /// extension can swap the file or its folder for one. A missing entry,
    /// or one where a symlink or other non-file stands in, reads as nil so
    /// the next deploy replaces it. Other read errors throw.
    static func entry(id: String, videosFolderURL: URL = videosFolderURL) throws -> EntryInfo? {
        guard let folder = try entryFolder(id, videosFolderURL: videosFolderURL) else { return nil }
        return try entry(id: id, readingFrom: folder)
    }

    /// The entry's folder, or nil when it's missing or a symlink or file
    /// stands in for it. Other errors throw.
    static func entryFolder(_ id: String, videosFolderURL: URL = videosFolderURL) throws -> TrustedDirectory? {
        do {
            return try trustedFolder(videosFolderURL).subdirectory(id)
        } catch let error as POSIXError where readsAsMissing(error) {
            return nil
        }
    }

    /// metadata.json in the open entry `folder`, as `entry(id:)` reads it.
    static func entry(id: String, readingFrom folder: TrustedDirectory) throws -> EntryInfo? {
        let data: Data
        do {
            data = try folder.readFile(named: "metadata.json")
        } catch let error as POSIXError where readsAsMissing(error) {
            return nil
        }
        // Bytes that don't decode (a truncated write, a hand edit) read as
        // missing so the next deploy replaces them. Read errors still throw.
        guard let decoded = try? JSONDecoder().decode(EntryInfo.self, from: data) else { return nil }
        return validated(decoded, id: id)
    }

    /// Missing, or a symlink or other non-file or non-folder where one
    /// should be. A socket fails `open` with EOPNOTSUPP.
    private static func readsAsMissing(_ error: POSIXError) -> Bool {
        [.ENOENT, .ELOOP, .ENOTDIR, .EFTYPE, .EOPNOTSUPP].contains(error.code)
    }

    /// The extension can write its container, so metadata.json is checked
    /// like any outside input: the ID must name its own folder and the
    /// filename be a plain basename. An entry failing that reads as missing,
    /// so the next deploy replaces it. Copies with unsafe names are dropped.
    static func validated(_ entry: EntryInfo, id: String) -> EntryInfo? {
        guard entry.id == id, PathSafety.isSafeComponent(entry.filename) else { return nil }
        var entry = entry
        entry.variants = entry.variants?.filter { PathSafety.isSafeComponent($0.filename) }
        return entry
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

    /// Ask the extension to clear its stills from WallpaperAgent's cache. Any
    /// process can post `clearCaches`, so the extension acts on it only when
    /// this request file is there and fresh (`CacheClearRequest` in the
    /// extension).
    static func requestSnapshotCacheClear(
        documentsURL: URL = WallpaperHostCapabilities.extensionDocumentsURL,
        post: () -> Void = postClearCaches
    ) {
        // Atomic: replaces whatever is at the path, symlink included, and
        // gives the file a fresh modification date.
        try? Data().write(to: documentsURL.appendingPathComponent("clear-caches.request"), options: .atomic)
        post()
    }

    private static func postClearCaches() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("app.lumawall.personal.clearCaches" as CFString),
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

    /// Parses deployed videos: the sandboxed media service, so a decoder
    /// exploit in a deployed file can't reach the user's files.
    static let mediaProbe: any MediaProbing = MediaServiceClient.shared

    private static func probe(url: URL) async throws -> Probe {
        let info: MediaInfo
        do {
            info = try await mediaProbe.inspect(fileAt: url)
        } catch MediaProbeError.noVideoTrack {
            throw DeploymentError.noVideoTrack
        } catch MediaProbeError.invalidDuration {
            throw DeploymentError.invalidDuration
        }
        return Probe(duration: info.duration, fps: info.framesPerSecond, resolution: info.pixelSize)
    }

    private static func contentHash(for url: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            try VerifiedFileCopy.sha256(ofFileAt: url).sha256
        }.value
    }

    @MainActor
    private static func generateThumbnail(for videoURL: URL, in directory: URL) async {
        guard let frame = try? await mediaProbe.posterFrame(fileAt: videoURL, maxPixelSize: CGSize(width: 640, height: 360)),
            let cgImage = frame.makeImage()
        else { return }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]),
            NativeModeSetting.isEnabledNow
        else { return }
        try? jpeg.write(to: directory.appendingPathComponent("thumbnail.jpg"), options: .atomic)
    }

    enum DeploymentError: LocalizedError {
        case invalidEntry, noVideoTrack, invalidDuration, removed
        var errorDescription: String? {
            switch self {
            case .invalidEntry: "Could not prepare that wallpaper for the system host."
            case .removed: "That wallpaper was removed from the library."
            case .noVideoTrack: "That file has no video track."
            case .invalidDuration: "That video duration is invalid."
            }
        }
    }
}
