import Foundation

public struct WallpaperAutomations: Codable, Equatable, Sendable {
    public var dayNightEnabled: Bool
    public var dayWallpaperID: WallpaperID?
    public var nightWallpaperID: WallpaperID?
    public var dayStartHour: Int
    public var nightStartHour: Int

    public var appearanceEnabled: Bool
    public var lightWallpaperID: WallpaperID?
    public var darkWallpaperID: WallpaperID?

    public init(
        dayNightEnabled: Bool = false,
        dayWallpaperID: WallpaperID? = nil,
        nightWallpaperID: WallpaperID? = nil,
        dayStartHour: Int = 6,
        nightStartHour: Int = 18,
        appearanceEnabled: Bool = false,
        lightWallpaperID: WallpaperID? = nil,
        darkWallpaperID: WallpaperID? = nil
    ) {
        self.dayNightEnabled = dayNightEnabled
        self.dayWallpaperID = dayWallpaperID
        self.nightWallpaperID = nightWallpaperID
        self.dayStartHour = dayStartHour
        self.nightStartHour = nightStartHour
        self.appearanceEnabled = appearanceEnabled
        self.lightWallpaperID = lightWallpaperID
        self.darkWallpaperID = darkWallpaperID
    }

    public func isDayPeriod(at date: Date = .now, calendar: Calendar = .current) -> Bool {
        let hour = calendar.component(.hour, from: date)
        if dayStartHour == nightStartHour { return true }
        if dayStartHour < nightStartHour {
            return hour >= dayStartHour && hour < nightStartHour
        }
        return hour >= dayStartHour || hour < nightStartHour
    }
}

public actor AutomationStore {
    private let fileURL: URL
    private var value = WallpaperAutomations()

    public init(rootURL: URL? = nil) throws {
        let base = rootURL ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("LumaWall", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.fileURL = base.appendingPathComponent("Automations.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder.lumaWall.decode(WallpaperAutomations.self, from: data) {
            value = decoded
        }
    }

    public func current() -> WallpaperAutomations { value }

    public func save(_ automations: WallpaperAutomations) throws {
        value = automations
        let data = try JSONEncoder.lumaWall.encode(value)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUnlessOpen])
    }
}
