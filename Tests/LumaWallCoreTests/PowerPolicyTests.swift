import CoreGraphics
import Foundation
import LumaWallCore
import Testing

struct PowerPolicyTests {
    @Test func fullQualityOnPowerUsesFullTier() {
        #expect(PlaybackPolicy.resolve(.init()) == .full)
    }

    @Test func automaticBatteryPlaybackReducesWork() {
        #expect(PlaybackPolicy.resolve(.init(isOnBattery: true)) == .reduced)
    }

    @Test func staticBatteryProfileStopsAnimationWithoutBlanking() {
        #expect(PlaybackPolicy.resolve(.init(profile: .staticOnBattery, isOnBattery: true)) == .staticFrame)
    }

    @Test func lockPausesVideo() {
        #expect(PlaybackPolicy.resolve(.init(sessionIsLocked: true)) == .paused)
    }

    @Test func stillDesktopHidesLiveVideo() {
        #expect(PlaybackPolicy.resolve(.init(hideDesktopVideo: true)) == .staticFrame)
    }

    @Test func gameModePausesVideo() {
        #expect(PlaybackPolicy.resolve(.init(gameModeActive: true)) == .paused)
    }

    @Test func nativeLockOnlyKeepsLiveOnLock() {
        #expect(
            PlaybackPolicy.resolve(
                .init(sessionIsLocked: true, hideDesktopVideo: true, allowLiveOnLock: true)
            ) == .full
        )
    }

    @Test func reduceMotionUsesStillFrame() {
        #expect(PlaybackPolicy.resolve(.init(reduceMotion: true)) == .staticFrame)
    }

    @Test func batterySaverUsesMinimalTier() {
        // Unified tier semantics: batterySaver plays motion at a reduced budget
        // on both hosts (overlay reduced budget, native reduced budget + variant).
        #expect(
            PlaybackPolicy.resolve(.init(profile: .batterySaver, isOnBattery: true)) == .minimal
        )
        #expect(PlaybackTier.minimal < PlaybackTier.paused)
        #expect(PlaybackTier.full < PlaybackTier.reduced)
    }

    @Test func batteryThresholdsPinSharedValues() {
        // Pinned to PlaybackPolicyThresholds so the extension mirror
        // (WallpaperExtension/PlaybackPolicy.swift) can't drift silently.
        #expect(PlaybackPolicyThresholds.batteryCritical == 10)
        #expect(PlaybackPolicyThresholds.batteryLow == 20)
        #expect(PlaybackPolicy.resolve(.init(batteryPercent: 9)) == .paused)
        #expect(PlaybackPolicy.resolve(.init(batteryPercent: 10)) == .full)
        #expect(
            PlaybackPolicy.resolve(.init(isOnBattery: true, batteryPercent: 19)) == .minimal
        )
        #expect(
            PlaybackPolicy.resolve(.init(isOnBattery: true, batteryPercent: 20)) == .reduced
        )
    }

    @Test func occlusionThresholdsRequireNearTotalCoverage() {
        // Maximized windows with menu bar/dock visible (~96%) must NOT count
        // as occluded; only near-total coverage pauses.
        #expect(PlaybackPolicyThresholds.occlusionCovered == 0.985)
        #expect(PlaybackPolicyThresholds.fullscreenCoverage == 0.99)
        #expect(
            ScreenGeometry.isCovered(
                screen: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                windows: [CGRect(x: 0, y: 0, width: 1920, height: 1040)],
                threshold: PlaybackPolicyThresholds.occlusionCovered
            ) == false
        )
        #expect(
            ScreenGeometry.isCovered(
                screen: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                windows: [CGRect(x: 0, y: 0, width: 1920, height: 1080)],
                threshold: PlaybackPolicyThresholds.occlusionCovered
            )
        )
    }

    @Test func policyResolvesThroughProtocol() {
        // Protocol-first: resolution works through the capability protocol,
        // enabling stub decision-makers in tests.
        let decider: any PlaybackPolicyDeciding.Type = PlaybackPolicy.self
        #expect(decider.resolve(.init(gameModeActive: true)) == .paused)
    }

    @Test func userPauseAsleepObscuredAndGameModePause() {
        #expect(PlaybackPolicy.resolve(.init(userPaused: true)) == .paused)
        #expect(PlaybackPolicy.resolve(.init(displayIsAsleep: true)) == .paused)
        #expect(PlaybackPolicy.resolve(.init(displayIsObscured: true)) == .paused)
        #expect(PlaybackPolicy.resolve(.init(gameModeActive: true)) == .paused)
    }

    @Test func thermalEscalationReducesThenPauses() {
        #expect(PlaybackPolicy.resolve(.init(thermalState: .fair)) == .reduced)
        #expect(PlaybackPolicy.resolve(.init(thermalState: .serious)) == .minimal)
        #expect(PlaybackPolicy.resolve(.init(thermalState: .critical)) == .paused)
    }

    @Test func lowPowerModeDropsToMinimal() {
        #expect(PlaybackPolicy.resolve(.init(lowPowerMode: true)) == .minimal)
    }

    @Test func fullQualityIgnoresBatteryLevel() {
        #expect(PlaybackPolicy.resolve(.init(
            profile: .fullQuality, isOnBattery: true, batteryPercent: 15
        )) == .full)
    }

    @Test func profilesApplyOnACPower() {
        // Manual overrides stay usable on AC / battery-less desktops instead of
        // silently resolving to .full ("nothing changes").
        #expect(PlaybackPolicy.resolve(.init(profile: .batterySaver)) == .minimal)
        #expect(PlaybackPolicy.resolve(.init(profile: .staticOnBattery)) == .staticFrame)
        #expect(PlaybackPolicy.resolve(.init(profile: .fullQuality)) == .full)
        #expect(PlaybackPolicy.resolve(.init(profile: .automatic)) == .full)
    }

    @Test func fullQualityOverridesLowPowerAndFairThermal() {
        #expect(PlaybackPolicy.resolve(.init(profile: .fullQuality, lowPowerMode: true)) == .full)
        #expect(PlaybackPolicy.resolve(.init(profile: .fullQuality, thermalState: .fair)) == .full)
        // Hard protections still win over Full Quality.
        #expect(PlaybackPolicy.resolve(.init(profile: .fullQuality, thermalState: .serious)) == .minimal)
        #expect(PlaybackPolicy.resolve(.init(profile: .fullQuality, thermalState: .critical)) == .paused)
        #expect(PlaybackPolicy.resolve(.init(profile: .fullQuality, userPaused: true)) == .paused)
    }

    @Test func sessionLockPausesUnlessLiveOnLock() {
        #expect(PlaybackPolicy.resolve(.init(sessionIsLocked: true)) == .paused)
        // hideDesktopVideo without native lock support still pauses on lock.
        #expect(PlaybackPolicy.resolve(.init(
            sessionIsLocked: true, hideDesktopVideo: true, allowLiveOnLock: false
        )) == .paused)
    }

    @Test func hysteresisThresholdsArePinned() {
        #expect(PlaybackPolicyThresholds.occlusionRelease == 0.975)
        #expect(PlaybackPolicyThresholds.fullscreenRelease == 0.97)
    }

    @Test func occlusionLatchHoldsUntilRelease() {
        let id = DisplayID(rawValue: "test-display")
        var latch = OcclusionLatch()
        // Below enter: stays clear.
        latch.update(displayID: id, ratio: 0.98, rawCovered: false, rawFullscreen: false)
        #expect(latch.covered.isEmpty)
        // At/above enter: latches on.
        latch.update(displayID: id, ratio: 0.99, rawCovered: true, rawFullscreen: true)
        #expect(latch.covered == [id])
        #expect(latch.fullscreen == [id])
        // Between release and enter with raw clear: holds (no strobing).
        latch.update(displayID: id, ratio: 0.98, rawCovered: false, rawFullscreen: false)
        #expect(latch.covered == [id])
        #expect(latch.fullscreen == [id])
        // Below release: clears.
        latch.update(displayID: id, ratio: 0.5, rawCovered: false, rawFullscreen: false)
        #expect(latch.covered.isEmpty)
        #expect(latch.fullscreen.isEmpty)
        // Prune drops disconnected displays.
        latch.update(displayID: id, ratio: 0.99, rawCovered: true, rawFullscreen: false)
        latch.prune(to: [])
        #expect(latch.covered.isEmpty)
    }
}
