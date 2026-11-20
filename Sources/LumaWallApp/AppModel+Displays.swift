import AppKit
import CoreGraphics
import Darwin
import IOKit.ps
import LumaWallCore
import Observation
import UniformTypeIdentifiers

extension AppModel {
    func refreshDisplays() {
        displayRefreshWorkItem?.cancel()
        displays = displayCoordinator.refresh()
        refreshActive()
        Task {
            // Overlay geometry tracks the burst immediately (kill-free);
            // the native half waits for the topology to settle (below).
            await engine.restoreOverlay(using: assets)
            refreshActive()
            applyPlaybackPolicy()
        }
        scheduleSettledNativeRestore()
    }

    func scheduleDebouncedDisplayRefresh(delay: TimeInterval = 0.6) {
        displayRefreshWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshDisplays() }
        displayRefreshWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Native restore after the topology goes quiet. A monitor handshake flips
    /// modes (and momentarily drops the display) several times over a few
    /// seconds; restoring + killing WallpaperAgent on each flip orphans
    /// in-flight surfaces and strands half-negotiated ones on screen. Waiting
    /// for 2.5s of quiet collapses the burst into a single restore of the
    /// settled topology. Re-armed by every screen-parameters event.
    func scheduleSettledNativeRestore(delay: TimeInterval = 2.5) {
        nativeRestoreWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.engine.restoreNative(using: self.assets)
                self.refreshActive()
                self.applyPlaybackPolicy()
            }
        }
        nativeRestoreWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
