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
        await encodeQueue.enqueue(specs.map {
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
            case .reduced: spec.filename == "Wallpaper.reduced.mov"
            case .minimal: spec.filename == "Wallpaper.minimal.mov"
            case .staticFrame, .paused: false
            }
        }
        guard spec.forFullQuality else { return .ready(rank: playing ? 0 : 1) }
        let planned = variantSpecs(sourceSize: sourceSize, sourceFPS: sourceFPS, displayPixels: surfaces.map(\.pixelSize))
        guard planned.contains(spec) else { return .drop }
        return playing && canMakeOptionalCopies ? .ready(rank: 0) : .hold
    }

    private static func readiness(of job: VariantEncodeQueue.Job) -> VariantEncodeQueue.Readiness {
        // A wallpaper removed or redeployed while its jobs waited has
        // nothing to encode for them.
        guard let entry = try? entry(id: job.entryID), entry.contentHash == job.contentHash,
              !isRecorded(job.spec, in: entry)
        else { return .drop }
        return copyReadiness(job.spec, sourceSize: entry.resolution, sourceFPS: entry.fps,
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
        prepare: { cleanUpAbandonedExports(videosFolderURL: videosFolderURL, stagingFolderURL: stagingFolderURL) }
    )

    private static func isRecorded(_ spec: VariantSpec, in entry: EntryInfo) -> Bool {
        guard (entry.variants ?? []).contains(where: { $0.filename == spec.filename && $0.fps == spec.recordedFPS }) else { return false }
        return FileManager.default.fileExists(atPath: entryDirectory(entry.id).appendingPathComponent(spec.filename).path)
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
                      entry.contentHash == job.contentHash else {
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
    static func cleanUpAbandonedExports(videosFolderURL: URL, stagingFolderURL: URL) {
        let fm = FileManager.default
        let staged = (try? fm.contentsOfDirectory(at: stagingFolderURL, includingPropertiesForKeys: nil)) ?? []
        for file in staged {
            let parts = file.lastPathComponent.split(separator: ".", maxSplits: 2).map(String.init)
            let keep = !file.lastPathComponent.hasSuffix(".partial.mov")
                && parts.count == 3
                && PathSafety.isValidEntryID(parts[0])
                && (try? entry(id: parts[0], videosFolderURL: videosFolderURL))??.contentHash == parts[1]
            if !keep { try? fm.removeItem(at: file) }
        }
        // Older versions exported "<copy name>.<UUID>.tmp.mov" inside the
        // entry. Only entries whose metadata.json reads and names another
        // primary are touched: the extension may have recovered one of these
        // as the primary, and deleting it makes the extension prune the entry.
        let entries = (try? fm.contentsOfDirectory(at: videosFolderURL, includingPropertiesForKeys: nil)) ?? []
        for dir in entries {
            let id = dir.lastPathComponent
            guard PathSafety.isValidEntryID(id),
                  let entry = try? entry(id: id, videosFolderURL: videosFolderURL)
            else { continue }
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.lastPathComponent != entry.filename && isLegacyExport(file.lastPathComponent) {
                try? fm.removeItem(at: file)
            }
        }
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
