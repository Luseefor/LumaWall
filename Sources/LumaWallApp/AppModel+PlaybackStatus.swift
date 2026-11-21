import Foundation
import LumaWallCore

extension AppModel {
    /// The status of the display, or nil when nothing plays there or the
    /// extension hasn't reported it.
    func playbackStatus(for display: ConnectedDisplay) -> DisplayPlaybackStatus? {
        guard activeByDisplay[display.displayID] != nil else { return nil }
        return playbackStatuses[display.displayID]
    }

    /// Listen for the extension's status writes. Native mode only: the
    /// overlay decides its own state in `applyPlaybackPolicy`.
    func observePlaybackStatus() {
        playbackStatusObserver = PlaybackStatusObserver { [weak self] in
            Task { @MainActor in self?.refreshNativePlaybackStatus() }
        }
        refreshNativePlaybackStatus()
    }

    /// Re-read the extension's file. The extension numbers displays by their
    /// Core Graphics ID.
    func refreshNativePlaybackStatus() {
        guard engine.mode == .native else { return }
        let snapshot = PlaybackStatusReader.read()
        var next: [DisplayID: DisplayPlaybackStatus] = [:]
        for display in displays {
            if let status = snapshot?.status(forDisplay: display.cgDisplayID) { next[display.displayID] = status }
        }
        if next != playbackStatuses { playbackStatuses = next }
    }

    /// Record what the overlay did with each display, from the decisions
    /// `applyPlaybackPolicy` just made.
    func noteOverlayPlaybackStatus(_ decisions: [DisplayID: (tier: PlaybackTier, reason: PlaybackStatusReason?)]) {
        guard engine.mode == .overlay else { return }
        var next: [DisplayID: DisplayPlaybackStatus] = [:]
        for display in displays {
            guard let decision = decisions[display.displayID] else { continue }
            next[display.displayID] = DisplayPlaybackStatus(
                displayID: display.cgDisplayID, overlayTier: decision.tier, reason: decision.reason)
        }
        if next != playbackStatuses { playbackStatuses = next }
    }
}
