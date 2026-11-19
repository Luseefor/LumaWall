import XCTest

/// Battery and brightness were read every 30 s even with nothing playing
/// (#14). The poll now runs only while a reading can change what plays.
final class PowerPollingTests: XCTestCase {
    func testPollsEverythingWhileAnythingPlays() {
        XCTAssertEqual(PowerPolling.mode(anyPlaying: true, batteryLevel: 80, displayBrightness: 0.7), .all)
    }

    func testStopsWhenNothingPlays() {
        XCTAssertEqual(PowerPolling.mode(anyPlaying: false, batteryLevel: 80, displayBrightness: 0.7), .off)
    }

    func testWatchesBrightnessWhileItsPauseHolds() {
        // Raising the backlight from zero has no notification; only a read
        // notices it and resumes playback.
        XCTAssertEqual(PowerPolling.mode(anyPlaying: false, batteryLevel: 80, displayBrightness: 0), .brightness)
        XCTAssertEqual(
            PowerPolling.mode(anyPlaying: false, batteryLevel: 80, displayBrightness: PlaybackPolicy.brightnessPauseThreshold),
            .off,
        )
    }

    func testWatchesTheBatteryWhileItsCriticalPauseHolds() {
        // Charging past the critical level resumes playback.
        XCTAssertEqual(PowerPolling.mode(anyPlaying: false, batteryLevel: 5, displayBrightness: 0), .all)
        XCTAssertEqual(
            PowerPolling.mode(anyPlaying: false, batteryLevel: PlaybackPolicy.batteryCriticalLevel, displayBrightness: 1),
            .off,
        )
    }

    func testPlayingRenderersReportOnlyTheFirstAndLast() {
        var playing = PlayingRenderers()
        XCTAssertTrue(playing.set(1, playing: true))
        XCTAssertFalse(playing.set(2, playing: true))
        XCTAssertFalse(playing.set(1, playing: true))
        XCTAssertFalse(playing.set(1, playing: false))
        XCTAssertTrue(playing.anyPlaying)
        XCTAssertTrue(playing.set(2, playing: false))
        XCTAssertFalse(playing.anyPlaying)
        XCTAssertFalse(playing.set(3, playing: false), "a renderer that never played")
    }
}
