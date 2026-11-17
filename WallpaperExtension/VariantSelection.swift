import Foundation

struct VideoVariant: Codable, Equatable {
    let filename: String
    let fps: Int
    let resolution: CGSize
}

/// Picks the variant to play for a playback policy, the pure half of
/// `VideoLibrary.bestVariantURL`, separated so it can be tested.
enum VariantSelection {
    /// The variant to play, or nil for the original file.
    ///
    /// `full` plays the original unless a variant matches the source frame
    /// rate AND covers the source resolution (a 720p-only library must not
    /// downscale Full Quality). `reduced` picks the highest tier below the
    /// source rate (falling back to the smallest), `minimal` the smallest.
    /// `displayPixels` (the display's size in pixels) lets `full` play the
    /// smallest copy at the source frame rate that still fills the display
    /// without upscaling: a 1440p monitor at 1x gains nothing from 4K.
    /// `paused` and an empty variant list resolve to the original. Equal-fps
    /// ties break by resolution so the pick is deterministic (Swift's sort is
    /// not stable, without this, reduced/minimal could land on the 1080p
    /// sibling instead of the 720p one).
    static func variant(
        for policy: PlaybackPolicy,
        sourceFPS: Int,
        sourceResolution: CGSize,
        variants: [VideoVariant],
        displayPixels: CGSize? = nil,
    ) -> VideoVariant? {
        guard !variants.isEmpty else { return nil }
        let sorted = variants.sorted {
            if $0.fps != $1.fps { return $0.fps > $1.fps }
            return ($0.resolution.width * $0.resolution.height) > ($1.resolution.width * $1.resolution.height)
        }

        switch policy {
        case .paused:
            return nil
        case .full:
            if let displayPixels,
               let fitted = smallestFilling(displayPixels, sourceFPS: sourceFPS, sourceResolution: sourceResolution, variants: variants) {
                return fitted
            }
            guard let top = sorted.first,
                  top.fps >= sourceFPS,
                  covers(top.resolution, sourceResolution)
            else { return nil }
            return top
        case .reduced:
            return sorted.first { $0.fps < sourceFPS } ?? sorted.last
        case .minimal:
            return sorted.last
        }
    }

    /// The smallest copy at the source frame rate that aspect-fills `display`
    /// without upscaling, when it is smaller than the source.
    private static func smallestFilling(
        _ display: CGSize,
        sourceFPS: Int,
        sourceResolution: CGSize,
        variants: [VideoVariant],
    ) -> VideoVariant? {
        guard display.width > 0, display.height > 0 else { return nil }
        let sourceArea = sourceResolution.width * sourceResolution.height
        return variants
            .filter { $0.fps >= sourceFPS }
            .filter { $0.resolution.width * $0.resolution.height < sourceArea }
            .filter { fills($0.resolution, display) }
            .min { $0.resolution.width * $0.resolution.height < $1.resolution.width * $1.resolution.height }
    }

    /// Aspect fill scales the video by the larger of the two ratios; above 1
    /// the video would be upscaled and look soft.
    private static func fills(_ video: CGSize, _ display: CGSize) -> Bool {
        guard video.width > 0, video.height > 0 else { return false }
        let scale = max(display.width / video.width, display.height / video.height)
        return scale <= 1.0
    }

    /// Orientation-agnostic coverage: the variant covers the source when both
    /// its long and short sides meet the source's.
    private static func covers(_ variant: CGSize, _ source: CGSize) -> Bool {
        max(variant.width, variant.height) >= max(source.width, source.height)
            && min(variant.width, variant.height) >= min(source.width, source.height)
    }
}
