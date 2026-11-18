import AVFoundation
import Foundation
import LumaWallCore

/// Smaller copies of deployed wallpapers: the battery tiers play them, and
/// Full Quality plays one when it still fills the display.
extension NativeWallpaperDeployment {
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

    /// One smaller copy to keep next to a deployed wallpaper.
    struct VariantSpec: Equatable {
        let filename: String
        /// Export preset; for `fitting` copies, the encoder preset.
        let preset: String
        /// Scale into this box (keeping the source aspect and frame rate)
        /// instead of using the preset's fixed size.
        let fitting: CGSize?
    }

    /// The copies a source of this size should have. The 1080p and 720p
    /// copies serve the battery tiers and 1080p monitors. The 1440p copy lets
    /// Full Quality on a 1440p monitor skip decoding 4K. Copies at or above
    /// the source size are never made.
    static func variantSpecs(sourceSize: CGSize) -> [VariantSpec] {
        let longSide = max(sourceSize.width, sourceSize.height)
        let portrait = sourceSize.height > sourceSize.width
        var specs: [VariantSpec] = []
        if longSide > 1920 { specs.append(VariantSpec(filename: "Wallpaper.reduced.mov", preset: AVAssetExportPreset1920x1080, fitting: nil)) }
        if longSide > 1280 { specs.append(VariantSpec(filename: "Wallpaper.minimal.mov", preset: AVAssetExportPreset1280x720, fitting: nil)) }
        if longSide > 2560 {
            specs.append(VariantSpec(
                filename: "Wallpaper.qhd.mov",
                preset: AVAssetExportPresetHEVCHighestQuality,
                fitting: portrait ? CGSize(width: 1440, height: 2560) : CGSize(width: 2560, height: 1440)
            ))
        }
        return specs
    }

    /// True when the entry lacks a copy its source size calls for, including
    /// copies added in later versions and listed copies deleted from disk.
    static func needsVariants(_ entry: EntryInfo, fileExists: ((String) -> Bool)? = nil) -> Bool {
        let exists = fileExists ?? { filename in
            FileManager.default.fileExists(atPath: videosFolderURL
                .appendingPathComponent(entry.id, isDirectory: true)
                .appendingPathComponent(filename).path)
        }
        let have = Set((entry.variants ?? []).map(\.filename).filter(exists))
        return variantSpecs(sourceSize: entry.resolution).contains { !have.contains($0.filename) }
    }

    /// Copies that failed this session, keyed "entryID/filename". A failure
    /// that keeps happening (disk full, unreadable source) would otherwise
    /// re-run most of an encode on every apply and restore.
    nonisolated(unsafe) private static var failedVariantWork = Set<String>()

    /// The 1440p copy only helps Full Quality on AC power, so it waits for AC
    /// instead of spending battery on an encode.
    private static var canMakeFullQualityCopies: Bool {
        !PowerStatus.current().isOnBattery && !ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    /// `current` with `added` applied, replacing same-named copies.
    static func merging(_ current: [NativeVideoVariant], with added: [NativeVideoVariant]) -> [NativeVideoVariant] {
        let replaced = Set(added.map(\.filename))
        return current.filter { !replaced.contains($0.filename) } + added
    }

    /// Transcode the copies `variantSpecs` plans and record them in
    /// metadata.json. Idempotent: skips copies already listed with a file on
    /// disk and regenerates missing ones. Runs detached in the background. A
    /// multi-GB 4K transcode must never block applying the wallpaper.
    ///
    /// Without these files the extension's variant selector always falls back
    /// to the full file, so Automatic-on-battery and Battery Saver resolve a
    /// cheaper tier and then play the exact same bytes ("does nothing").
    static func ensureVariants(for entryID: String, sourceURL: URL, sourceFPS: Double, sourceSize: CGSize) async {
        guard PathSafety.isValidEntryID(entryID) else { return }
        let fm = FileManager.default
        let dir = videosFolderURL.appendingPathComponent(entryID, isDirectory: true)
        guard fm.fileExists(atPath: dir.path) else { return }
        let fullQualityAllowed = canMakeFullQualityCopies
        let specs = variantSpecs(sourceSize: sourceSize).filter { $0.fitting == nil || fullQualityAllowed }
        guard !specs.isEmpty else { return }
        var changed = false
        for spec in specs {
            let workKey = entryID + "/" + spec.filename
            guard claimVariantWork(workKey) else { continue }
            defer { finishVariantWork(workKey) }
            // Recheck under the claim: another worker may have finished this
            // copy after the caller decided it was missing.
            if isRecorded(spec.filename, entryID: entryID, in: dir) { continue }
            if variantWorkLock.withLock({ failedVariantWork.contains(workKey) }) { continue }
            guard let variant = await transcode(sourceURL: sourceURL, dir: dir, spec: spec, sourceFPS: sourceFPS) else {
                variantWorkLock.withLock { _ = failedVariantWork.insert(workKey) }
                continue
            }
            // Record before releasing the claim, so no worker sees the file
            // without its metadata entry and encodes it again.
            record([variant], for: entryID, in: dir)
            changed = true
        }
        if changed { notifyLibraryChanged() }
    }

    private static func isRecorded(_ filename: String, entryID: String, in dir: URL) -> Bool {
        guard let entry = try? entry(id: entryID),
              (entry.variants ?? []).contains(where: { $0.filename == filename })
        else { return false }
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent(filename).path)
    }

