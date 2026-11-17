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
        if automations.useSunriseSunset {
            LocationDaylightProvider.shared.requestIfNeeded()
        }
        if let lockID = automations.lockScreenWallpaperID,
           let asset = assets.first(where: { $0.id == lockID }) {
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
            asset = assets.first { $0.name.compare(pending, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
                ?? assets.first { $0.name.localizedCaseInsensitiveContains(pending) }
        }
        guard let asset else {
            present("Shortcuts", pending == "__featured__"
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
        activeByDisplay = Dictionary(uniqueKeysWithValues: engine.activeDisplayIDs.compactMap { id in
            guard let wallpaper = engine.wallpaperID(on: id) else { return nil }
            return (id, wallpaper)
        })
        displays = displayCoordinator.displays
    }

    func startStatsPolling() {
        refreshStats(includeDiskUsage: true)
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshStats() }
        }
        timer.tolerance = 3
        RunLoop.main.add(timer, forMode: .common)
        statsTimer = timer
    }

    func refreshStats(includeDiskUsage: Bool = false) {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            processMemoryMB = Double(info.resident_size) / 1_048_576
        }
        activeDecoderCount = engine.activeDecoderCount
        reduceMotionActive = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let cpu = cpuSampler.sample()
        processCPUPercent = cpu.process
        systemCPUPercent = cpu.system
        let previousPower = PowerStatus(isOnBattery: isOnBattery, percent: batteryPercent)
        let power = PowerStatus.current()
        batteryPercent = power.percent
        isOnBattery = power.isOnBattery
        if power != previousPower {
            applyPlaybackPolicy()
        }
        statsTick += 1
        if includeDiskUsage || statsTick.isMultiple(of: 4) {
            Task { @MainActor in
                let bytes = await store.diskUsageBytes()
                libraryDiskMB = Double(bytes) / 1_048_576
            }
        }
        if statsTick == 1 || statsTick.isMultiple(of: 4) {
            let sample = EnergySample(
                processCPUPercent: processCPUPercent,
                systemCPUPercent: systemCPUPercent,
                processMemoryMB: processMemoryMB,
                batteryPercent: batteryPercent,
                isOnBattery: isOnBattery,
                decoderCount: activeDecoderCount,
                powerProfile: powerProfile.rawValue,
                playbackActive: !playbackStopped && !activeByDisplay.isEmpty
            )
            Task { @MainActor in
                try? await energyLogStore.record(sample)
                await refreshEnergyReport()
            }
        }
    }
}
