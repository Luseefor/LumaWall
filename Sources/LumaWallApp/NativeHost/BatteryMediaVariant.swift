import AVFoundation
import Foundation
import LumaWallCore

/// Silent 1280x720 library sibling used on reduced and minimal tiers.
enum BatteryMediaVariant {
    /// Tracks assets with a transcode currently running (see `ensure`).
    /// MainActor-guarded: every caller is MainActor-isolated.
    @MainActor
    private static var inFlight = Set<String>()

    static func url(for asset: WallpaperAsset) -> URL {
        asset.mediaURL.deletingLastPathComponent().appendingPathComponent("Wallpaper.battery.mov")
    }

    static func resolvedURL(for asset: WallpaperAsset, tier: PlaybackTier) -> URL {
        let variant = url(for: asset)
        switch tier {
        case .reduced, .minimal:
            if FileManager.default.fileExists(atPath: variant.path) { return variant }
            return asset.mediaURL
        default:
            return asset.mediaURL
        }
    }

    @MainActor
    static func ensure(for asset: WallpaperAsset) async {
        let dest = url(for: asset)
        if FileManager.default.fileExists(atPath: dest.path) { return }
        // Transcode anything above 720p: the sibling is what reduced/minimal
        // tiers actually play, so without it those profiles only move a bitrate
        // hint and look like they "do nothing". 720p and below play as-is.
        guard max(asset.pixelSize.width, asset.pixelSize.height) > 1_280
        else { return }
        // Applies fan out one ensure per display/session; without this two of
        // them transcode the same source at once (all callers are MainActor,
        // so a plain set suffices).
        let key = asset.mediaURL.standardizedFileURL.path
        guard inFlight.insert(key).inserted else { return }
        defer { inFlight.remove(key) }

        let source = AVURLAsset(url: asset.mediaURL)
        guard let export = AVAssetExportSession(asset: source, presetName: AVAssetExportPreset1280x720)
            ?? AVAssetExportSession(asset: source, presetName: AVAssetExportPresetMediumQuality)
        else { return }
        let temp = dest.deletingLastPathComponent()
            .appendingPathComponent("Wallpaper.battery.\(UUID().uuidString).mov")
        do {
            try await export.export(to: temp, as: .mov)
            if FileManager.default.fileExists(atPath: dest.path) {
                try? FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: temp, to: dest)
        } catch {
            try? FileManager.default.removeItem(at: temp)
        }
    }
}
