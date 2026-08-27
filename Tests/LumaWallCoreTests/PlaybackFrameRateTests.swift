import Foundation
import LumaWallCore
import Testing

@Suite struct PlaybackFrameRateTests {
    @Test func pumpIntervalUsesSourceUpToDisplayCap() {
        #expect(abs(PlaybackFrameRate.pumpInterval(sourceFPS: 120, displayMaxFPS: 120) - (1.0 / 120.0)) < 0.0001)
        #expect(abs(PlaybackFrameRate.pumpInterval(sourceFPS: 120, displayMaxFPS: 60) - (1.0 / 60.0)) < 0.0001)
        #expect(abs(PlaybackFrameRate.pumpInterval(sourceFPS: 30, displayMaxFPS: 120) - (1.0 / 30.0)) < 0.0001)
    }

    @Test func frameDurationTracksHighFPS() {
        let step = PlaybackFrameRate.frameDuration(fps: 120)
        #expect(step.seconds > 0)
        #expect(abs(step.seconds - (1.0 / 120.0)) < 0.001)
    }
}
