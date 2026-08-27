import Foundation
import LumaWallCore
import Testing

struct AutomationStoreTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    @Test func handlesNormalAndOvernightDayWindows() throws {
        let morning = try #require(calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 8)))
        let evening = try #require(calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 20)))
        #expect(WallpaperAutomations(dayStartHour: 6, nightStartHour: 18).isDayPeriod(at: morning, calendar: calendar))
        #expect(!WallpaperAutomations(dayStartHour: 6, nightStartHour: 18).isDayPeriod(at: evening, calendar: calendar))
        #expect(WallpaperAutomations(dayStartHour: 18, nightStartHour: 6).isDayPeriod(at: evening, calendar: calendar))
        #expect(!WallpaperAutomations(dayStartHour: 18, nightStartHour: 6).isDayPeriod(at: morning, calendar: calendar))
    }

    @Test func persistsCustomSchedule() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let day = WallpaperID()
        let night = WallpaperID()
        let value = WallpaperAutomations(
            dayNightEnabled: true,
            dayWallpaperID: day,
            nightWallpaperID: night,
            dayStartHour: 7,
            nightStartHour: 21
        )
        let store = try AutomationStore(rootURL: root)
        try await store.save(value)
        let restored = try AutomationStore(rootURL: root)
        #expect(await restored.current() == value)
    }
}
