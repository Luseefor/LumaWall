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

    func testAReadPublishesBatteryBrightnessAndItsTimeTogether() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        var sample = PowerSample()
        XCTAssertTrue(sample.merge(battery: (onBattery: true, level: 40), brightness: 0.5, at: now))
        XCTAssertEqual(sample.state.isOnBattery, true)
        XCTAssertEqual(sample.state.batteryLevel, 40)
        XCTAssertEqual(sample.state.displayBrightness, 0.5)
        XCTAssertEqual(sample.batteryReadAt, now)
        XCTAssertFalse(sample.merge(battery: (onBattery: true, level: 40), brightness: 0.5, at: now + 30), "same values")
        XCTAssertEqual(sample.batteryReadAt, now + 30, "still a fresh battery reading")
    }

    func testAFailedBatteryReadKeepsTheOldReadingAndItsTime() {
        // IOKit returned nothing: the old battery state is as stale as before,
        // so the next policy computation must still re-read it.
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        var sample = PowerSample()
        _ = sample.merge(battery: (onBattery: false, level: 90), brightness: 1, at: now)
        XCTAssertTrue(sample.merge(battery: nil, brightness: 0.2, at: now + 40))
        XCTAssertEqual(sample.state.batteryLevel, 90)
        XCTAssertEqual(sample.state.displayBrightness, 0.2)
        XCTAssertEqual(sample.batteryReadAt, now)
        XCTAssertTrue(sample.batteryIsStale(now: now + 40))
    }

    // MARK: Power notifications

    func testANotificationQueuedBehindATransitionDoesntReplayAnOlderSample() {
        // Unplugged: the power-source notification is queued on the
        // lifecycle queue behind a lock update, which reads battery itself.
        // The queued read finds that reading and applies nothing; it never
        // reapplies the AC sample from before the unplug.
        var battery = PowerSnapshot()
        battery.isOnBattery = true
        var signal = PowerSignal()
        XCTAssertTrue(signal.notified())
        signal.applied(battery)
        XCTAssertNil(signal.take(latest: battery))
    }

    func testANewerSampleAfterTheTransitionApplies() {
        var battery = PowerSnapshot()
        battery.isOnBattery = true
        var signal = PowerSignal()
        signal.applied(battery)
        XCTAssertTrue(signal.notified())
        XCTAssertEqual(signal.take(latest: PowerSnapshot()), PowerSnapshot(), "plugged back in")
        XCTAssertTrue(signal.notified())
        XCTAssertNil(signal.take(latest: PowerSnapshot()), "already applied")
    }

    func testNotificationsCoalesceUntilTheQueuedReadRuns() {
        var signal = PowerSignal()
        XCTAssertTrue(signal.notified())
        XCTAssertFalse(signal.notified(), "a read is already queued")
        XCTAssertFalse(signal.notified())
        var hot = PowerSnapshot()
        hot.thermalState = .serious
        XCTAssertEqual(signal.take(latest: hot), hot)
        XCTAssertTrue(signal.notified(), "the next notification queues a new read")
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
