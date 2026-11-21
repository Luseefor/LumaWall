import Foundation

extension WallpaperPrefs {
    /// One status per display with a live, open surface: the decision
    /// `applyPolicies` last gave its renderers (or one computed now, before
    /// the first), and the state of its renderer. Several surfaces on one
    /// display (one per Space) share a wallpaper, so the first open one
    /// speaks for it.
    func currentDisplayStatuses() -> [DisplayPlaybackStatus] {
        let state = WallpaperState.shared
        let publisher = DisplayStatusPublisher.shared
        var seen = Set<UInt32>()
        return state.liveStatusSources().compactMap { source in
            guard seen.insert(source.displayID).inserted else { return nil }
            let decision =
                publisher.decision(for: source.displayID)
                ?? self.decision(
                    for: source.displayID,
                    presentationMode: state.presentationMode,
                    activityState: state.activityState,
                    powerState: PowerMonitor.shared.currentState
                )
            return DisplayStatusBuilder.status(
                .init(
                    displayID: source.displayID,
                    decision: decision,
                    displayAsleep: source.info.displayAsleep,
                    filename: source.info.url.lastPathComponent,
                    frameRate: publisher.frameRate(of: source.info.url),
                    decodeFailed: source.info.decodeFailed
                ))
        }
    }
}
