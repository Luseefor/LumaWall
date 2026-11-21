import AppKit
import CoreGraphics
import Darwin
import IOKit.ps
import LumaWallCore
import Observation
import UniformTypeIdentifiers

extension AppModel {
    /// True while nobody can see the controller's windows even though
    /// occlusion says they're visible: the screen is locked or displays sleep.
    var screenIsHidden: Bool { sessionLocked || displaysAsleep }

    func observeLockAndSleep() {
        // The notifications below only report changes; a launch at the lock
        // screen (login item, relaunch after an update) would otherwise
        // believe the screen is unlocked until the next lock.
        sessionLocked = SessionLock.isLocked
        let distributed = DistributedNotificationCenter.default()
        lockObservers.append(
            distributed.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.sessionLocked = true
                    self?.applyPlaybackPolicy()
                }
            }
        )
        lockObservers.append(
            distributed.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.sessionLocked = false
                    self?.applyPlaybackPolicy()
                }
            }
        )
        let workspace = NSWorkspace.shared.notificationCenter
        lockObservers.append(
            workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.displaysAsleep = true
                    self?.applyPlaybackPolicy()
                }
            }
        )
        lockObservers.append(
            workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.displaysAsleep = false
                    self?.applyPlaybackPolicy()
                    self?.notePlaylistWake()
                }
            }
        )
        lockObservers.append(
            workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.notePlaylistWake() }
            }
        )
    }

    func observeGameMode() {
        gameModeMonitor.onChange = { [weak self] in
            self?.applyPlaybackPolicy()
        }
        gameModeMonitor.start()
    }

    private func notePlaylistWake() {
        guard activePlaylistID != nil, !playlistIDs.isEmpty else { return }
        if let lastPlaylistWakeAdvance, Date().timeIntervalSince(lastPlaylistWakeAdvance) < 30 {
            return
        }
        lastPlaylistWakeAdvance = Date()
        // Advance once on wake so overnight playlists move without waiting for the next timer fire.
        stepPlaylist(1, persist: false)
        if let playlistID = activePlaylistID,
            let playlist = playlists.first(where: { $0.id == playlistID })
        {
            startPlaylistRotation(ids: playlistIDs, intervalMinutes: playlist.intervalMinutes)
        }
    }

    func notePlaylistLoginIfNeeded() {
        guard !didAdvancePlaylistOnLogin else { return }
        didAdvancePlaylistOnLogin = true
        // Login item launches stay accessory and usually never become active for a click.
        guard launchAtLogin, NSApp.activationPolicy() == .accessory || !NSApp.isActive else { return }
        guard activePlaylistID != nil else { return }
        stepPlaylist(1, persist: false)
        if let playlistID = activePlaylistID,
            let playlist = playlists.first(where: { $0.id == playlistID })
        {
            startPlaylistRotation(ids: playlistIDs, intervalMinutes: playlist.intervalMinutes)
        }
    }

    func observePowerChanges() {
        let center = NotificationCenter.default
        for name in [
            ProcessInfo.thermalStateDidChangeNotification,
            Notification.Name.NSProcessInfoPowerStateDidChange,
        ] {
            powerObservers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.applyPlaybackPolicy() }
                }
            )
        }
        observePowerSourceChanges()
    }

    /// Event-driven AC↔battery (and capacity) transitions via IOKit. The
    /// notifications above cover thermal and Low Power Mode, but nothing posts
    /// for unplug/replug, without this, Automatic only noticed the switch at
    /// the next 15s stats tick (or never, if the tick's power comparison was
    /// skipped), which reads as "Automatic does nothing".
    private func observePowerSourceChanges() {
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let model = Unmanaged<AppModel>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in model.handlePowerSourceCallback() }
        }
        guard
            let source = IOPSNotificationCreateRunLoopSource(
                callback,
                Unmanaged.passUnretained(self).toOpaque()
            )?.takeRetainedValue()
        else { return }
        powerSourceRegistration.set(source)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }

    /// Reads power once per callback. Only an AC/battery switch changes what
    /// the window scan and the automation rules depend on; a charge-level tick
    /// just refreshes the battery tiers from the cached coverage.
    func handlePowerSourceCallback() {
        let power = PowerStatus.current()
        switch powerTracker.observe(power) {
        case .none:
            return
        case .percentOnly:
            applyPlaybackPolicy(refreshCoverage: false, power: power)
        case .sourceSwitched:
            applyPlaybackPolicy(power: power)
            // Power-source rules gate automations: apply or lift them now.
            evaluateAutomations(force: false, power: power)
        }
    }

    private var userPausedEverywhere: Bool {
        userPaused || (!displays.isEmpty && displays.allSatisfy { pausedDisplayIDs.contains($0.displayID) })
    }

    func observeDesktopCoverage() {
        // Merges a burst of workspace notifications into one scan. Created here
        // so a notification queued before shutdown() finds it gone and does nothing.
        coverageDebouncer = CoverageDebouncer(delay: .seconds(CoverageScanPolicy.debounce)) { [weak self] in
            self?.applyPlaybackPolicy()
        }
        let center = NSWorkspace.shared.notificationCenter
        let names: [NSNotification.Name] = [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didDeactivateApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification,
        ]
        for name in names {
            coverageObservers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.coverageDebouncer?.signal() }
                }
            )
        }
        // Workspace/Space notifications handle normal transitions. This slow fallback
        // catches apps that resize opaque windows without publishing a workspace event.
        // Resume, unlock, wake and unpause call applyPlaybackPolicy() directly, so
        // skipping the scan here never leaves coverage stale when playback restarts.
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let scan = CoverageScanPolicy.fallbackScanNeeded(
                    userPausedEverywhere: self.userPausedEverywhere,
                    displaysAsleep: self.displaysAsleep,
                    sessionLocked: self.sessionLocked,
                    hasAssignedWallpaper: self.engine.hasActivePlayback
                )
                if scan { self.applyPlaybackPolicy() }
            }
        }
        timer.tolerance = 8
        RunLoop.main.add(timer, forMode: .common)
        coverageTimer = timer
        applyPlaybackPolicy()
    }

    /// `refreshCoverage: false` reuses the latched coverage instead of fetching
    /// the window list again.
    func applyPlaybackPolicy(refreshCoverage: Bool = true, power sampled: PowerStatus? = nil) {
        let power = sampled ?? PowerStatus.current()
        batteryPercent = power.percent
        isOnBattery = power.isOnBattery
        if refreshCoverage {
            powerTracker.noteCoverageScan(onBattery: power.isOnBattery)
            // On battery, a window filling everything below the menu bar counts as
            // covering the display: the compositor shows none of the wallpaper's
            // frames then, so decoding them only drains the battery.
            let coverage = DisplayOcclusion.analyze(
                windows: OnscreenWindow.current(),
                displays: displays,
                ignoringMenuBar: power.isOnBattery
            )
            // Hysteresis: hold the paused verdict until coverage falls back past
            // the release thresholds, so a window sitting at the enter boundary
            // can't strobe pause/resume on every evaluation.
            occlusionLatch.beginScan(onBattery: power.isOnBattery)
            occlusionLatch.prune(to: Set(displays.map(\.displayID)))
            for display in displays {
                occlusionLatch.update(
                    displayID: display.displayID,
                    ratio: coverage.coverage[display.displayID] ?? 0,
                    rawCovered: coverage.covered.contains(display.displayID),
                    rawFullscreen: coverage.fullscreen.contains(display.displayID)
                )
            }
        }
        let coveredDisplays = occlusionLatch.covered
        let fullscreenDisplays = occlusionLatch.fullscreen
        let allowLiveOnLock = engine.mode == .native
        var decisions: [DisplayID: (tier: PlaybackTier, reason: PlaybackStatusReason?)] = [:]
        for display in displays {
            let obscured =
                (pauseWhenObscured && coveredDisplays.contains(display.displayID))
                || fullscreenDisplays.contains(display.displayID)
            let conditions = PlaybackConditions(
                profile: powerProfile,
                isOnBattery: power.isOnBattery,
                batteryPercent: power.percent,
                lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                thermalState: ProcessInfo.processInfo.thermalState,
                displayIsAsleep: displaysAsleep,
                sessionIsLocked: pauseOnLock && sessionLocked,
                displayIsObscured: obscured,
                userPaused: userPaused || pausedDisplayIDs.contains(display.displayID),
                hideDesktopVideo: hideDesktopVideo,
                allowLiveOnLock: allowLiveOnLock,
                gameModeActive: gameModeMonitor.isActive,
                reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            )
            let decision = PlaybackPolicy.decide(conditions)
            decisions[display.displayID] = decision
            engine.apply(tier: decision.tier, to: display.displayID)
        }
        noteOverlayPlaybackStatus(decisions)
        if engine.mode == .native {
            let pausedCG = Set(pausedDisplayIDs.compactMap { id in displays.first(where: { $0.displayID == id })?.cgDisplayID })
            let coveredCG = Set(coveredDisplays.compactMap { id in displays.first(where: { $0.displayID == id })?.cgDisplayID })
            let fullscreenCG = Set(fullscreenDisplays.compactMap { id in displays.first(where: { $0.displayID == id })?.cgDisplayID })
            NativeWallpaperPrefsBridge.write(
                userPaused: userPaused,
                pauseWhenOccluded: pauseWhenObscured,
                alwaysPauseDesktop: hideDesktopVideo,
                pausedDisplays: pausedCG,
                occludedDisplays: coveredCG,
                fullscreenDisplays: fullscreenCG,
                desktopOccluded: coveredDisplays.count == displays.count && !displays.isEmpty,
                screenSaverIsOurs: WallpaperStoreProbe.screenSaverIsOurs(),
                powerProfile: powerProfile.rawValue
            )
        }
        playbackStopped =
            displays.contains { engine.wallpaperID(on: $0.displayID) != nil }
            && displays.allSatisfy { display in
                guard engine.wallpaperID(on: display.displayID) != nil else { return true }
                switch engine.tier(on: display.displayID) {
                case .full, .reduced, .minimal: return false
                default: return true
                }
            }
    }

    func present(_ title: String, _ message: String) {
        // Messages name files and folders; only the title is public.
        nativeHostLog.error("alert: \(title, privacy: .public), \(message, privacy: .private)")
        let alert = AppAlert(title: title, message: message)
        if activeAlert == nil {
            activeAlert = alert
        } else {
            alertQueue.append(alert)
        }
    }

    /// Dismiss the active alert and show the next queued one, if any.
    func acknowledgeAlert() {
        activeAlert = alertQueue.isEmpty ? nil : alertQueue.removeFirst()
    }
}
