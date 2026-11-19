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
