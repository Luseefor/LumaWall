import Foundation
import LumaWallCore

/// Native wallpaper mode: the opt-in setting, its warning, automatic
/// fallback notices and restoring the user's original wallpaper.
extension AppModel {
    enum NativeModeText {
        static let title = "Native wallpaper mode (experimental)"
        static let warning =
            "Native mode edits the macOS wallpaper settings file and uses macOS interfaces Apple doesn't document. "
            + "A macOS update can break it. If it stops working on a display, LumaWall switches that display "
            + "back to the overlay on its own. Use it at your own risk."
    }

    var nativeModeEnabled: Bool { engine.nativeModeEnabled }
    var needsNativeModeDisclosure: Bool { engine.needsNativeModeDisclosure }
    var nativeFallbackDisplayCount: Int { engine.nativeFallbackDisplayIDs.count }

    /// Restore needs a backup, and native mode off so the next restore
    /// doesn't put LumaWall straight back.
    var canRestoreOriginalWallpaper: Bool {
        !nativeModeEnabled && NativeWallpaperAssignmentService.hasBackup
    }

    /// Call with `true` only after the user confirmed the warning.
    func setNativeMode(enabled: Bool) {
        isApplying = true
        Task {
            await engine.setNativeMode(enabled: enabled, library: assets)
            refreshActive()
            applyPlaybackPolicy()
            isApplying = false
            // A Lock Screen pick saved while native mode was off goes on now.
            if engine.mode == .native, let lockID = automations.lockScreenWallpaperID,
                let asset = assets.first(where: { $0.id == lockID })
            {
                await applyLockScreenWallpaper(asset)
            }
        }
    }

    /// The one-time warning for someone who already used native mode.
    func answerNativeModeDisclosure(keepNativeMode: Bool) {
        engine.acknowledgeNativeModeDisclosure()
        if !keepNativeMode { setNativeMode(enabled: false) }
    }

    func restoreOriginalWallpaper() {
        do {
            let result = try NativeWallpaperAssignmentService.restoreOriginalWallpaper()
            present("Restore original wallpaper", Self.restoreMessage(result))
        } catch {
            present("Restore original wallpaper", error.localizedDescription)
        }
    }

    static func restoreMessage(_ result: NativeWallpaperAssignmentService.RestoreResult) -> String {
        switch (result.restored, result.missing) {
        case (0, 0): "Your wallpaper isn't set by LumaWall, so there was nothing to restore."
        case (0, _): "LumaWall has no saved wallpaper to put back. Choose one in System Settings → Wallpaper."
        case (_, 0): "Your previous wallpaper is back."
        default:
            "Your previous wallpaper is back where LumaWall had a saved copy. "
                + "Choose the rest in System Settings → Wallpaper."
        }
    }

    func observeNativeFallback() {
        engine.onNativeFallback = { [weak self] fallback in
            self?.presentNativeFallback(fallback)
        }
    }

    private func presentNativeFallback(_ fallback: WallpaperEngine.NativeFallback) {
        let names = displays.filter { fallback.displayIDs.contains($0.displayID) }.map(\.name)
        let target = names.isEmpty ? "a display" : names.joined(separator: ", ")
        var message = "Native mode stopped working on \(target). LumaWall switched it to the overlay."
        if let detail = fallback.error?.localizedDescription { message += " \(detail)" }
        present("Native mode", message)
    }
}
