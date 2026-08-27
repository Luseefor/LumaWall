import AppKit
import Foundation

struct ExtensionAutomationConfiguration: Codable, Sendable {
    var dayVideoID: String?
    var nightVideoID: String?
    var lightVideoID: String?
    var darkVideoID: String?
    var dayStartMinutes: Int
    var nightStartMinutes: Int
}

enum ExtensionAutomationLibrary {
    static let dayNightChoiceID = "automation:day-night"
    static let appearanceChoiceID = "automation:appearance"

    private static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/lumawall-automations.json")
    }

    static func load() -> ExtensionAutomationConfiguration? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(ExtensionAutomationConfiguration.self, from: data)
    }

    static func isAutomationChoice(_ id: String?) -> Bool {
        id == dayNightChoiceID || id == appearanceChoiceID
    }

    static func isConfigured(_ choiceID: String, configuration: ExtensionAutomationConfiguration? = load()) -> Bool {
        guard let configuration else { return false }
        let available = Set(VideoLibrary.shared.entries.map(\.id))
        switch choiceID {
        case dayNightChoiceID:
            return configuration.dayVideoID.map(available.contains) == true
                && configuration.nightVideoID.map(available.contains) == true
        case appearanceChoiceID:
            return configuration.lightVideoID.map(available.contains) == true
                && configuration.darkVideoID.map(available.contains) == true
        default:
            return false
        }
    }

    static func memberIDs(for choiceID: String, configuration: ExtensionAutomationConfiguration? = load()) -> [String] {
        guard let configuration else { return [] }
        let ids: [String?]
        switch choiceID {
        case dayNightChoiceID: ids = [configuration.dayVideoID, configuration.nightVideoID]
        case appearanceChoiceID: ids = [configuration.lightVideoID, configuration.darkVideoID]
        default: ids = []
        }
        let available = Set(VideoLibrary.shared.entries.map(\.id))
        return ids.compactMap { $0 }.filter(available.contains)
    }

    static func resolve(_ choiceID: String, at date: Date = Date()) -> String? {
        guard let configuration = load() else { return nil }
        switch choiceID {
        case dayNightChoiceID:
            let components = Calendar.current.dateComponents([.hour, .minute], from: date)
            let minute = (components.hour ?? 0) * 60 + (components.minute ?? 0)
            let dayStart = min(max(configuration.dayStartMinutes, 0), 1439)
            let nightStart = min(max(configuration.nightStartMinutes, 0), 1439)
            let isDay: Bool
            if dayStart <= nightStart {
                isDay = minute >= dayStart && minute < nightStart
            } else {
                isDay = minute >= dayStart || minute < nightStart
            }
            return isDay ? configuration.dayVideoID : configuration.nightVideoID
        case appearanceChoiceID:
            let isDark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
            return isDark ? configuration.darkVideoID : configuration.lightVideoID
        default:
            return choiceID
        }
    }
}

/// Keeps native time/appearance choices alive inside the wallpaper extension. The
/// companion window can be closed; only the selected wallpaper surface does work.
final class AutomationController: NSObject, @unchecked Sendable {
    static let shared = AutomationController()

    private let queue = DispatchQueue(label: "app.lumawall.personal.automation")
    private var boundaryTimer: (any DispatchSourceTimer)?

    private override init() {
        super.init()
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(appearanceChanged),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(dayChanged),
            name: NSWorkspace.didWakeNotification,
            object: nil,
        )
    }

    func resolveChoice(_ choice: String?) -> String? {
        guard let choice, ExtensionAutomationLibrary.isAutomationChoice(choice) else { return choice }
        return ExtensionAutomationLibrary.resolve(choice)
    }

    func noteAcquire(choice: String?) {
        guard let choice, ExtensionAutomationLibrary.isAutomationChoice(choice) else { return }
        if choice == ExtensionAutomationLibrary.dayNightChoiceID {
            armBoundaryTimer()
        }
    }

    @objc private func appearanceChanged() {
        queue.async { [self] in refresh(choiceID: ExtensionAutomationLibrary.appearanceChoiceID, reason: "appearance") }
    }

    @objc private func dayChanged() {
        queue.async { [self] in
            refresh(choiceID: ExtensionAutomationLibrary.dayNightChoiceID, reason: "wake")
            armBoundaryTimerOnQueue()
        }
    }

    private func armBoundaryTimer() {
        queue.async { [self] in armBoundaryTimerOnQueue() }
    }

    private func armBoundaryTimerOnQueue() {
        boundaryTimer?.cancel()
        guard WallpaperState.shared.hasContext(forVideoID: ExtensionAutomationLibrary.dayNightChoiceID),
              let configuration = ExtensionAutomationLibrary.load()
        else { boundaryTimer = nil; return }

        let now = Date()
        let next = [configuration.dayStartMinutes, configuration.nightStartMinutes]
            .compactMap { nextOccurrence(minutes: $0, after: now) }
            .min() ?? now.addingTimeInterval(60 * 60)
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + max(1, next.timeIntervalSince(now)), leeway: .seconds(2))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.refresh(choiceID: ExtensionAutomationLibrary.dayNightChoiceID, reason: "time boundary")
            self.armBoundaryTimerOnQueue()
        }
        boundaryTimer = source
        source.resume()
    }

    private func nextOccurrence(minutes: Int, after date: Date) -> Date? {
        let safe = min(max(minutes, 0), 1439)
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        guard let today = calendar.date(byAdding: .minute, value: safe, to: start) else { return nil }
        if today > date { return today }
        return calendar.date(byAdding: .day, value: 1, to: today)
    }

    private func refresh(choiceID: String, reason: String) {
        guard let videoID = ExtensionAutomationLibrary.resolve(choiceID),
              let url = VideoLibrary.shared.videoURL(for: videoID)
        else { return }
        let renderers = WallpaperState.shared.renderers(forVideoID: choiceID)
        for renderer in renderers {
            renderer.variantSelector = makeVariantSelector(choice: videoID, fallback: url)
            renderer.switchVideo(to: url)
        }
        guard !renderers.isEmpty else { return }
        LumaWallExtension.recomputeAndApplyPolicy()
        WallpaperState.shared.currentVideoID = videoID
        WallpaperPrefs.shared.updateCurrentVideo()
        extensionLog("[Automation] switched \(choiceID) to \(videoID) on \(renderers.count) renderer(s) (\(reason))")
    }
}
