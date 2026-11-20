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

    /// Exports are written here, outside the library folder the extension
    /// scans, and moved into the entry once metadata.json can list them.
    static var stagingFolderURL: URL {
        WallpaperHostCapabilities.extensionDocumentsURL.appendingPathComponent("copy-staging", isDirectory: true)
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
            let fm = FileManager.default
            let staged = stagedURL(for: job)
            // A finished export whose publication failed is reused, not redone.
            if !fm.fileExists(atPath: staged.path) {
                try? fm.createDirectory(at: stagingFolderURL, withIntermediateDirectories: true)
                let result = await transcode(sourceURL: job.sourceURL, to: staged, spec: job.spec) {
                    if case .ready = readiness(of: job) { return true }
                    return false
                }
                switch result {
                case .finished: break
                case .failed: return .failed
                case .skipped: return .notNow
                }
            }
            guard let resolution = await videoSize(of: staged) else {
                try? fm.removeItem(at: staged)
                return .failed
            }
            switch publish(staged, job: job, resolution: resolution) {
            case .published:
                notifyLibraryChanged()
                return .done
            case .stale: return .done
            case .failed: return .failed
            }
        },
        prepare: {
            cleanUpAbandonedExports(
                videosFolderURL: videosFolderURL, stagingFolderURL: stagingFolderURL, trustedAncestor: containerURL)
        }
    )

    private static func isRecorded(_ spec: VariantSpec, in entry: EntryInfo) -> Bool {
        guard (entry.variants ?? []).contains(where: { $0.filename == spec.filename && $0.fps == spec.recordedFPS }) else { return false }
        return isRegularFile(spec.filename, inEntry: entry.id)
    }

    /// Held while a copy is published and while deploy clears an entry, so a
    /// copy of the old source can't land in the redeployed entry.
    static let entryLock = NSLock()

    enum PublishResult: Equatable { case published, stale, failed }

    /// Moves a finished export into its entry and lists it in metadata.json,
    /// re-reading the file so copies other jobs recorded are kept. Discards
    /// the export when the entry no longer holds the source it was made from.
    /// When metadata.json can't be written the export goes back to staging,
    /// so a retry publishes it without encoding again.
    static func publish(
        _ staged: URL,
        job: VariantEncodeQueue.Job,
        resolution: CGSize,
        videosFolderURL: URL = videosFolderURL,
        writeMetadata: (EntryInfo, URL) throws -> Void = { entry, url in
            try JSONEncoder().encode(entry).write(to: url, options: .atomic)
        }
    ) -> PublishResult {
        entryLock.withLock {
            let fm = FileManager.default
            let current: EntryInfo
            do {
                guard let entry = try entry(id: job.entryID, videosFolderURL: videosFolderURL),
                    entry.contentHash == job.contentHash
                else {
                    try? fm.removeItem(at: staged)
                    return .stale
                }
                current = entry
            } catch {
                return .failed
            }
            let dir = entryDirectory(job.entryID, videosFolderURL: videosFolderURL)
            let dest = dir.appendingPathComponent(job.spec.filename)
            try? fm.removeItem(at: dest)
            do { try fm.moveItem(at: staged, to: dest) } catch { return .failed }
            var updated = current
            let listed = (current.variants ?? []).filter { fm.fileExists(atPath: dir.appendingPathComponent($0.filename).path) }
            let variant = NativeVideoVariant(filename: job.spec.filename, fps: job.spec.recordedFPS, resolution: resolution)
            updated.variants = merging(listed, with: [variant])
            do {
                try writeMetadata(updated, dir.appendingPathComponent("metadata.json"))
            } catch {
                try? fm.moveItem(at: dest, to: staged)
                return .failed
            }
            return .published
        }
    }

    /// Deletes interrupted exports, finished exports of sources that are no
    /// longer deployed, and the `.tmp.mov` files older versions exported
    /// inside the entry folder, where the extension's recovery scan could
    /// pick one as the wallpaper.
    ///
    /// Only `.mov` files are deleted, through `TrustedDirectory` opened
    /// below `trustedAncestor`: a staging or entry folder, or any folder
    /// above them, swapped for a symlink can't steer the delete elsewhere.
    static func cleanUpAbandonedExports(videosFolderURL: URL, stagingFolderURL: URL, trustedAncestor: URL) {
        // Without a trustworthy videos folder, no staged export can be shown
        // stale, so everything is kept.
        guard let videos = try? TrustedDirectory(url: videosFolderURL, below: trustedAncestor) else { return }
        if let staging = try? TrustedDirectory(url: stagingFolderURL, below: trustedAncestor) {
            for file in (try? staging.entries()) ?? [] where file.kind == .file && file.name.hasSuffix(".mov") {
                let parts = file.name.split(separator: ".", maxSplits: 2).map(String.init)
                let keep =
                    !file.name.hasSuffix(".partial.mov")
                    && parts.count == 3
                    && PathSafety.isValidEntryID(parts[0])
                    && entry(id: parts[0], in: videos)?.contentHash == parts[1]
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

    /// metadata.json of entry `id`, read inside `videos` without following
    /// symlinks; nil when unreadable or listing another ID.
    private static func entry(id: String, in videos: TrustedDirectory) -> EntryInfo? {
        guard let folder = try? videos.subdirectory(id) else { return nil }
        return entry(id: id, inEntry: folder)
    }

    private static func entry(id: String, inEntry folder: TrustedDirectory) -> EntryInfo? {
        guard let data = try? folder.readFile(named: "metadata.json"),
            let entry = try? JSONDecoder().decode(EntryInfo.self, from: data)
        else { return nil }
        return validated(entry, id: id)
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
