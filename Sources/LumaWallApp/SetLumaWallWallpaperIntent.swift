import AppIntents
import Foundation
import LumaWallCore

struct SetLumaWallWallpaperIntent: AppIntent {
    static let title: LocalizedStringResource = "Set LumaWall Wallpaper"
    static let description = IntentDescription("Applies a local LumaWall library video to the desktop.")
    static let openAppWhenRun: Bool = true

    @Parameter(title: "Wallpaper Name")
    var wallpaperName: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Set \(\.$wallpaperName) with LumaWall")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let name = wallpaperName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let name, !name.isEmpty {
            UserDefaults.standard.set(name, forKey: "lumawall.pendingShortcutApply")
            return .result(dialog: "Applying “\(name)” in LumaWall.")
        }
        UserDefaults.standard.set("__featured__", forKey: "lumawall.pendingShortcutApply")
        return .result(dialog: "Applying the current LumaWall wallpaper.")
    }
}

struct LumaWallShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SetLumaWallWallpaperIntent(),
            phrases: [
                "Set wallpaper with \(.applicationName)",
                "Apply \(.applicationName) wallpaper"
            ],
            shortTitle: "Set Wallpaper",
            systemImageName: "rectangle.on.rectangle.angled"
        )
    }
}
