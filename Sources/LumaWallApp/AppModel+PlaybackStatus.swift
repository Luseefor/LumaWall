import Foundation
import LumaWallCore

extension AppModel {
    /// The status of the display, or nil when nothing plays there or nothing
    /// has reported it.
    func playbackStatus(for display: ConnectedDisplay) -> DisplayPlaybackStatus? {
        guard activeByDisplay[display.displayID] != nil else { return nil }
        return playbackStatuses[display.displayID]
    }

    /// Listen for the extension's status writes.
    func observePlaybackStatus() {
        playbackStatusObserver = PlaybackStatusObserver { [weak self] in
            Task { @MainActor in self?.refreshNativePlaybackStatus() }
        }
        refreshNativePlaybackStatus()
    }

    /// Re-read the extension's files. The extension numbers displays by their
    /// Core Graphics ID.
    func refreshNativePlaybackStatus() {
        guard engine.mode == .native else { return }
        nativePlaybackStatuses = PlaybackStatusReader.read()
        rebuildPlaybackStatuses()
    }

    /// Record what the overlay decided for each display, from the decisions
    /// `applyPlaybackPolicy` just made.
    func noteOverlayPlaybackDecisions(_ decisions: [DisplayID: (tier: PlaybackTier, reason: PlaybackStatusReason?)]) {
        overlayPlaybackDecisions = decisions
        rebuildPlaybackStatuses()
    }

    /// Each display takes its status from the engine drawing it: the
    /// overlay's own decision, or the extension's report.
    private func rebuildPlaybackStatuses() {
        var next: [DisplayID: DisplayPlaybackStatus] = [:]
        for display in displays {
            if engine.isDrawnByOverlay(display.displayID) {
                guard let decision = overlayPlaybackDecisions[display.displayID] else { continue }
                next[display.displayID] = DisplayPlaybackStatus(
                    displayID: display.cgDisplayID, overlayTier: decision.tier, reason: decision.reason)
            } else if let status = nativePlaybackStatuses.status(forDisplay: display.cgDisplayID) {
                next[display.displayID] = status
            }
        }
        if next != playbackStatuses { playbackStatuses = next }
    }
}
