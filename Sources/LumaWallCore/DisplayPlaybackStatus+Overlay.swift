import Foundation

// Not in `DisplayPlaybackStatus.swift`, which the extension also compiles and
// which has no `PlaybackTier`.
extension DisplayPlaybackStatus {
    /// The status of a display the app's own overlay draws (Safe mode). A
    /// still frame counts as paused. The overlay plays the original at Full
    /// and a battery copy below it, which has no tier name, so only Full names
    /// its copy.
    public init(displayID: UInt32, overlayTier tier: PlaybackTier, reason: PlaybackStatusReason?) {
        switch tier {
        case .full, .reduced, .minimal:
            self.init(
                displayID: displayID, state: .playing, reason: reason,
                copy: tier == .full ? .full : nil, engine: .overlay)
        case .staticFrame, .paused:
            self.init(displayID: displayID, state: .paused, reason: reason, engine: .overlay)
        }
    }
}
