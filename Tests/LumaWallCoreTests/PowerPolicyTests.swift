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
}
