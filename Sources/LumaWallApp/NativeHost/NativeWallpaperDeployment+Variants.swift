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
        guard let metadata = try? entry(id: entryID) else { return }
        var variants = metadata.variants ?? []
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
        if var entry = try? entry(id: entryID) {
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
}
