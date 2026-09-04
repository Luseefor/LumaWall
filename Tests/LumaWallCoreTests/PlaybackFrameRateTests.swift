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

    @Test func invalidFrameRatesFallBackToSaneDefaults() {
        // Non-finite or non-positive inputs must never produce a zero/NaN step.
        #expect(abs(PlaybackFrameRate.pumpInterval(sourceFPS: 0, displayMaxFPS: 60) - (1.0 / 60.0)) < 0.0001)
        #expect(abs(PlaybackFrameRate.pumpInterval(sourceFPS: 30, displayMaxFPS: -5) - (1.0 / 30.0)) < 0.0001)
        #expect(abs(PlaybackFrameRate.pumpInterval(sourceFPS: .nan, displayMaxFPS: .infinity) - (1.0 / 60.0)) < 0.0001)
        #expect(PlaybackFrameRate.frameDuration(fps: .nan).seconds > 0)
        #expect(PlaybackFrameRate.frameDuration(fps: 0).seconds > 0)
    }
}
