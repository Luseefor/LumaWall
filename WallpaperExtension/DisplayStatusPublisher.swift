import Foundation
import os

/// Publishes what each display is doing to `Documents/playback-status.json`
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
    }

    private let queue = DispatchQueue(label: "display-status", qos: .utility)
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents").appendingPathComponent(PlaybackStatusSnapshot.fileName)

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
        guard changed, let data = try? snapshot.encoded() else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            extensionLog("[Status] write failed: \(error.localizedDescription)")
            state.withLock { $0.lastWritten = nil }
            return
        }
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(PlaybackStatusSnapshot.notificationName as CFString),
            nil, nil, true
        )
    }
}
