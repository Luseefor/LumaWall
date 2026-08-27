import Foundation
import LumaWallCore
import Testing

struct PlaylistScheduleTests {
    @Test func preservesFutureDeadline() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let future = now.addingTimeInterval(90)
        let result = try #require(PlaylistSchedule.resume(
            nextAdvanceAt: future, intervalMinutes: 5, cursor: 2, itemCount: 4, now: now
        ))
        #expect(result.cursor == 2)
        #expect(result.nextAdvanceAt == future)
    }

    @Test func catchesUpOverdueRotationWithoutDrift() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let deadline = now.addingTimeInterval(-650)
        let result = try #require(PlaylistSchedule.resume(
            nextAdvanceAt: deadline, intervalMinutes: 5, cursor: 1, itemCount: 4, now: now
        ))
        #expect(result.cursor == 0)
        #expect(result.nextAdvanceAt == deadline.addingTimeInterval(900))
    }

    @Test func rejectsEmptyPlaylist() {
        #expect(PlaylistSchedule.resume(
            nextAdvanceAt: nil, intervalMinutes: 5, cursor: 0, itemCount: 0
        ) == nil)
    }
}
