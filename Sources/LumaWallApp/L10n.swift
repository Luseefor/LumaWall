import Foundation

enum L10n {
    static func string(_ key: StaticString, default defaultValue: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: defaultValue)
    }

    static var appName: String { string("app.name", default: "LumaWall") }
    static var home: String { string("nav.home", default: "Home") }
    static var library: String { string("nav.library", default: "Library") }
    static var displays: String { string("nav.displays", default: "Displays") }
    static var settings: String { string("nav.settings", default: "Settings") }
    static var pause: String { string("action.pause", default: "Pause playback") }
    static var resume: String { string("action.resume", default: "Resume playback") }
    static var importVideos: String { string("action.import", default: "Import videos") }
    static var search: String { string("action.search", default: "Search wallpapers") }
    static var settingsSubtitle: String {
        string("settings.subtitle", default: "Energy, lock, and local storage.")
    }
    static var wallpaperHost: String { string("settings.host", default: "Wallpaper host") }
    static var playbackEnergy: String { string("settings.playback", default: "Playback & energy") }
    static var energyLog: String { string("settings.energyLog", default: "Energy Log") }
    static var energyLogDetail: String {
        string(
            "settings.energyLog.detail",
            default: "24-hour log of CPU, RAM, decoders, and battery while wallpapers run."
        )
    }
    static var startSoak: String { string("settings.energyLog.start", default: "Start 24h log") }
    static var copyProof: String { string("settings.energyLog.copy", default: "Copy report") }
    static var resetSoak: String { string("settings.energyLog.reset", default: "Reset window") }
    static var app: String { string("settings.app", default: "App") }
    static var storage: String { string("settings.storage", default: "Storage") }
    static var status: String { string("settings.status", default: "Status") }
    static var launchAtLogin: String { string("settings.launchAtLogin", default: "Launch at login") }
    static var pauseObscured: String {
        string("settings.pauseObscured", default: "Pause when the desktop is hidden")
    }
    static var pauseLock: String {
        string("settings.pauseLock", default: "Pause when the Mac is locked")
    }
    static var stillDesktop: String { string("settings.stillDesktop", default: "Still desktop only") }
    static var reduceMotion: String { string("settings.reduceMotion", default: "Reduce Motion") }
    static var clearRAM: String { string("settings.clearRAM", default: "Clear RAM") }
    static var clearDisk: String { string("settings.clearDisk", default: "Clear disk cache") }
    static var brandHome: String { string("a11y.brand", default: "LumaWall home") }
    static var tagline: String {
        string("tagline", default: "Local video wallpapers. No account. No tracking.")
    }
}
