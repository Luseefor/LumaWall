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
            + "back to Safe mode on its own and tells you. Use it at your own risk."
    }

    var nativeModeEnabled: Bool { engine.nativeModeEnabled }
    var needsNativeModeDisclosure: Bool { engine.needsNativeModeDisclosure }
    var nativeFallbackDisplayCount: Int { engine.nativeFallbackDisplayIDs.count }

    /// Restore needs a backup. With native mode on it is turned off first,
    /// so the next restore doesn't put LumaWall straight back.
    var canRestoreOriginalWallpaper: Bool {
        NativeWallpaperAssignmentService.hasBackup
    }

    /// Call with `true` only after the user confirmed the warning.
    func setNativeMode(enabled: Bool) {
        Task { await switchNativeMode(enabled: enabled) }
    }

    private func switchNativeMode(enabled: Bool) async {
        isApplying = true
        nativeFailureNotice = nil
        await engine.setNativeMode(enabled: enabled, library: assets)
        refreshActive()
        applyPlaybackPolicy()
        isApplying = false
        syncNativeHealth()
        askForNotificationPermissionIfNeeded()
        // A Lock Screen pick saved while native mode was off goes on now.
        if engine.mode == .native, let lockID = automations.lockScreenWallpaperID,
            let asset = assets.first(where: { $0.id == lockID })
        {
            await applyLockScreenWallpaper(asset)
        }
    }

    /// Saves the layout and, in native mode, rewrites the store for it.
    /// With native mode off it is only saved: Safe mode writes nothing.
    func setNativeSurfaceLayout(_ layout: NativeSurfaceLayout) {
        guard layout != nativeSurfaceLayout else { return }
        nativeSurfaceLayout = layout
        layout.save()
        syncNativeHealth()
        if engine.mode == .native { engine.reapplyAssignments() }
    }

    /// The one-time warning for someone who already used native mode.
    func answerNativeModeDisclosure(keepNativeMode: Bool) {
        engine.acknowledgeNativeModeDisclosure()
        if keepNativeMode { askForNotificationPermissionIfNeeded() } else { setNativeMode(enabled: false) }
    }

    /// The failure notice needs permission. Asked while native mode is the
    /// host and its warning is answered, never during a failure: those
    /// come after an unlock or wake, when macOS refused the prompt.
    private func askForNotificationPermissionIfNeeded() {
        nativeFailureNotifier.askForPermissionIfNeeded { [weak self] in
            guard let self else { return false }
            return self.engine.mode == .native && !self.needsNativeModeDisclosure
        }
    }

    /// Turns native mode off if it is on, stops LumaWall's wallpapers so
    /// nothing covers the desktop, then puts back the user's own wallpaper
    /// from the backup.
    func restoreOriginalWallpaper() {
        Task {
            let wasNative = nativeModeEnabled
            if wasNative { await switchNativeMode(enabled: false) }
            nativeFailureNotice = nil
            // Safe mode's windows would cover the restored wallpaper.
            if activePlaylistID != nil { stopPlaylistRotation() }
            try? await engine.clearAll()
            refreshActive()
            applyPlaybackPolicy()
            do {
                let result = try NativeWallpaperAssignmentService.restoreOriginalWallpaper()
                var message = Self.restoreMessage(result)
                message += wasNative ? " Native mode is off now, and " : " "
                message += "LumaWall stopped playing. Pick a wallpaper in the Library to start again."
                present("Restore original wallpaper", message)
            } catch {
                present("Restore original wallpaper", error.localizedDescription)
            }
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
        nativeFailureNotifier.onRestore = { [weak self] in self?.restoreOriginalWallpaper() }
        nativeFailureNotifier.onOpen = { [weak self] in self?.section = .settings }
        nativeFailureNotifier.start()
        askForNotificationPermissionIfNeeded()
        nativeHealth = NativeHealthMonitor(
            watchedDisplays: { [weak self] in
                guard let self else { return [:] }
                let served = self.engine.nativeServedDisplayIDs
                return Dictionary(
                    self.displays.filter { served.contains($0.displayID) }.map { ($0.cgDisplayID, $0.displayID) },
                    uniquingKeysWith: { first, _ in first })
            },
            session: { [weak self] in
                .init(sessionLocked: self?.sessionLocked ?? true, displaysAsleep: self?.displaysAsleep ?? true)
            },
            onUnserved: { [weak self] ids in
                guard let self else { return }
                let writes = LiveSystemWallpaperFiles.storeChangeCount
                let disturbances = self.nativeHealth?.disturbances
                Task {
                    // A store write or another disturbance since the verdict:
                    // the next probes decide after their grace.
                    guard LiveSystemWallpaperFiles.storeChangeCount == writes,
                        self.nativeHealth?.disturbances == disturbances
                    else { return }
                    await self.engine.fallBackUnserved(ids)
                    self.refreshActive()
                    self.applyPlaybackPolicy()
                }
            }
        )
        syncNativeHealth()
    }

    /// The extension health check runs while native mode is the host and
    /// plays on the desktop: it can only check while the screen is unlocked.
    func syncNativeHealth() {
        nativeHealth?.setRunning(engine.mode == .native && nativeSurfaceLayout.playsOnDesktop)
    }

    /// Told once per display each time native mode fails there: the engine
    /// reports a display again only after native mode is turned off and on.
    private func presentNativeFallback(_ fallback: WallpaperEngine.NativeFallback) {
        let names = displays.filter { fallback.displayIDs.contains($0.displayID) }.map(\.name)
        let failed = names.isEmpty ? ["a display"] : names
        if let detail = fallback.error?.localizedDescription {
            nativeHostLog.error("native fallback: \(detail, privacy: .private)")
        }
        nativeFailureNotice = NativeFailureNotice(displayNames: (nativeFailureNotice?.displayNames ?? []) + failed)
        nativeFailureNotifier.post(title: NativeFailureNotice.title(for: failed), body: NativeFailureNotice.message(for: failed))
    }

    func dismissNativeFailureNotice() {
        nativeFailureNotice = nil
    }
}

/// What the in-app banner says after native mode failed on some displays.
struct NativeFailureNotice: Equatable {
    var displayNames: [String]

    var title: String { Self.title(for: displayNames) }
    var message: String { Self.message(for: displayNames) }

    static func title(for names: [String]) -> String {
        "Native mode stopped working on \(list(names))"
    }

    static func message(for names: [String]) -> String {
        let moved =
            names.count == 1
            ? "It moved to Safe mode, where its wallpaper keeps playing."
            : "They moved to Safe mode, where their wallpapers keep playing."
        return moved + " To go back to your own wallpaper, choose Restore Original Wallpaper."
    }

    private static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: "a display"
        case 1: names[0]
        case 2: "\(names[0]) and \(names[1])"
        default: names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
    }
}
