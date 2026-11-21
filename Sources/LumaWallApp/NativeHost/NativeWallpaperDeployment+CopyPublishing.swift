import AppKit
import Foundation
import LumaWallCore

/// Queues copy encodes and moves finished copies into the library.
extension NativeWallpaperDeployment {
    /// Queue the copies `variantSpecs` plans for the deployment whose source
    /// hashes to `contentHash`. Copies already listed with a file on disk are
    /// skipped and missing ones regenerated. A multi-GB 4K transcode must
    /// never block applying the wallpaper, so this returns once the jobs are
    /// queued.
    ///
    /// Without these files the extension's variant selector always falls back
    /// to the full file, so Automatic-on-battery and Battery Saver resolve a
    /// cheaper tier and then play the exact same bytes ("does nothing").
    static func ensureVariants(
        for entryID: String, contentHash: String, sourceURL: URL,
        sourceFPS: Double, sourceSize: CGSize, displayPixels: [CGSize]
    ) async {
        guard PathSafety.isValidEntryID(entryID),
            FileManager.default.fileExists(atPath: entryDirectory(entryID).path)
        else { return }
        let specs = variantSpecs(sourceSize: sourceSize, sourceFPS: sourceFPS, displayPixels: displayPixels)
        await encodeQueue.enqueue(
            specs.map {
                VariantEncodeQueue.Job(entryID: entryID, sourceURL: sourceURL, contentHash: contentHash, spec: $0)
            })
    }

    /// Removes exports a previous run left behind. Safe to call more than
    /// once; the queue runs it before its first encode.
    static func prepareCopyEncoding() async {
        await encodeQueue.prepareIfNeeded()
    }

    private static func entryDirectory(_ entryID: String, videosFolderURL: URL = videosFolderURL) -> URL {
        videosFolderURL.appendingPathComponent(entryID, isDirectory: true)
    }

    /// Exports are written, probed and kept here until they are moved into
    /// the entry once metadata.json can list them. It sits next to
    /// `transcodeSourcesFolderURL`, outside the extension's container: the
    /// app reads an export by path, and inside the container the extension
    /// could swap it for other bytes between the check and the read.
    static var stagingFolderURL: URL {
        transcodeSourcesFolderURL.deletingLastPathComponent().appendingPathComponent("copy-staging", isDirectory: true)
    }

    /// The private staging folder, made owner-only if missing.
    static func privateStagingFolder(_ url: URL = stagingFolderURL) throws -> TrustedDirectory {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return try TrustedDirectory(url: url)
    }

