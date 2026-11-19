import Foundation
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

    func testAReadingOlderThanThePollIsReadAgain() {
        // With the poll stopped, a policy computed on wake or lock must not
        // use the battery state from before the Mac was unplugged.
        let read = Date(timeIntervalSinceReferenceDate: 1_000)
        XCTAssertTrue(PowerPolling.readIsStale(lastRead: nil, now: read))
        XCTAssertFalse(PowerPolling.readIsStale(lastRead: read, now: read + PowerPolling.interval - 1))
        XCTAssertTrue(PowerPolling.readIsStale(lastRead: read, now: read + PowerPolling.interval))
        XCTAssertTrue(PowerPolling.readIsStale(lastRead: read, now: read - 1), "the clock moved back")
    }

    func testAReadThatFindsAHardwarePauseStartsThePoll() {
        // Polling is off; a lock computes its policy and the read finds the
        // backlight at zero. Nothing ever plays, so only the read can start
        // the poll that notices the backlight coming back.
        var poller = PowerPoller()
        XCTAssertEqual(poller.reading(batteryLevel: 80, displayBrightness: 0.7), .keep)
        XCTAssertEqual(poller.reading(batteryLevel: 80, displayBrightness: 0), .start)
        XCTAssertEqual(poller.mode, .brightness)
        XCTAssertEqual(poller.reading(batteryLevel: 80, displayBrightness: 0), .keep)
        XCTAssertEqual(poller.reading(batteryLevel: 80, displayBrightness: 0.5), .stop)
        XCTAssertEqual(poller.mode, .off)
    }

    func testCriticalBatteryFoundByAReadPollsUntilItCharges() {
        var poller = PowerPoller()
        XCTAssertEqual(poller.reading(batteryLevel: 6, displayBrightness: 1), .start)
        XCTAssertEqual(poller.mode, .all)
        XCTAssertEqual(poller.reading(batteryLevel: 7, displayBrightness: 0), .keep)
        XCTAssertEqual(poller.mode, .all)
        XCTAssertEqual(poller.reading(batteryLevel: 12, displayBrightness: 0), .keep)
        XCTAssertEqual(poller.mode, .brightness)
        XCTAssertEqual(poller.reading(batteryLevel: 12, displayBrightness: 1), .stop)
    }

    func testPlaybackStartsAndStopsThePoll() {
        var poller = PowerPoller()
        XCTAssertEqual(poller.playback(1, playing: true), .start)
        XCTAssertEqual(poller.playback(2, playing: true), .keep)
        XCTAssertEqual(poller.reading(batteryLevel: 80, displayBrightness: 0), .keep, "still playing")
        XCTAssertEqual(poller.playback(1, playing: false), .keep)
        XCTAssertEqual(poller.playback(2, playing: false), .keep, "the zero backlight keeps it")
        XCTAssertEqual(poller.mode, .brightness)
        XCTAssertEqual(poller.reading(batteryLevel: 80, displayBrightness: 1), .stop)
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
