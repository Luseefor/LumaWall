import AVFoundation
import Foundation
import LumaWallCore

/// Silent 1280x720 library sibling used on reduced and minimal tiers.
enum BatteryMediaVariant {
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
        guard asset.framesPerSecond > 30
            || max(asset.pixelSize.width, asset.pixelSize.height) > 1_920
        else { return }

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
