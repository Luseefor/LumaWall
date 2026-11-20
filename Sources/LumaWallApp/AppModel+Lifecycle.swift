import AppKit
import CoreGraphics
import Darwin
import IOKit.ps
import LumaWallCore
import Observation
import UniformTypeIdentifiers

extension AppModel {
    func bootstrap() async {
        await reload()
        playlists = await playlistStore.all()
        await restorePlaylistPlaybackState()
        automations = await automationStore.current()
        syncSolarLocation()
        displays = displayCoordinator.refresh()
        await engine.restoreOverlay(using: assets)
        refreshActive()
        refreshStats()
        applyPlaybackPolicy()
        // Native side follows after settle, like any other topology event,
        // at login the displays may still be negotiating modes.
        scheduleSettledNativeRestore()
        syncDayNightTimer()
        evaluateAutomations(force: false)
        notePlaylistLoginIfNeeded()
        await refreshEnergyReport()
        if let lockID = automations.lockScreenWallpaperID,
            let asset = assets.first(where: { $0.id == lockID })
        {
            await applyLockScreenWallpaper(asset)
        }
        await consumePendingShortcutIfNeeded()
    }

    func consumePendingShortcutIfNeeded() async {
        guard let pending = UserDefaults.standard.string(forKey: "lumawall.pendingShortcutApply") else { return }
        UserDefaults.standard.removeObject(forKey: "lumawall.pendingShortcutApply")
        let asset: WallpaperAsset?
        if pending == "__featured__" {
            asset = featured
        } else {
            asset =
                assets.first { $0.name.compare(pending, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
                ?? assets.first { $0.name.localizedCaseInsensitiveContains(pending) }
        }
        guard let asset else {
            present(
                "Shortcuts",
                pending == "__featured__"
                    ? "No wallpaper is ready to apply."
                    : "No wallpaper matched \"\(pending)\".")
            return
        }
        stopPlaylistRotation()
        do {
            try await engine.applyToAll(asset)
            try? await store.recordApply(id: asset.id)
            try? await recentsStore.push(asset.id)
            await reload()
        } catch {
            present("Shortcuts", error.localizedDescription)
        }
    }

    func reload() async {
        assets = await store.assets(sortedBy: librarySort)
        recentIDs = await recentsStore.all()
        refreshActive()
        refreshStats()
    }

    func refreshActive() {
        activeByDisplay = Dictionary(
            uniqueKeysWithValues: engine.activeDisplayIDs.compactMap { id in
                guard let wallpaper = engine.wallpaperID(on: id) else { return nil }
                return (id, wallpaper)
            })
        displays = displayCoordinator.displays
    }

    /// A diagnostics view (Settings, menu bar popover) reports whether it is
    /// on screen. Live stats poll only while at least one is.
    func setDiagnosticsViewer(_ id: UUID, visible: Bool) {
        switch diagnosticsVisibility.set(id, visible: visible) {
        case .becameVisible:
            startStatsPolling()
            Task { await refreshEnergyReport() }
        case .becameHidden: stopStatsPolling()
        case nil: break
        }
    }

    private func startStatsPolling() {
        guard statsTimer == nil else { return }
        refreshStats()
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshStats() }
        }
        timer.tolerance = 3
        RunLoop.main.add(timer, forMode: .common)
        statsTimer = timer
    }

    private func stopStatsPolling() {
        statsTimer?.invalidate()
        statsTimer = nil
    }

    /// Refreshes the numbers the diagnostics views show. Does nothing while no
    /// such view is visible; the view's first appearance refreshes again.
    func refreshStats() {
        guard diagnosticsVisibility.isVisible else { return }
        processMemoryMB = Self.residentMemoryMB() ?? processMemoryMB
        let decoders = engine.activeDecoderCount
        if decoders != activeDecoderCount { activeDecoderCount = decoders }
        reduceMotionActive = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let cpu = cpuSampler.sample()
        processCPUPercent = cpu.process
        systemCPUPercent = cpu.system
        // The IOKit callback and applyPlaybackPolicy() track power changes
        // while no view is open; this only catches a change they missed.
        let previousPower = PowerStatus(isOnBattery: isOnBattery, percent: batteryPercent)
        let power = PowerStatus.current()
        batteryPercent = power.percent
        isOnBattery = power.isOnBattery
        if power != previousPower {
            applyPlaybackPolicy()
        }
        // Cached in the store: walks the library only after it changed.
        Task { @MainActor in
            let bytes = await store.diskUsageBytes()
            let megabytes = Double(bytes) / 1_048_576
            if megabytes != libraryDiskMB { libraryDiskMB = megabytes }
        }
    }

    /// One energy sample a minute for the 24 h report, whether or not any
    /// view is open. The store batches them and writes at most every 15 minutes.
    func startEnergyLogging() {
        guard energyTimer == nil else { return }
        // The first sample should cover the first minute, not start its baseline.
        _ = energyCPUSampler.sample()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.recordEnergySample() }
        }
        timer.tolerance = 15
        RunLoop.main.add(timer, forMode: .common)
        energyTimer = timer
    }

    private func recordEnergySample() {
        let cpu = energyCPUSampler.sample()
        let power = PowerStatus.current()
        let sample = EnergySample(
            processCPUPercent: cpu.process,
            systemCPUPercent: cpu.system,
            processMemoryMB: Self.residentMemoryMB() ?? 0,
            batteryPercent: power.percent,
            isOnBattery: power.isOnBattery,
            decoderCount: engine.activeDecoderCount,
            powerProfile: powerProfile.rawValue,
            playbackActive: !playbackStopped && !activeByDisplay.isEmpty
        )
        Task { @MainActor in
            try? await energyLogStore.record(sample)
            if diagnosticsVisibility.isVisible {
                await refreshEnergyReport()
            }
        }
    }

    private static func residentMemoryMB() -> Double? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Double(info.resident_size) / 1_048_576
    }
}