    /// Re-reads metadata.json and merges `produced` into it. Another worker
    /// may have recorded its own copy since this one started; writing the
    /// list read before transcoding dropped that copy.
    private static func record(_ produced: [NativeVideoVariant], for entryID: String, in dir: URL) {
        variantMetadataLock.withLock {
            guard var latest = try? entry(id: entryID) else { return }
            let fm = FileManager.default
            let current = (latest.variants ?? []).filter { fm.fileExists(atPath: dir.appendingPathComponent($0.filename).path) }
            latest.variants = merging(current, with: produced)
            if let data = try? JSONEncoder().encode(latest) {
                try? data.write(to: dir.appendingPathComponent("metadata.json"), options: .atomic)
            }
        }
    }

    /// Serializes the read-merge-write of metadata.json across workers.
    private static let variantMetadataLock = NSLock()

    private static func transcode(sourceURL: URL, dir: URL, spec: VariantSpec, sourceFPS: Double) async -> NativeVideoVariant? {
        let source = AVURLAsset(url: sourceURL)
        guard let export = AVAssetExportSession(asset: source, presetName: spec.preset) else { return nil }
        let temp = dir.appendingPathComponent("\(spec.filename).\(UUID().uuidString).tmp.mov")
        do {
            if let box = spec.fitting {
                guard let composition = try await scaledComposition(for: source, fitting: box, fps: sourceFPS) else { return nil }
                export.videoComposition = composition
            }
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
            let dest = dir.appendingPathComponent(spec.filename)
            if FileManager.default.fileExists(atPath: dest.path) {
                try? FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: temp, to: dest)
            return NativeVideoVariant(filename: spec.filename, fps: Int(sourceFPS.rounded()), resolution: resolution)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            return nil
        }
    }

    /// Frame duration for a copy that keeps the source cadence. NTSC rates
    /// (23.976, 29.97, 59.94...) use their exact 1001-based duration; rounding
    /// them repeats a frame every few seconds. Other rates, including
    /// irregular ones, round to the nearest whole rate, which matches their
    /// average frame count better than the shortest frame gap does.
    static func copyFrameDuration(nominalFPS fps: Double) -> CMTime {
        for base in [24, 30, 48, 60, 120] {
            let ntsc = Double(base) * 1000 / 1001
            if abs(fps - ntsc) < 0.01 { return CMTime(value: 1001, timescale: CMTimeScale(base * 1000)) }
        }
        return CMTime(value: 1, timescale: CMTimeScale(max(1, fps.rounded())))
    }

    /// Scales the source into `box` (aspect kept, even dimensions) at the
    /// source frame rate. The fixed-size presets only offer 1080p and 4K.
    private static func scaledComposition(for asset: AVURLAsset, fitting box: CGSize, fps: Double) async throws -> AVVideoComposition? {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return nil }
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let duration = try await asset.load(.duration)
        // Where the oriented frame lands; a rotation can carry an offset that
        // would otherwise leave a black strip and clip the opposite edge.
        let oriented = CGRect(origin: .zero, size: natural).applying(transform)
        let width = oriented.width, height = oriented.height
        guard width > 0, height > 0 else { return nil }
        let scale = min(box.width / width, box.height / height, 1)
        let placed = transform
            .concatenating(CGAffineTransform(translationX: -oriented.minX, y: -oriented.minY))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(placed, at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.layerInstructions = [layer]
        let composition = AVMutableVideoComposition()
        composition.instructions = [instruction]
        composition.renderSize = CGSize(width: (width * scale / 2).rounded() * 2, height: (height * scale / 2).rounded() * 2)
        composition.frameDuration = copyFrameDuration(nominalFPS: fps)
        return composition
    }
}
