import Foundation

public struct PlaylistScheduleResult: Equatable, Sendable {
    public let cursor: Int
    public let nextAdvanceAt: Date
}

public enum PlaylistSchedule {
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
