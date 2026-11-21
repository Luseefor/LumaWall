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
        /// The frame rate of that file, 0 when unknown.
        let frameRate: Int
        /// The renderer gave up decoding and shows a still.
        let decodeFailed: Bool
    }

    static func status(_ input: Input) -> DisplayPlaybackStatus {
        let copy = PlaybackCopy(filename: input.filename)
        let rate = input.frameRate > 0 ? input.frameRate : nil
        // A sleeping display holds its frame whatever the tier says.
        if input.displayAsleep {
            return DisplayPlaybackStatus(
                displayID: input.displayID, state: .paused, reason: .displayAsleep, copy: copy, frameRate: rate)
        }
        // A tier that plays still shows a frame when the decoder gave up.
        if input.decodeFailed, input.decision.tier != .paused {
            return DisplayPlaybackStatus(
                displayID: input.displayID, state: .paused, reason: .decodeFailed, copy: copy, frameRate: rate)
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
