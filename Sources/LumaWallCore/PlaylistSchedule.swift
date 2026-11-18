import Foundation

public struct PlaylistScheduleResult: Equatable, Sendable {
    public let cursor: Int
    public let nextAdvanceAt: Date
}

public struct PlaylistStepResult: Equatable, Sendable {
    public let cursor: Int
    /// False when the target wallpaper is already on every display.
    public let needsApply: Bool
}

public enum PlaylistSchedule {
    /// Moves the cursor by `delta`. Skips the apply when every display already
    /// shows the target (a nil entry is a display with no wallpaper), so a
    /// one-item playlist doesn't rewrite the system wallpaper store on each tick.
    public static func step(
        ids: [WallpaperID],
        cursor: Int,
        delta: Int,
        shownOnDisplays: [WallpaperID?]
    ) -> PlaylistStepResult {
        guard !ids.isEmpty else { return .init(cursor: 0, needsApply: false) }
        let next = normalized(cursor + delta, count: ids.count)
        let target = ids[next]
        let satisfied = !shownOnDisplays.isEmpty && shownOnDisplays.allSatisfy { $0 == target }
        return .init(cursor: next, needsApply: !satisfied)
    }

    public static func resume(
        nextAdvanceAt: Date?,
        intervalMinutes: Int,
        cursor: Int,
        itemCount: Int,
        now: Date = .now
    ) -> PlaylistScheduleResult? {
        guard itemCount > 0 else { return nil }
        let interval = TimeInterval(max(1, intervalMinutes) * 60)
        guard let nextAdvanceAt else {
            return .init(cursor: normalized(cursor, count: itemCount), nextAdvanceAt: now.addingTimeInterval(interval))
        }
        guard nextAdvanceAt <= now else {
            return .init(cursor: normalized(cursor, count: itemCount), nextAdvanceAt: nextAdvanceAt)
        }
        let missed = Int(floor(now.timeIntervalSince(nextAdvanceAt) / interval)) + 1
        return .init(
            cursor: normalized(cursor + missed, count: itemCount),
            nextAdvanceAt: nextAdvanceAt.addingTimeInterval(Double(missed) * interval)
        )
    }

    private static func normalized(_ cursor: Int, count: Int) -> Int {
        ((cursor % count) + count) % count
    }
}
