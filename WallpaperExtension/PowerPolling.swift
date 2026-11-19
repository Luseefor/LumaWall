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

/// The poll's mode from renderer playback and the latest hardware reading.
/// Every reading goes through `reading`, whatever asked for it: a policy
/// computed while nothing plays can find a hardware pause, and then only the
/// poll can notice it lift.
struct PowerPoller {
    /// What to do with the poll timer.
    enum Timer: Equatable { case start, stop, keep }

    private(set) var mode = PowerPolling.off
    private var playing = PlayingRenderers()
    private var batteryLevel = 100
    private var displayBrightness: Float = 1

    var anyPlaying: Bool { playing.anyPlaying }

    mutating func reading(batteryLevel: Int, displayBrightness: Float) -> Timer {
        self.batteryLevel = batteryLevel
        self.displayBrightness = displayBrightness
        return reconcile()
    }

    mutating func playback(_ id: Int, playing isPlaying: Bool) -> Timer {
        guard playing.set(id, playing: isPlaying) else { return .keep }
        return reconcile()
    }

    private mutating func reconcile() -> Timer {
        let next = PowerPolling.mode(anyPlaying: anyPlaying, batteryLevel: batteryLevel, displayBrightness: displayBrightness)
        defer { mode = next }
        if next == .off { return mode == .off ? .keep : .stop }
        return mode == .off ? .start : .keep
    }
}

/// What `PowerMonitor` knows about the Mac's power and thermal state.
struct PowerSnapshot: Equatable {
    var thermalState: ProcessInfo.ThermalState = .nominal
    var isOnBattery = false
    var batteryLevel: Int = 100
    var isGameModeActive: Bool = false
    var isLowPowerModeEnabled = false
    /// Backlight brightness of the built-in display, 0.0–1.0. Defaults to 1.0
    /// when the value can't be read (external displays, headless, etc.).
    var displayBrightness: Float = 1.0
}

/// The power state with when its battery fields were read. One hardware read
/// merges in one step, so a reader never sees battery from one read and
/// brightness from another, or a fresh time on an old battery reading.
struct PowerSample {
    var state = PowerSnapshot()
    private(set) var batteryReadAt: Date?

    /// Merge one read that started at `now`. `battery` nil (the read failed,
    /// or only brightness was read) keeps the old battery fields and their
    /// time, and so does a battery reading started before the one merged
    /// last: a transition reads the power source off the poll queue, and an
    /// older poll read landing after it must not undo it. `brightness` nil
    /// (a power-source read) keeps the old brightness. True when `state`
    /// changed.
    mutating func merge(battery: (onBattery: Bool, level: Int)?, brightness: Float?, at now: Date) -> Bool {
        let before = state
        if let battery, batteryReadAt.map({ now >= $0 }) ?? true {
            state.isOnBattery = battery.onBattery
            state.batteryLevel = battery.level
            batteryReadAt = now
        }
        if let brightness { state.displayBrightness = brightness }
        return state != before
    }

    func batteryIsStale(now: Date) -> Bool {
        PowerPolling.readIsStale(lastRead: batteryReadAt, now: now)
    }
}

/// Power notifications as signals, not values: each queues one read of the
/// latest snapshot on `Lifecycle.queue` (where lock and unlock read power
/// too), so a notification that waited behind a transition can't apply a
/// sample older than the transition's. Redundant notifications coalesce
/// into the queued read, and a snapshot already applied isn't applied again.
/// `Lifecycle.queue` only.
struct PowerSignal {
    private var queued = false
    private var applied: PowerSnapshot?

    /// A notification arrived. True when the caller must queue a read;
    /// false when one is already queued.
    mutating func notified() -> Bool {
        guard !queued else { return false }
        queued = true
        return true
    }

    /// The queued read runs: the snapshot to apply, or nil when it already is.
    mutating func take(latest: PowerSnapshot) -> PowerSnapshot? {
        queued = false
        guard latest != applied else { return nil }
        applied = latest
        return latest
    }

    /// A transition applied `snapshot` itself.
    mutating func applied(_ snapshot: PowerSnapshot) {
        applied = snapshot
    }
}
