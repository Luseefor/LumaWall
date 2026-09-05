import Foundation

public enum PowerSourceRule: String, Codable, CaseIterable, Sendable, Identifiable {
    case any
    case batteryOnly
    case acOnly

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .any: "Any power source"
        case .batteryOnly: "Battery only"
        case .acOnly: "Power adapter only"
        }
    }

    public func allows(isOnBattery: Bool) -> Bool {
        switch self {
        case .any: true
        case .batteryOnly: isOnBattery
        case .acOnly: !isOnBattery
        }
    }
}

public struct WallpaperAutomations: Codable, Equatable, Sendable {
    public var dayNightEnabled: Bool
    public var dayWallpaperID: WallpaperID?
    public var nightWallpaperID: WallpaperID?
    public var dayStartHour: Int
    public var nightStartHour: Int
    public var useSunriseSunset: Bool

    public var appearanceEnabled: Bool
    public var lightWallpaperID: WallpaperID?
    public var darkWallpaperID: WallpaperID?

    /// Bitmask Sunday=1<<0 … Saturday=1<<6. Zero means every day.
    public var weekdayMask: UInt8
    public var doNotInterruptStartHour: Int?
    public var doNotInterruptEndHour: Int?
    public var powerSourceRule: PowerSourceRule

    /// Optional lock-screen / Idle wallpaper when the native host is active.
    public var lockScreenWallpaperID: WallpaperID?

    public init(
        dayNightEnabled: Bool = false,
        dayWallpaperID: WallpaperID? = nil,
        nightWallpaperID: WallpaperID? = nil,
        dayStartHour: Int = 6,
        nightStartHour: Int = 18,
        useSunriseSunset: Bool = false,
        appearanceEnabled: Bool = false,
        lightWallpaperID: WallpaperID? = nil,
        darkWallpaperID: WallpaperID? = nil,
        weekdayMask: UInt8 = 0,
        doNotInterruptStartHour: Int? = nil,
        doNotInterruptEndHour: Int? = nil,
        powerSourceRule: PowerSourceRule = .any,
        lockScreenWallpaperID: WallpaperID? = nil
    ) {
        self.dayNightEnabled = dayNightEnabled
        self.dayWallpaperID = dayWallpaperID
        self.nightWallpaperID = nightWallpaperID
        self.dayStartHour = dayStartHour
        self.nightStartHour = nightStartHour
        self.useSunriseSunset = useSunriseSunset
        self.appearanceEnabled = appearanceEnabled
        self.lightWallpaperID = lightWallpaperID
        self.darkWallpaperID = darkWallpaperID
        self.weekdayMask = weekdayMask
        self.doNotInterruptStartHour = doNotInterruptStartHour
        self.doNotInterruptEndHour = doNotInterruptEndHour
        self.powerSourceRule = powerSourceRule
        self.lockScreenWallpaperID = lockScreenWallpaperID
    }

    public func isDayPeriod(
        at date: Date = .now,
        calendar: Calendar = .current,
        latitude: Double? = nil,
        longitude: Double? = nil
    ) -> Bool {
        if useSunriseSunset, let latitude, let longitude {
            return SolarSchedule.isDaylight(at: date, latitude: latitude, longitude: longitude, calendar: calendar)
        }
        let hour = calendar.component(.hour, from: date)
        if dayStartHour == nightStartHour { return true }
        return Self.coversHour(hour, start: dayStartHour, end: nightStartHour)
    }

    public func allowsWeekday(at date: Date = .now, calendar: Calendar = .current) -> Bool {
        guard weekdayMask != 0 else { return true }
        let weekday = calendar.component(.weekday, from: date) - 1 // 0=Sunday
        return (weekdayMask & (1 << weekday)) != 0
    }

    public func isDoNotInterrupt(at date: Date = .now, calendar: Calendar = .current) -> Bool {
        guard let start = doNotInterruptStartHour, let end = doNotInterruptEndHour else { return false }
        let hour = calendar.component(.hour, from: date)
        if start == end { return true }
        return Self.coversHour(hour, start: start, end: end)
    }

    /// Half-open hour window `[start, end)`, wrapping past midnight when
    /// `start > end`. Shared by the day/night and quiet-hours checks so the
    /// overnight logic cannot drift between the two.
    private static func coversHour(_ hour: Int, start: Int, end: Int) -> Bool {
        if start < end { return hour >= start && hour < end }
        return hour >= start || hour < end
    }
}

public actor AutomationStore {
    private let fileURL: URL
    private var value = WallpaperAutomations()

    public init(rootURL: URL? = nil) throws {
        let base = try StorePaths.appSupportBase(rootURL: rootURL)
        self.fileURL = base.appendingPathComponent("Automations.json")
        if let decoded: WallpaperAutomations = StoreIO.readJSON(from: fileURL, as: WallpaperAutomations.self) {
            value = decoded
        }
    }

    public func current() -> WallpaperAutomations { value }

    public func save(_ automations: WallpaperAutomations) throws {
        value = automations
        try StoreIO.writeJSON(value, to: fileURL)
    }
}
