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

    @Test func missingDeadlineStartsFreshSchedule() throws {
        // First launch / cleared playback state: no saved deadline, so the
        // next advance is one full interval out and the cursor is normalized.
        let now = Date(timeIntervalSince1970: 10_000)
        let result = try #require(PlaylistSchedule.resume(
            nextAdvanceAt: nil, intervalMinutes: 5, cursor: 7, itemCount: 3, now: now
        ))
        #expect(result.cursor == 1)
        #expect(result.nextAdvanceAt == now.addingTimeInterval(300))
    }

    @Test func singleItemStepSkipsApplyWhenAlreadyShown() {
        let a = WallpaperID()
        let step = PlaylistSchedule.step(ids: [a], cursor: 0, delta: 1, shownOnDisplays: [a, a])
        #expect(step.cursor == 0)
        #expect(!step.needsApply)
    }

    @Test func stepAppliesWhenAnyDisplayShowsSomethingElse() {
        let a = WallpaperID(), b = WallpaperID()
        #expect(PlaylistSchedule.step(ids: [a], cursor: 0, delta: 1, shownOnDisplays: [a, b]).needsApply)
        #expect(PlaylistSchedule.step(ids: [a], cursor: 0, delta: 1, shownOnDisplays: []).needsApply)
    }

    @Test func stepAdvancesAndAppliesForMultiItemPlaylist() {
        let a = WallpaperID(), b = WallpaperID()
        let step = PlaylistSchedule.step(ids: [a, b], cursor: 1, delta: 1, shownOnDisplays: [b])
        #expect(step.cursor == 0)
        #expect(step.needsApply)
    }
}
