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

    @Test func weekdayMaskAllowsSelectedDaysOnly() throws {
        let monday = try #require(calendar.date(from: DateComponents(year: 2026, month: 1, day: 5)))
        let sunday = try #require(calendar.date(from: DateComponents(year: 2026, month: 1, day: 4)))
        let weekdaysOnly = WallpaperAutomations(weekdayMask: 0b0111110) // Mon–Fri
        #expect(weekdaysOnly.allowsWeekday(at: monday, calendar: calendar))
        #expect(!weekdaysOnly.allowsWeekday(at: sunday, calendar: calendar))
        #expect(WallpaperAutomations().allowsWeekday(at: sunday, calendar: calendar))
    }

    @Test func doNotInterruptCoversOvernightWindow() throws {
        let midday = try #require(calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 12)))
        let late = try #require(calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 23)))
        let dni = WallpaperAutomations(doNotInterruptStartHour: 22, doNotInterruptEndHour: 6)
        #expect(dni.isDoNotInterrupt(at: late, calendar: calendar))
        #expect(!dni.isDoNotInterrupt(at: midday, calendar: calendar))
    }

    @Test func powerSourceRuleGatesBatteryOnly() {
        #expect(PowerSourceRule.batteryOnly.allows(isOnBattery: true))
        #expect(!PowerSourceRule.batteryOnly.allows(isOnBattery: false))
        #expect(PowerSourceRule.acOnly.allows(isOnBattery: false))
        #expect(!PowerSourceRule.acOnly.allows(isOnBattery: true))
    }

    @Test func sunriseUsesSolarDayBoundaryNearEquator() throws {
        let noon = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 20, hour: 12)))
        let midnight = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 20, hour: 0)))
        let solar = WallpaperAutomations(dayStartHour: 6, nightStartHour: 18, useSunriseSunset: true)
        #expect(solar.isDayPeriod(at: noon, calendar: calendar, latitude: 0, longitude: 0))
        #expect(!solar.isDayPeriod(at: midnight, calendar: calendar, latitude: 0, longitude: 0))
    }
}
