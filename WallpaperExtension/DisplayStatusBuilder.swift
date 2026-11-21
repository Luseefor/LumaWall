import Foundation

/// Turns what the extension knows about one display into the status the app
/// shows. Pure, so the rules (sleep beats a tier, a copy's rate) are tested.
enum DisplayStatusBuilder {
    struct Input {
        let displayID: UInt32
        let decision: PlaybackPolicy.Decision
        let displayAsleep: Bool
        /// The file the renderer reads, e.g. `Wallpaper.reduced.mov`.
        let filename: String
        /// The original's frame rate, and each copy's by filename.
        let sourceFPS: Int
        let variantFPS: [String: Int]
    }

    static func status(_ input: Input) -> DisplayPlaybackStatus {
        let copy = PlaybackCopy(filename: input.filename)
        let fps = input.variantFPS[input.filename] ?? input.sourceFPS
        let rate = fps > 0 ? fps : nil
        // A sleeping display holds its frame whatever the tier says.
        if input.displayAsleep {
            return DisplayPlaybackStatus(
                displayID: input.displayID, state: .paused, reason: .displayAsleep, copy: copy, frameRate: rate)
        }
        let paused = input.decision.tier == .paused
        return DisplayPlaybackStatus(
            displayID: input.displayID,
            state: paused ? .paused : .playing,
            reason: input.decision.reason,
            copy: copy,
            frameRate: rate
        )
    }
}