    /// Whether another process of this app is running, such as the
    /// installed LumaWall next to a dev build.
    static func anotherLumaWallIsRunning() -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        return NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .contains { $0.processIdentifier != getpid() }
    }

    /// Deletes what versions before this one left in copy-staging in the
    /// extension's Documents folder, without following a symlink on the way.
    /// Callers skip it while another LumaWall runs; in case an older one
    /// starts meanwhile, only items untouched for an hour go. Their copies are encoded again if
    /// still wanted.
    static func removeLegacyCopyStaging(
        documentsURL: URL = WallpaperHostCapabilities.extensionDocumentsURL, trustedAncestor: URL = containerURL,
        now: Date = Date()
    ) {
        guard let documents = try? TrustedDirectory(url: documentsURL, below: trustedAncestor),
            let staging = try? documents.subdirectory("copy-staging")
        else { return }
        for item in (try? staging.entries()) ?? [] {
            guard let modified = try? staging.modificationDate(ofItemNamed: item.name),
                now.timeIntervalSince(modified) > 60 * 60
            else { continue }
            try? staging.removeItem(named: item.name)
        }
    }

    /// The extension's container. The extension can write anything inside
    /// `Data`, including swapping a folder for a symlink, so folders below
    /// this are opened with `TrustedDirectory(url:below:)`.
    static var containerURL: URL {
        WallpaperHostCapabilities.extensionDocumentsURL.deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Where a finished export waits to be published: "entryID.hash.filename".
    static func stagedURL(for job: VariantEncodeQueue.Job, stagingFolderURL: URL = stagingFolderURL) -> URL {
        stagingFolderURL.appendingPathComponent("\(job.entryID).\(job.contentHash).\(job.spec.filename)")
    }

    /// A display showing a wallpaper, with the tier it plays at.
    struct Surface: Sendable, Equatable {
        var pixelSize: CGSize
        var tier: PlaybackTier
    }

    private static let surfacesLock = NSLock()
    nonisolated(unsafe) private static var surfacesByEntry: [String: [Surface]] = [:]

    /// Records where a wallpaper plays and re-evaluates queued copies.
    /// Callers report every deploy and tier evaluation, which also runs on
    /// power and Low Power Mode changes, so a held 1440p copy starts once
    /// AC returns and a running one stops when its display goes away.
    static func playbackChanged(entryID: String, surfaces: [Surface]) {
        surfacesLock.withLock { surfacesByEntry[entryID] = surfaces }
        Task { await encodeQueue.wake() }
    }

    /// Re-evaluates queued and running copies, for a change no surface
    /// report carries, such as native mode turning off with nothing playing.
    static func copyConditionsChanged() {
        Task { await encodeQueue.wake() }
    }

    /// Stops and forgets every copy encode for a removed entry.
    static func forgetCopies(for entryID: String) async {
        surfacesLock.withLock { surfacesByEntry[entryID] = nil }
        await encodeQueue.cancel(entryID: entryID)
    }

    private static func surfaces(for entryID: String) -> [Surface] {
        surfacesLock.withLock { surfacesByEntry[entryID] ?? [] }
    }

    /// When a copy may encode. A copy some surface's tier would play now
    /// goes first (rank 0), other battery copies next (rank 1). The 1440p
    /// copy is made only for a surface playing it now on AC power; it is
    /// held while a tier or power keeps it unplayed, and dropped once no
    /// surface fits it.
    static func copyReadiness(
        _ spec: VariantSpec, sourceSize: CGSize, sourceFPS: Double,
        surfaces: [Surface], canMakeOptionalCopies: Bool
    ) -> VariantEncodeQueue.Readiness {
        let all = variantSpecs(sourceSize: sourceSize, sourceFPS: sourceFPS)
        let playing = surfaces.contains { surface in
            switch surface.tier {
            case .full: fullQualityPick(among: all, sourceSize: sourceSize, sourceFPS: sourceFPS, display: surface.pixelSize) == spec
            case .reduced: reducedPick(among: all, sourceSize: sourceSize, sourceFPS: sourceFPS) == spec
            case .minimal: spec.filename == "Wallpaper.minimal.mov"
            case .staticFrame, .paused: false
            }
        }
        guard spec.forFullQuality else { return .ready(rank: playing ? 0 : 1) }
        let planned = variantSpecs(sourceSize: sourceSize, sourceFPS: sourceFPS, displayPixels: surfaces.map(\.pixelSize))
        guard planned.contains(spec) else { return .drop }
        return playing && canMakeOptionalCopies ? .ready(rank: 0) : .hold
    }

    /// The copy the extension's Reduced tier plays: the one named for it, or
    /// without it (a source of 1920 px or less plans no 1080p copy) the
    /// fastest copy below the source rate, else the smallest at the same
    /// rate. Mirrors `VariantSelection.variant(for: .reduced)`, which orders
    /// copies by rate, then size, largest first.
    static func reducedPick(among specs: [VariantSpec], sourceSize: CGSize, sourceFPS: Double) -> VariantSpec? {
        if let named = specs.first(where: { $0.filename == "Wallpaper.reduced.mov" }) { return named }
        func area(_ spec: VariantSpec) -> CGFloat {
            let size = copySize(source: sourceSize, fitting: spec.fitting)
            return size.width * size.height
        }
        let sorted = specs.sorted {
            $0.recordedFPS != $1.recordedFPS ? $0.recordedFPS > $1.recordedFPS : area($0) > area($1)
        }
        let sourceRate = Int(sourceFPS.rounded())
        return sorted.first { $0.recordedFPS < sourceRate } ?? sorted.last
    }

    private static func readiness(of job: VariantEncodeQueue.Job) -> VariantEncodeQueue.Readiness {
        // Copies live in the extension's container, which only native mode uses.
        guard NativeModeSetting.isEnabledNow else { return .drop }
        // A wallpaper removed or redeployed while its jobs waited has
        // nothing to encode for them.
        guard let entry = try? entry(id: job.entryID), entry.contentHash == job.contentHash,
            !isRecorded(job.spec, in: entry)
        else { return .drop }
        return copyReadiness(
            job.spec, sourceSize: entry.resolution, sourceFPS: entry.fps,
            surfaces: surfaces(for: job.entryID), canMakeOptionalCopies: canMakeFullQualityCopies)
    }

    /// The one queue every copy encode goes through.
    private static let encodeQueue = VariantEncodeQueue(
        readiness: { readiness(of: $0) },
        encode: { job in
            let staged = stagedURL(for: job)
            guard let staging = try? privateStagingFolder() else { return .failed }
            // A finished export whose publication failed is reused, not redone.
            if !reusableExport(named: staged.lastPathComponent, in: staging) {
                // Encoded from a private copy: AVFoundation reads by path,
                // and the deployed file may be a symlink to a user's file.
                let result = await exportCopy(job, sources: transcodeSources) { source in
                    await transcode(sourceURL: source, to: staged, spec: job.spec) {
                        if case .ready = readiness(of: job) { return true }
                        return false
                    }
                }
                switch result {
                case .finished: break
                case .failed: return .failed
                case .skipped: return .notNow
                }
            }
            // By path, which is safe here: the extension can't reach staging.
            guard let resolution = await videoSize(of: staged) else {
                try? staging.removeFile(named: staged.lastPathComponent)
                return .failed
            }
            switch publish(staged, job: job, resolution: resolution) {
            case .published:
                notifyLibraryChanged()
                return .done
            case .stale: return .done
            case .failed: return .failed
            case .nativeModeOff: return .notNow
            case .deferred: return .retryLater
            }
        },
        prepare: {
            transcodeSources.removeLeftovers()
            // An older LumaWall still running may be using it.
            if !anotherLumaWallIsRunning() { removeLegacyCopyStaging() }
            cleanUpAbandonedExports(
                videosFolderURL: videosFolderURL, stagingFolderURL: stagingFolderURL, trustedAncestor: containerURL)
        },
        finishedSource: { transcodeSources.release($0) }
    )

    /// True when a regular file sits at `name` in `staging`, ready to
    /// publish. Anything else there (a folder, a symlink) would fail every
    /// publish and survive cleanup, so it's deleted, without following
    /// symlinks, and the copy is encoded again.
    static func reusableExport(named name: String, in staging: TrustedDirectory) -> Bool {
        switch try? staging.kind(ofItemNamed: name) {
        case .file: return true
        case nil: return false
        default:
            try? staging.removeItem(named: name)
            return false
        }
    }

    private static func isRecorded(_ spec: VariantSpec, in entry: EntryInfo) -> Bool {
        guard (entry.variants ?? []).contains(where: { $0.filename == spec.filename && $0.fps == spec.recordedFPS }) else { return false }
        return isRegularFile(spec.filename, inEntry: entry.id)
    }

    /// Held while a copy is published and while deploy clears an entry, so a
    /// copy of the old source can't land in the redeployed entry.
    static let entryLock = NSLock()

    enum PublishResult: Equatable {
        case published, stale, failed, deferred
        /// Native mode was off once the entry lock was held; the export
        /// stays staged.
        case nativeModeOff
    }

    private enum PublishInterrupted: Error {
        case entryChanged
    }

    /// Moves a finished export into its entry and lists it in metadata.json,
    /// re-reading the file so copies other jobs recorded are kept. Discards
    /// the export when the entry no longer holds the source it was made from.
    /// If metadata.json can't be written, restore the previous variant.
    ///
    /// The staging and entry folders are opened through `TrustedDirectory`
    /// and every read, move and delete goes through their descriptors, so
    /// a folder swapped for a symlink fails the publish instead of steering
    /// it elsewhere.
    ///
    /// Check native mode after preparing the metadata, just before moving
    /// the export. Disabling native mode can proceed while a write finishes.
    static func publish(
        _ staged: URL,
        job: VariantEncodeQueue.Job,
        resolution: CGSize,
        videosFolderURL: URL = videosFolderURL,
        writeMetadata: (Data, TrustedDirectory) throws -> Void = { data, folder in
            try folder.writeFile(named: "metadata.json", contents: data)
        },
        isNativeModeOn: () -> Bool = { NativeModeSetting.isEnabledNow }
    ) -> PublishResult {
        entryLock.withLock {
            let stagedName = staged.lastPathComponent
            guard let staging = try? trustedFolder(staged.deletingLastPathComponent()) else { return .failed }
            // Stale only when the entry is known gone or holds another
            // source. A folder that can't be opened safely (a symlink in
            // place of videos or the entry) keeps the export for a retry.
            guard let videos = try? trustedFolder(videosFolderURL) else { return .failed }
            let folder: TrustedDirectory
            do {
                folder = try videos.subdirectory(job.entryID)
            } catch POSIXError.ENOENT {
                try? staging.removeFile(named: stagedName)
                return .stale
            } catch {
                return .failed
            }
            guard isNativeModeOn() else { return .nativeModeOff }
            do {
                let identity = try folder.identity()
                func isCurrent() -> Bool {
                    guard !isRemoving(entryID: job.entryID),
                        let current = try? entryFolder(job.entryID, videosFolderURL: videosFolderURL)
                    else { return false }
                    return (try? current.identity()) == identity
                }
                return try folder.withExclusiveFileLock(named: ".copy-publish.lock") {
                    guard isCurrent() else { return .deferred }
                    guard var updated = try entry(id: job.entryID, readingFrom: folder), updated.contentHash == job.contentHash else {
                        try? staging.removeFile(named: stagedName)
                        return .stale
                    }
                    let name = job.spec.filename
                    let listed = (updated.variants ?? []).filter { (try? folder.kind(ofItemNamed: $0.filename)) == .file }
                    let variant = NativeVideoVariant(filename: name, fps: job.spec.recordedFPS, resolution: resolution)
                    updated.variants = merging(listed, with: [variant])
                    let metadata = try JSONEncoder().encode(updated)
                    guard isNativeModeOn() else { return .nativeModeOff }
                    guard isCurrent() else { return .deferred }
                    // The swap can move the previous movie into staging.
                    // Give it a private name that retries won't reuse and
                    // that cleanup skips while this process is alive.
                    let moving = "\(getpid()).\(UUID().uuidString).publishing.partial.mov"
                    do { try staging.renameItem(named: stagedName, to: moving) } catch { return .failed }
                    var moved = false
                    do {
                        try staging.publishItem(
                            named: moving, into: folder, as: name,
                            shouldRestore: {
                                entry(id: job.entryID, inEntry: folder)?.contentHash == job.contentHash && isCurrent()
                            },
                            commit: {
                                moved = true
                                guard isCurrent() else { throw PublishInterrupted.entryChanged }
                                try writeMetadata(metadata, folder)
                                guard isCurrent() else { throw PublishInterrupted.entryChanged }
                            })
                    } catch PublishInterrupted.entryChanged {
                        return .deferred
                    } catch {
                        // Once the export has reached the extension's folder,
                        // its bytes can no longer be reused by the app.
                        if !moved { try? staging.renameItem(named: moving, to: stagedName) }
                        return isCurrent() ? .failed : .deferred
                    }
                    return .published
                }
            } catch {
                return .failed
            }
        }
    }

    /// Deletes interrupted exports, finished exports of sources that are no
    /// longer deployed, and the `.tmp.mov` files older versions exported
    /// inside the entry folder, where the extension's recovery scan could
    /// pick one as the wallpaper.
    ///
    /// Only `.mov` files are deleted, through `TrustedDirectory` opened
    /// below `trustedAncestor` (and the staging folder below
    /// `stagingAncestor`, by default itself): a staging or entry folder, or
    /// any folder between them and their ancestor, swapped for a symlink
    /// can't steer the delete elsewhere.
    static func cleanUpAbandonedExports(
        videosFolderURL: URL, stagingFolderURL: URL, trustedAncestor: URL, stagingAncestor: URL? = nil
    ) {
        // Without a trustworthy videos folder, no staged export can be shown
        // stale, so everything is kept.
        guard let videos = try? TrustedDirectory(url: videosFolderURL, below: trustedAncestor) else { return }
        if let staging = try? TrustedDirectory(url: stagingFolderURL, below: stagingAncestor ?? stagingFolderURL) {
            for file in (try? staging.entries()) ?? [] where file.kind == .file && file.name.hasSuffix(".mov") {
                if isLivePublishingPartial(file.name) { continue }
                let parts = file.name.split(separator: ".", maxSplits: 2).map(String.init)
                let keep =
                    !file.name.hasSuffix(".partial.mov")
                    && parts.count == 3
                    && PathSafety.isValidEntryID(parts[0])
                    && holdsSource(parts[1], entryID: parts[0], in: videos) != false
                if !keep { try? staging.removeFile(named: file.name) }
            }
        }
        // Older versions exported "<copy name>.<UUID>.tmp.mov" inside the
        // entry. Only entries whose metadata.json reads and names another
        // primary are touched: the extension may have recovered one of these
        // as the primary, and deleting it makes the extension prune the entry.
        // The metadata is read through the descriptor the delete uses, under
        // the entry lock deploy holds while it replaces an entry.
        for dir in (try? videos.entries()) ?? [] where dir.kind == .directory && PathSafety.isValidEntryID(dir.name) {
            entryLock.withLock {
                guard let folder = try? videos.subdirectory(dir.name), let entry = entry(id: dir.name, inEntry: folder) else {
                    return
                }
                for file in (try? folder.entries()) ?? []
                where file.kind == .file && file.name != entry.filename && isLegacyExport(file.name) {
                    try? folder.removeFile(named: file.name)
                }
            }
        }
    }

    private static func isLivePublishingPartial(_ name: String) -> Bool {
        guard name.hasSuffix(".publishing.partial.mov"),
            let prefix = name.split(separator: ".", maxSplits: 1).first,
            let owner = pid_t(prefix), owner > 0
        else { return false }
        return kill(owner, 0) == 0 || errno == EPERM
    }

    /// Whether entry `id` still holds the source hashed `hash`: false when
    /// the entry is gone, holds another source or has no usable metadata;
    /// nil when its folder or metadata can't be opened safely, which says
    /// neither.
    private static func holdsSource(_ hash: String, entryID id: String, in videos: TrustedDirectory) -> Bool? {
        let folder: TrustedDirectory
        do {
            folder = try videos.subdirectory(id)
        } catch POSIXError.ENOENT {
            return false
        } catch {
            return nil
        }
        do {
            return try entry(id: id, readingFrom: folder)?.contentHash == hash
        } catch {
            return nil
        }
    }

    private static func entry(id: String, inEntry folder: TrustedDirectory) -> EntryInfo? {
        (try? entry(id: id, readingFrom: folder)) ?? nil
    }

    private static func isLegacyExport(_ name: String) -> Bool {
        let copies = ["Wallpaper.reduced.mov", "Wallpaper.minimal.mov", "Wallpaper.qhd.mov"]
        guard name.hasSuffix(".tmp.mov"),
            let copy = copies.first(where: { name.hasPrefix($0 + ".") })
        else { return false }
        let uuid = name.dropFirst(copy.count + 1).dropLast(".tmp.mov".count)
        return UUID(uuidString: String(uuid)) != nil
    }
}
