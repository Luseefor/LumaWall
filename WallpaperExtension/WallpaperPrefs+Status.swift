import Foundation

extension WallpaperPrefs {
    /// One status per display with a live, open surface, from the policy and
    /// renderer state as they are now. Several surfaces on one display (one
    /// per Space) show the same wallpaper, so the first open one speaks for it.
    func currentDisplayStatuses() -> [DisplayPlaybackStatus] {
        let state = WallpaperState.shared
        let power = PowerMonitor.shared.currentState
        var seen = Set<UInt32>()
        return state.liveStatusSources().compactMap { source in
            guard seen.insert(source.displayID).inserted else { return nil }
            let entry = source.videoID.flatMap { VideoLibrary.shared.entry(for: $0) }
            let decision = decision(
                for: source.displayID,
                presentationMode: state.presentationMode,
                activityState: state.activityState,
                powerState: power
            )
            return DisplayStatusBuilder.status(
                .init(
                    displayID: source.displayID,
                    decision: decision,
                    displayAsleep: source.info.displayAsleep,
                    filename: source.info.filename,
                    sourceFPS: VariantSelection.wholeFPS(entry?.fps ?? 0),
                    variantFPS: Dictionary(
                        (entry?.variants ?? []).map { ($0.filename, $0.fps) }, uniquingKeysWith: { first, _ in first })
                ))
        }
    }
}
