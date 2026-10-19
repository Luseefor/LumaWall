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
        #expect(PowerSourceRule.any.allows(isOnBattery: true))
        #expect(PowerSourceRule.any.allows(isOnBattery: false))
        let titles = PowerSourceRule.allCases.map(\.title)
        #expect(Set(titles).count == titles.count)
        #expect(PowerSourceRule.any.id == "any")
    }

    @Test func sunriseUsesSolarDayBoundaryNearEquator() throws {
        let noon = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 20, hour: 12)))
        let midnight = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 20, hour: 0)))
        let solar = WallpaperAutomations(dayStartHour: 6, nightStartHour: 18, useSunriseSunset: true)
        #expect(solar.isDayPeriod(at: noon, calendar: calendar, latitude: 0, longitude: 0))
        #expect(!solar.isDayPeriod(at: midnight, calendar: calendar, latitude: 0, longitude: 0))
    }

    @Test func nextTransitionFindsSunsetThenSunrise() throws {
        // Equinox at the equator: sunrise ~06:00, sunset ~18:00 UTC.
        let noon = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 20, hour: 12)))
        let evening = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 20, hour: 20)))
        let sunset = try #require(SolarSchedule.nextTransition(after: noon, latitude: 0, longitude: 0, calendar: calendar))
        #expect(calendar.component(.day, from: sunset) == 20)
        #expect((17...19).contains(calendar.component(.hour, from: sunset)))
        let sunrise = try #require(SolarSchedule.nextTransition(after: evening, latitude: 0, longitude: 0, calendar: calendar))
        #expect(calendar.component(.day, from: sunrise) == 21)
        #expect((5...7).contains(calendar.component(.hour, from: sunrise)))
    }

    @Test func evaluationArmsQuietEndAndMidnight() throws {
        // Monday noon, day 6–18, quiet 22–7: the next boundary is 18:00, but
        // the schedule must also arm quiet end (07:00) and midnight — the old
        // timer armed only the fixed hours, so a boundary skipped in quiet
        // hours never applied and weekends never re-entered.
        let mondayNoon = try #require(calendar.date(from: DateComponents(year: 2026, month: 1, day: 5, hour: 12)))
        let automations = WallpaperAutomations(
            dayStartHour: 6,
            nightStartHour: 18,
            weekdayMask: 0b0111110,
            doNotInterruptStartHour: 22,
            doNotInterruptEndHour: 7
        )
        let dates = automations.nextEvaluationDates(after: mondayNoon, calendar: calendar)
        let first = try #require(dates.first)
        #expect(calendar.component(.day, from: first) == 5)
        #expect(calendar.component(.hour, from: first) == 18)
        #expect(dates.contains { calendar.component(.day, from: $0) == 6 && calendar.component(.hour, from: $0) == 0 })
        #expect(dates.contains { calendar.component(.day, from: $0) == 6 && calendar.component(.hour, from: $0) == 7 })
    }

    @Test func evaluationArmsSolarInsteadOfFixedHours() throws {
        // High latitude in winter: sunset (~15:30) lands well before the fixed
        // 18:00 boundary. The old timer fired at 18:00 while the verdict had
        // already flipped hours earlier — and vice versa at sunrise.
        let januaryNoon = try #require(calendar.date(from: DateComponents(year: 2026, month: 1, day: 5, hour: 12)))
        let solar = WallpaperAutomations(dayStartHour: 6, nightStartHour: 18, useSunriseSunset: true)
        let dates = solar.nextEvaluationDates(
            after: januaryNoon, calendar: calendar, latitude: 60, longitude: 0
        )
        let first = try #require(dates.first)
        #expect(calendar.component(.day, from: first) == 5)
        #expect((14...16).contains(calendar.component(.hour, from: first)))
    }
}
