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

    /// The one queue every copy encode goes through.
    private static let encodeQueue = VariantEncodeQueue(
        canMakeOptionalCopies: { canMakeFullQualityCopies },
        isDone: { job in
            // A wallpaper removed or redeployed while its jobs waited has
            // nothing to encode for them.
            guard let entry = try? entry(id: job.entryID), entry.contentHash == job.contentHash else { return true }
            return isRecorded(job.spec, in: entry)
        },
        encode: { job in
            let fm = FileManager.default
            let staged = stagedURL(for: job)
            // A finished export whose publication failed is reused, not redone.
            if !fm.fileExists(atPath: staged.path) {
                try? fm.createDirectory(at: stagingFolderURL, withIntermediateDirectories: true)
                guard await transcode(sourceURL: job.sourceURL, to: staged, spec: job.spec) else { return false }
            }
            guard let resolution = await videoSize(of: staged) else {
                try? fm.removeItem(at: staged)
                return false
            }
            switch publish(staged, job: job, resolution: resolution) {
            case .published:
                notifyLibraryChanged()
                return true
            case .stale: return true
            case .failed: return false
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
        let entries = (try? fm.contentsOfDirectory(at: videosFolderURL, includingPropertiesForKeys: nil)) ?? []
        for dir in entries {
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.lastPathComponent.hasSuffix(".tmp.mov") {
                try? fm.removeItem(at: file)
            }
        }
    }
}
