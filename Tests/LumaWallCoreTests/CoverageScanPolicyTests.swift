import Foundation
import LumaWallCore
import Testing

struct CoverageScanPolicyTests {
    @Test func fallbackScansWhenPlaying() {
        #expect(
            CoverageScanPolicy.fallbackScanNeeded(
                userPausedEverywhere: false, displaysAsleep: false, sessionLocked: false, hasAssignedWallpaper: true))
    }

    @Test func fallbackSkipsWhenCoverageCannotMatter() {
        #expect(
            !CoverageScanPolicy.fallbackScanNeeded(
                userPausedEverywhere: true, displaysAsleep: false, sessionLocked: false, hasAssignedWallpaper: true))
        #expect(
            !CoverageScanPolicy.fallbackScanNeeded(
                userPausedEverywhere: false, displaysAsleep: true, sessionLocked: false, hasAssignedWallpaper: true))
        #expect(
            !CoverageScanPolicy.fallbackScanNeeded(
                userPausedEverywhere: false, displaysAsleep: false, sessionLocked: true, hasAssignedWallpaper: true))
        #expect(
            !CoverageScanPolicy.fallbackScanNeeded(
                userPausedEverywhere: false, displaysAsleep: false, sessionLocked: false, hasAssignedWallpaper: false))
    }

    @Test func powerChangeClassification() {
        let ac = PowerStatus(isOnBattery: false, percent: 80)
        #expect(CoverageScanPolicy.powerChange(from: ac, to: ac) == .none)
        #expect(CoverageScanPolicy.powerChange(from: ac, to: PowerStatus(isOnBattery: false, percent: 81)) == .percentOnly)
        #expect(CoverageScanPolicy.powerChange(from: ac, to: PowerStatus(isOnBattery: true, percent: 80)) == .sourceSwitched)
    }
}

struct PowerSampleTrackerTests {
    @Test func firstSampleIsASwitch() {
        var tracker = PowerSampleTracker()
        #expect(tracker.observe(PowerStatus(isOnBattery: false, percent: 90)) == .sourceSwitched)
    }

    @Test func sameSourceClassifiesByPercent() {
        var tracker = PowerSampleTracker()
        _ = tracker.observe(PowerStatus(isOnBattery: false, percent: 90))
        tracker.noteCoverageScan(onBattery: false)
        #expect(tracker.observe(PowerStatus(isOnBattery: false, percent: 91)) == .percentOnly)
        #expect(tracker.observe(PowerStatus(isOnBattery: false, percent: 91)) == .none)
    }

    /// AC sampled, a workspace scan ran on battery, AC returned before the
    /// next callback: the sample looks unchanged but coverage is stale.
    @Test func coverageMeasuredOnOtherSourceForcesRefresh() {
        var tracker = PowerSampleTracker()
        _ = tracker.observe(PowerStatus(isOnBattery: false, percent: 90))
        tracker.noteCoverageScan(onBattery: true)
        #expect(tracker.observe(PowerStatus(isOnBattery: false, percent: 90)) == .sourceSwitched)
    }
}

@MainActor
struct CoverageDebouncerTests {
    @Test func burstRunsOnceAfterTheLastSignal() async throws {
        var runs = 0
        let debouncer = CoverageDebouncer(delay: .milliseconds(40)) { runs += 1 }
        for _ in 0..<5 { debouncer.signal() }
        try await Task.sleep(for: .milliseconds(150))
        #expect(runs == 1)
    }

    @Test func cancelStopsAPendingScan() async throws {
        var runs = 0
        let debouncer = CoverageDebouncer(delay: .milliseconds(40)) { runs += 1 }
        debouncer.signal()
        debouncer.cancel()
        try await Task.sleep(for: .milliseconds(150))
        #expect(runs == 0)
    }
}

struct OcclusionLatchPowerSourceTests {
    private let id = DisplayID(rawValue: "test-display")

    private func tier(_ latch: OcclusionLatch, onBattery: Bool) -> PlaybackTier {
        PlaybackPolicy.resolve(.init(isOnBattery: onBattery, displayIsObscured: latch.covered.contains(id)))
    }

    /// 1,440-pt display with a 28-pt menu bar: a maximized window measures
    /// 100% ignoring the menu bar (battery) and about 98.1% counting it (AC).
    @Test func acBatteryScanAcPausesOnlyOnBattery() {
        var latch = OcclusionLatch()
        // AC: below the 98.5% enter threshold, so playing.
        latch.beginScan(onBattery: false)
        latch.update(displayID: id, ratio: 0.981, rawCovered: false, rawFullscreen: false)
        #expect(tier(latch, onBattery: false) == .full)
        // Battery scan: the menu bar is ignored, so covered.
        latch.beginScan(onBattery: true)
        latch.update(displayID: id, ratio: 1.0, rawCovered: true, rawFullscreen: false)
        #expect(tier(latch, onBattery: true) == .paused)
        // AC again, repeated scans: 98.1% sits between release and enter, but
        // the covered verdict came from the battery measurement and must drop.
        for _ in 0..<3 {
            latch.beginScan(onBattery: false)
            latch.update(displayID: id, ratio: 0.981, rawCovered: false, rawFullscreen: false)
            #expect(tier(latch, onBattery: false) == .full)
        }
    }

    @Test func sourceChangeKeepsFullscreenHysteresis() {
        var latch = OcclusionLatch()
        latch.beginScan(onBattery: false)
        latch.update(displayID: id, ratio: 1.0, rawCovered: true, rawFullscreen: true)
        latch.beginScan(onBattery: true)
        #expect(latch.fullscreen == [id])
        #expect(latch.covered.isEmpty)
    }

    @Test func sameSourceKeepsCoveredHysteresis() {
        var latch = OcclusionLatch()
        latch.beginScan(onBattery: false)
        latch.update(displayID: id, ratio: 1.0, rawCovered: true, rawFullscreen: false)
        latch.beginScan(onBattery: false)
        #expect(latch.covered == [id])
    }
}
