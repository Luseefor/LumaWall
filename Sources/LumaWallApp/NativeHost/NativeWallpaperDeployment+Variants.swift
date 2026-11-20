import AVFoundation
import Foundation
import LumaWallCore

/// Smaller copies of deployed wallpapers: the battery tiers play them, and
/// Full Quality plays one when it still fills the display.
extension NativeWallpaperDeployment {
    /// One smaller copy to keep next to a deployed wallpaper.
    struct VariantSpec: Equatable, Sendable {
        let filename: String
        let preset: String
        /// Scaled into this box, keeping the source aspect.
        let fitting: CGSize
        /// Target frame rate.
        let fps: Double
        /// Only Full Quality plays it, so it is made on AC power only.
        let forFullQuality: Bool

        /// The frame rate recorded in metadata.json for this copy.
        var recordedFPS: Int { Int(fps.rounded()) }
    }

    /// The frame rates `MediaInfo.isPlausible` accepts from a probe. Anything
    /// else (NaN, infinite, negative, huge) would trap converting to `Int`.
    static func isPlausibleFPS(_ fps: Double) -> Bool {
        fps.isFinite && fps >= 0 && fps <= 1_000
    }

    /// Battery copies above 30 fps drop to a whole divisor of the source rate
    /// (60 to 30, 59.94 to 29.97, 120 to 30, 50 to 25), keeping frames evenly
    /// spaced. Decoding and redrawing 60 frames a second at 720p on battery
    /// cost twice what 30 does, for motion nobody studies on a wallpaper.
    static func batteryFPS(source fps: Double) -> Double {
        guard fps > 30.01 else { return fps }
        return fps / (fps / 30 - 0.001).rounded(.up)
    }

    /// The copies a source should have. The 1080p and 720p copies serve the
    /// battery tiers, capped at 30 fps. The 1440p copy keeps the source rate
    /// so Full Quality on a 1440p monitor can skip decoding 4K. Copies at or
    /// above the source size are never made. With `displayPixels` (connected
    /// displays, in pixels) the 1440p copy is planned only when one of them
    /// would play it. A frame rate outside `isPlausibleFPS` plans nothing.
    static func variantSpecs(sourceSize: CGSize, sourceFPS: Double, displayPixels: [CGSize]? = nil) -> [VariantSpec] {
        guard isPlausibleFPS(sourceFPS) else { return [] }
        let specs = allVariantSpecs(sourceSize: sourceSize, sourceFPS: sourceFPS)
        guard let displayPixels else { return specs }
        return specs.filter { spec in
            !spec.forFullQuality
                || displayPixels.contains { display in
                    fullQualityPick(among: specs, sourceSize: sourceSize, sourceFPS: sourceFPS, display: display) == spec
                }
        }
    }

    /// The copy the extension's Full Quality selection would play on
    /// `display`: the smallest one at the source rate that aspect-fills it
    /// without upscaling. Mirrors `VariantSelection.smallestFilling`.
    static func fullQualityPick(among specs: [VariantSpec], sourceSize: CGSize, sourceFPS: Double, display: CGSize) -> VariantSpec? {
        guard display.width > 0, display.height > 0, isPlausibleFPS(sourceFPS) else { return nil }
        let sourceRate = Int(sourceFPS.rounded())
        func area(_ spec: VariantSpec) -> CGFloat {
            let size = copySize(source: sourceSize, fitting: spec.fitting)
            return size.width * size.height
        }
        return
            specs
            .filter { $0.recordedFPS >= sourceRate }
            .filter { spec in
                let size = copySize(source: sourceSize, fitting: spec.fitting)
                return size.width > 0 && size.height > 0
                    && max(display.width / size.width, display.height / size.height) <= 1
            }
            .min { area($0) < area($1) }
    }

    /// The frame size `scaledComposition` renders: the source scaled into
    /// `box` with its aspect kept, rounded to even dimensions.
    static func copySize(source: CGSize, fitting box: CGSize) -> CGSize {
        guard source.width > 0, source.height > 0 else { return .zero }
        let scale = min(box.width / source.width, box.height / source.height, 1)
        return CGSize(width: (source.width * scale / 2).rounded() * 2, height: (source.height * scale / 2).rounded() * 2)
    }

