import CoreGraphics

/// Whether the displays are asleep, read from the displays themselves. The
/// extension otherwise learns of sleep only from `screensDidSleep`, which a
/// process launched during display sleep never receives (#34).
enum DisplaySleep {
    /// Asleep when every online display reports asleep. `screensDidSleep`
    /// means all of them, and the flag gates every renderer, so one lit
    /// display keeps playback on. An empty list says nothing.
    static func allAsleep(_ displays: [Bool]) -> Bool {
        !displays.isEmpty && !displays.contains(false)
    }

    /// Whether the flag missed a sleep that the displays report. Only this
    /// direction is caught up: waking stays with `screensDidWake`, which
    /// follows every real sleep.
    static func missedSleep(flagAsleep: Bool, displays: [Bool]) -> Bool {
        !flagAsleep && allAsleep(displays)
    }

    /// `CGDisplayIsAsleep` for each online display.
    static func onlineDisplays() -> [Bool] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { CGDisplayIsAsleep($0) != 0 }
    }
}

/// The extension's display-sleep flag and the order of its transitions.
/// A catch-up samples the displays off the main queue while sleep and wake
/// notifications land on it; the epoch lets a catch-up sampled before a
/// notification lose to it instead of undoing a wake.
struct SleepGate: Equatable {
    private(set) var asleep = false
    /// Bumped by every notification and catch-up.
    private(set) var epoch = 0

    /// `screensDidSleep` or `screensDidWake`. Returns whether the flag changed.
    mutating func notified(asleep: Bool) -> Bool {
        epoch += 1
        guard self.asleep != asleep else { return false }
        self.asleep = asleep
        return true
    }

    /// Close the gate for displays sampled at `sampledAt`, when they all
    /// sleep, the flag missed it, and no notification landed since.
    mutating func catchUp(sampledAt: Int, displays: [Bool]) -> Bool {
        guard sampledAt == epoch, DisplaySleep.missedSleep(flagAsleep: asleep, displays: displays) else { return false }
        asleep = true
        epoch += 1
        return true
    }
}
