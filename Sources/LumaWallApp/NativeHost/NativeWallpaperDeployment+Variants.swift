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
    /// copies added in later versions.
    static func needsVariants(_ entry: EntryInfo) -> Bool {
        let have = Set((entry.variants ?? []).map(\.filename))
        return variantSpecs(sourceSize: entry.resolution).contains { !have.contains($0.filename) }
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
        let specs = variantSpecs(sourceSize: sourceSize)
        guard !specs.isEmpty, let metadata = try? entry(id: entryID) else { return }
        let onDisk = { (variant: NativeVideoVariant) in fm.fileExists(atPath: dir.appendingPathComponent(variant.filename).path) }
        let present = Set((metadata.variants ?? []).filter(onDisk).map(\.filename))
        var produced: [NativeVideoVariant] = []
        for spec in specs where !present.contains(spec.filename) {
            let workKey = entryID + "/" + spec.filename
            guard claimVariantWork(workKey) else { continue }
            let variant = await transcode(sourceURL: sourceURL, dir: dir, spec: spec, sourceFPS: sourceFPS)
            finishVariantWork(workKey)
            if let variant { produced.append(variant) }
        }
        guard !produced.isEmpty else { return }
        record(produced, for: entryID, in: dir)
        notifyLibraryChanged()
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

    /// Scales the source into `box` (aspect kept, even dimensions) at the
    /// source frame rate. The fixed-size presets only offer 1080p and 4K.
    private static func scaledComposition(for asset: AVURLAsset, fitting box: CGSize, fps: Double) async throws -> AVVideoComposition? {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return nil }
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let duration = try await asset.load(.duration)
        let oriented = natural.applying(transform)
        let width = abs(oriented.width), height = abs(oriented.height)
        guard width > 0, height > 0 else { return nil }
        let scale = min(box.width / width, box.height / height, 1)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(transform.concatenating(CGAffineTransform(scaleX: scale, y: scale)), at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.layerInstructions = [layer]
        let composition = AVMutableVideoComposition()
        composition.instructions = [instruction]
        composition.renderSize = CGSize(width: (width * scale / 2).rounded() * 2, height: (height * scale / 2).rounded() * 2)
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, fps.rounded())))
        return composition
    }
}
