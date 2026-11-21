import AVFoundation
import Foundation
import os

/// Publishes what each display is doing to `Documents/playback-status.<pid>.json`
/// and posts the Darwin notification the app re-reads on, so the app can show
/// the state, reason and copy without asking.
///
/// Callers `markDirty()` whenever something that could change a status does.
/// Bursts (a lock changes the policy, then every renderer's lifecycle) fold
/// into one write after `debounce`, and an unchanged snapshot isn't written
/// at all. Nothing polls.
final class DisplayStatusPublisher: Sendable {
    static let shared = DisplayStatusPublisher()

    static let debounce: DispatchTimeInterval = .milliseconds(250)

    private struct State {
        var scheduled = false
        var lastWritten: PlaybackStatusSnapshot?
        /// What `applyPolicies` last decided for each display, so the status
        /// is the decision the renderers got, not a second computation.
        var decisions: [UInt32: PlaybackPolicy.Decision] = [:]
        /// Frame rate by file; 0 while loading. A file's rate doesn't change.
        var frameRates: [URL: Int] = [:]
    }

    private let queue = DispatchQueue(label: "display-status", qos: .utility)
    private let state = OSAllocatedUnfairLock(initialState: State())
    /// This process's own file; a sibling extension process writes its own.
    private let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents")
        .appendingPathComponent(PlaybackStatusSnapshot.fileName(pid: ProcessInfo.processInfo.processIdentifier))

    /// Record the decisions `applyPolicies` just applied.
    func record(decisions: [UInt32: PlaybackPolicy.Decision]) {
        state.withLock { $0.decisions = decisions }
    }

    func decision(for displayID: UInt32) -> PlaybackPolicy.Decision? {
        state.withLock { $0.decisions[displayID] }
    }

    /// The frame rate of `url`, 0 until its track loads; the first ask starts
    /// the load and publishes again when it lands.
    func frameRate(of url: URL) -> Int {
        let start = state.withLock { state -> Bool in
            guard state.frameRates[url] == nil else { return false }
            state.frameRates[url] = 0
            return true
        }
        if start {
            Task.detached(priority: .utility) { [self] in
                let rate = await Self.loadFrameRate(of: url)
                state.withLock { $0.frameRates[url] = rate }
                markDirty()
            }
        }
        return state.withLock { $0.frameRates[url] ?? 0 }
    }

    private static func loadFrameRate(of url: URL) async -> Int {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
            let rate = try? await track.load(.nominalFrameRate)
        else { return 0 }
        return VariantSelection.wholeFPS(Double(rate))
    }

    func markDirty() {
        let schedule = state.withLock { state -> Bool in
            guard !state.scheduled else { return false }
            state.scheduled = true
            return true
        }
        guard schedule else { return }
        queue.asyncAfter(deadline: .now() + Self.debounce) { [self] in
            state.withLock { $0.scheduled = false }
            publish()
        }
    }

    private func publish() {
        let snapshot = PlaybackStatusSnapshot(statuses: WallpaperPrefs.shared.currentDisplayStatuses())
        let changed = state.withLock { state -> Bool in
            guard state.lastWritten != snapshot else { return false }
            state.lastWritten = snapshot
            return true
        }
        guard changed else { return }
        // No display, no file: a process with nothing to report (a Settings
        // preview) leaves no stale snapshot behind.
        guard !snapshot.statuses.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            notify()
            return
        }
        guard let data = try? snapshot.encoded() else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            extensionLog("[Status] write failed: \(error.localizedDescription)")
            state.withLock { $0.lastWritten = nil }
            return
        }
        notify()
    }

    private func notify() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(PlaybackStatusSnapshot.notificationName as CFString),
            nil, nil, true
        )
    }
}