    private static func allVariantSpecs(sourceSize: CGSize, sourceFPS: Double) -> [VariantSpec] {
        let longSide = max(sourceSize.width, sourceSize.height)
        let portrait = sourceSize.height > sourceSize.width
        func box(_ long: CGFloat, _ short: CGFloat) -> CGSize {
            portrait ? CGSize(width: short, height: long) : CGSize(width: long, height: short)
        }
        let battery = batteryFPS(source: sourceFPS)
        var specs: [VariantSpec] = []
        if longSide > 1920 {
            specs.append(
                VariantSpec(
                    filename: "Wallpaper.reduced.mov", preset: AVAssetExportPresetHighestQuality,
                    fitting: box(1920, 1080), fps: battery, forFullQuality: false))
        }
        if longSide > 1280 {
            specs.append(
                VariantSpec(
                    filename: "Wallpaper.minimal.mov", preset: AVAssetExportPresetHighestQuality,
                    fitting: box(1280, 720), fps: battery, forFullQuality: false))
        }
        if longSide > 2560 {
            specs.append(
                VariantSpec(
                    filename: "Wallpaper.qhd.mov", preset: AVAssetExportPresetHEVCHighestQuality,
                    fitting: box(2560, 1440), fps: sourceFPS, forFullQuality: true))
        }
        return specs
    }

    /// True when the entry lacks a copy it should have: one added in a later
    /// version, one deleted from disk, or one made at a different frame rate.
    static func needsVariants(_ entry: EntryInfo, displayPixels: [CGSize], fileExists: ((String) -> Bool)? = nil) -> Bool {
        // A symlink where a copy should be doesn't count: previews refuse it,
        // so it has to be encoded again.
        let exists = fileExists ?? { isRegularFile($0, inEntry: entry.id) }
        let have = entry.variants ?? []
        return variantSpecs(sourceSize: entry.resolution, sourceFPS: entry.fps, displayPixels: displayPixels).contains { spec in
            !have.contains { $0.filename == spec.filename && $0.fps == spec.recordedFPS && exists($0.filename) }
        }
    }

    /// The 1440p copy only helps Full Quality on AC power, so it waits for AC
    /// instead of spending battery on an encode.
    static var canMakeFullQualityCopies: Bool {
        !PowerStatus.current().isOnBattery && !ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    /// `current` with `added` applied, replacing same-named copies.
    static func merging(_ current: [NativeVideoVariant], with added: [NativeVideoVariant]) -> [NativeVideoVariant] {
        let replaced = Set(added.map(\.filename))
        return current.filter { !replaced.contains($0.filename) } + added
    }

    enum TranscodeResult { case finished, failed, skipped }

    /// Exports `spec` to `output`, writing a `.partial.mov` beside it first
    /// so an interrupted export never sits under the finished name.
    /// `proceed` is asked once more right before the export starts, after
    /// the composition is set up; a no, or task cancellation, skips it.
    static func transcode(sourceURL: URL, to output: URL, spec: VariantSpec, proceed: () -> Bool) async -> TranscodeResult {
        let source = AVURLAsset(url: sourceURL)
        guard let export = AVAssetExportSession(asset: source, presetName: spec.preset) else { return .failed }
        let partial = output.deletingPathExtension().appendingPathExtension("\(UUID().uuidString).partial.mov")
        do {
            guard let composition = try await scaledComposition(for: source, fitting: spec.fitting, fps: spec.fps) else { return .failed }
            export.videoComposition = composition
            guard !Task.isCancelled, proceed() else { return .skipped }
            try await export.export(to: partial, as: .mov)
            try? FileManager.default.removeItem(at: output)
            try FileManager.default.moveItem(at: partial, to: output)
            return .finished
        } catch {
            try? FileManager.default.removeItem(at: partial)
            return Task.isCancelled || error is CancellationError ? .skipped : .failed
        }
    }

    /// Oriented pixel size of a movie's video track, or nil when unreadable.
    static func videoSize(of url: URL) async -> CGSize? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
            let natural = try? await track.load(.naturalSize),
            let transform = try? await track.load(.preferredTransform)
        else { return nil }
        let transformed = natural.applying(transform)
        let size = CGSize(width: abs(transformed.width), height: abs(transformed.height))
        return size.width > 0 && size.height > 0 ? size : nil
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
        let placed =
            transform
            .concatenating(CGAffineTransform(translationX: -oriented.minX, y: -oriented.minY))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(placed, at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.layerInstructions = [layer]
        let composition = AVMutableVideoComposition()
        composition.instructions = [instruction]
        composition.renderSize = copySize(source: CGSize(width: width, height: height), fitting: box)
        composition.frameDuration = copyFrameDuration(nominalFPS: fps)
        return composition
    }
}
