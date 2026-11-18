import AppKit
import CoreGraphics
import Darwin
import IOKit.ps
import LumaWallCore
import Observation
import UniformTypeIdentifiers

extension AppModel {
    func setDayNightEnabled(_ enabled: Bool) {
        automations.dayNightEnabled = enabled
        if enabled {
            automations.appearanceEnabled = false
            stopPlaylistRotation()
        }
        persistAutomations()
        evaluateAutomations(force: true)
    }

    func setAppearanceEnabled(_ enabled: Bool) {
        automations.appearanceEnabled = enabled
        if enabled {
            automations.dayNightEnabled = false
            stopPlaylistRotation()
        }
        persistAutomations()
        evaluateAutomations(force: true)
    }

    func setDayStartHour(_ hour: Int) {
        automations.dayStartHour = min(max(hour, 0), 23)
        persistAutomations()
        syncDayNightTimer()
        evaluateAutomations(force: true)
    }

    func setNightStartHour(_ hour: Int) {
        automations.nightStartHour = min(max(hour, 0), 23)
        persistAutomations()
        syncDayNightTimer()
        evaluateAutomations(force: true)
    }

    func setUseSunriseSunset(_ enabled: Bool) {
        automations.useSunriseSunset = enabled
        if enabled { LocationDaylightProvider.shared.requestIfNeeded() }
        persistAutomations()
        evaluateAutomations(force: true)
    }

    func setPowerSourceRule(_ rule: PowerSourceRule) {
        automations.powerSourceRule = rule
        persistAutomations()
        evaluateAutomations(force: true)
    }

    func setWeekdayMask(_ mask: UInt8) {
        automations.weekdayMask = mask
        persistAutomations()
        evaluateAutomations(force: true)
    }

    func setDoNotInterrupt(start: Int?, end: Int?) {
        automations.doNotInterruptStartHour = start.map { min(max($0, 0), 23) }
        automations.doNotInterruptEndHour = end.map { min(max($0, 0), 23) }
        persistAutomations()
        evaluateAutomations(force: true)
    }

    func toggleWeekday(_ weekday: Int) {
        guard (0...6).contains(weekday) else { return }
        let bit: UInt8 = 1 << weekday
        if automations.weekdayMask == 0 {
            automations.weekdayMask = 0b0111_1111 ^ bit
        } else {
            automations.weekdayMask ^= bit
            if automations.weekdayMask == 0 || automations.weekdayMask == 0b0111_1111 {
                automations.weekdayMask = 0
            }
        }
        persistAutomations()
        evaluateAutomations(force: true)
    }

    func isWeekdaySelected(_ weekday: Int) -> Bool {
        guard (0...6).contains(weekday) else { return true }
        if automations.weekdayMask == 0 { return true }
        return (automations.weekdayMask & (1 << weekday)) != 0
    }

    func clearWeekdayFilter() {
        automations.weekdayMask = 0
        persistAutomations()
        evaluateAutomations(force: true)
    }

    func assignAutomation(slot: AutomationSlot, asset: WallpaperAsset) {
        switch slot {
        case .day: automations.dayWallpaperID = asset.id
        case .night: automations.nightWallpaperID = asset.id
        case .light: automations.lightWallpaperID = asset.id
        case .dark: automations.darkWallpaperID = asset.id
        case .lock:
            automations.lockScreenWallpaperID = asset.id
            Task { await applyLockScreenWallpaper(asset, announceUnavailable: true) }
        }
        automationPickSlot = nil
        persistAutomations()
        evaluateAutomations(force: true)
    }

    func clearAutomation(slot: AutomationSlot) {
        switch slot {
        case .day: automations.dayWallpaperID = nil
        case .night: automations.nightWallpaperID = nil
        case .light: automations.lightWallpaperID = nil
        case .dark: automations.darkWallpaperID = nil
        case .lock: automations.lockScreenWallpaperID = nil
        }
        persistAutomations()
        evaluateAutomations(force: true)
    }

    func applyLockScreenWallpaper(_ asset: WallpaperAsset, announceUnavailable: Bool = false) async {
        guard engine.mode == .native else {
            if announceUnavailable {
                present("Lock Screen", "Lock-screen assignment needs the macOS 26 wallpaper extension build.")
            }
            return
        }
        do {
            let entry = try await NativeWallpaperDeployment.ensureDeployed(
                asset: asset,
                surfaces: displays.map { .init(pixelSize: $0.pixelSize, tier: .full) }
            )
            try NativeWallpaperAssignmentService.applyLockScreen(entry: entry)
        } catch {
            present("Lock Screen", error.localizedDescription)
        }
    }

