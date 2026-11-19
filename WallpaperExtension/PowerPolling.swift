import Foundation

/// Which power readings `PowerMonitor`'s periodic check takes. Battery and
/// brightness have no change notification the extension uses, so they are
/// polled, but only while a reading can change what plays (#14).
enum PowerPolling: Equatable {
    case off
    /// Nothing plays and the backlight is at zero: read only brightness, so
    /// raising it resumes playback.
    case brightness
    case all

    /// Seconds between reads while the poll runs.
    static let interval: TimeInterval = 30

    /// Whether a battery and brightness reading taken at `lastRead` is too old
    /// to compute a policy from. While the poll is stopped, the reading can be
    /// from before the Mac was unplugged or the displays slept.
    static func readIsStale(lastRead: Date?, now: Date) -> Bool {
        guard let lastRead else { return true }
        let age = now.timeIntervalSince(lastRead)
        return age < 0 || age >= interval
    }

    static func mode(anyPlaying: Bool, batteryLevel: Int, displayBrightness: Float) -> PowerPolling {
        if anyPlaying { return .all }
        // The critical-battery pause holds on AC too; charging past the level
        // resumes playback.
        if batteryLevel < PlaybackPolicy.batteryCriticalLevel { return .all }
        if displayBrightness < PlaybackPolicy.brightnessPauseThreshold { return .brightness }
        return .off
    }
}

/// Renderers whose lifecycle wants playback, keyed by `VideoRenderer.debugID`.
struct PlayingRenderers {
    private var ids: Set<Int> = []

    var anyPlaying: Bool { !ids.isEmpty }

    /// Record one renderer; true when `anyPlaying` changed.
    mutating func set(_ id: Int, playing: Bool) -> Bool {
        let before = anyPlaying
        if playing { ids.insert(id) } else { ids.remove(id) }
        return before != anyPlaying
    }
}
