import CoreMedia
import Foundation

public enum PlaybackFrameRate {
    /// Pump interval for shared overlay decoders, capped to the display refresh rate.
    public static func pumpInterval(sourceFPS: Double, displayMaxFPS: Double) -> TimeInterval {
        let source = sourceFPS.isFinite && sourceFPS > 0 ? sourceFPS : 60
        let display = displayMaxFPS.isFinite && displayMaxFPS > 0 ? displayMaxFPS : 60
        return 1.0 / min(source, display)
    }

    /// One-frame CMTime step when a sample buffer has no duration metadata.
    public static func frameDuration(fps: Double) -> CMTime {
        let rate = max(fps.isFinite ? fps : 60, 1)
        let timescale = CMTimeScale(min(120_000, max(1, Int((rate * 100).rounded()))))
        return CMTime(value: 100, timescale: timescale)
    }
}