    func persistAutomations() {
        Task { try? await automationStore.save(automations) }
        syncDayNightTimer()
    }

    func syncDayNightTimer() {
        dayNightTimer?.invalidate()
        dayNightTimer = nil
        guard automations.dayNightEnabled else { return }
        let now = Date()
        let calendar = Calendar.autoupdatingCurrent
        let coordinate = LocationDaylightProvider.shared.coordinate
        // The timer used to arm only the fixed day/night hours, but the
        // verdict can also flip on solar transitions, quiet-hours end, and
        // weekday re-entry — none of which that covered, so switches landed
        // late, were skipped in quiet hours, or never fired at all.
        guard let fireDate = automations.nextEvaluationDates(
            after: now,
            calendar: calendar,
            latitude: coordinate?.latitude,
            longitude: coordinate?.longitude
        ).first else { return }
        let interval = max(1, fireDate.timeIntervalSince(now))
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.evaluateAutomations(force: false)
                self?.syncDayNightTimer()
            }
        }
        timer.tolerance = min(30, interval * 0.01)
        RunLoop.main.add(timer, forMode: .common)
        dayNightTimer = timer
    }

    func observeAppearanceChanges() {
        appearanceObserver = DistributedNotificationCenter.default.addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                self?.evaluateAutomations(force: false)
            }
        }
    }

    func observeAutomationClockChanges() {
        let center = NotificationCenter.default
        for name in [
            NSNotification.Name.NSSystemClockDidChange,
            NSNotification.Name.NSSystemTimeZoneDidChange,
            NSApplication.didBecomeActiveNotification
        ] {
            automationObservers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in
                        self?.syncDayNightTimer()
                        self?.evaluateAutomations(force: false)
                        await self?.consumePendingShortcutIfNeeded()
                    }
                }
            )
        }
    }

    /// Re-evaluate when the first location fix lands. Solar automations start
    /// on the hour-based fallback (no coordinate yet); without this they sit
    /// there until the next armed boundary instead of switching to true
    /// sunrise/sunset immediately.
    func observeFirstLocationFix() {
        LocationDaylightProvider.shared.onFirstFix = { [weak self] in
            Task { @MainActor in
                self?.syncDayNightTimer()
                self?.evaluateAutomations(force: false)
            }
        }
    }

    func observeReduceMotion() {
        reduceMotionActive = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        reduceMotionObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reduceMotionActive = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                self?.applyPlaybackPolicy()
            }
        }
    }

    func observeScreenChanges() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // didChangeScreenParameters fires in bursts during join/cut/mode
            // probes. Restoring on every fire rewrote Index.plist + killall'd
            // WallpaperAgent repeatedly → visible glitch loop. Debounce.
            Task { @MainActor in self?.scheduleDebouncedDisplayRefresh() }
        }
    }

    /// `power` lets a caller that already sampled IOPS avoid a second read.
    func evaluateAutomations(force: Bool, power: PowerStatus? = nil) {
        guard automations.allowsWeekday() else { return }
        guard !automations.isDoNotInterrupt() else { return }
        guard automations.powerSourceRule.allows(isOnBattery: (power ?? PowerStatus.current()).isOnBattery) else { return }

        let targetID: WallpaperID?
        if automations.dayNightEnabled {
            if automations.useSunriseSunset {
                LocationDaylightProvider.shared.requestIfNeeded()
            }
            let coordinate = LocationDaylightProvider.shared.coordinate
            targetID = automations.isDayPeriod(
                latitude: coordinate?.latitude,
                longitude: coordinate?.longitude
            ) ? automations.dayWallpaperID : automations.nightWallpaperID
        } else if automations.appearanceEnabled {
            targetID = isSystemDarkAppearance() ? automations.darkWallpaperID : automations.lightWallpaperID
        } else {
            return
        }
        guard let targetID, let asset = assets.first(where: { $0.id == targetID }) else { return }
        if !force, lastAutomationWallpaperID == targetID { return }
        lastAutomationWallpaperID = targetID
        stopPlaylistRotation()
        Task {
            do {
                try await engine.applyToAll(asset)
                try? await store.recordApply(id: asset.id)
                try? await recentsStore.push(asset.id)
                await reload()
            } catch {
                present("Automation", error.localizedDescription)
            }
        }
    }

    private func isSystemDarkAppearance() -> Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}
