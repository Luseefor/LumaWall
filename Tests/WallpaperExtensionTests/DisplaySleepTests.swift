import XCTest

/// An extension launched while the displays slept never got
/// `screensDidSleep` and decoded in the dark (#34).
final class DisplaySleepTests: XCTestCase {
    func testEveryOnlineDisplayAsleepCountsAsAsleep() {
        XCTAssertTrue(DisplaySleep.allAsleep([true]))
        XCTAssertTrue(DisplaySleep.allAsleep([true, true, true]))
    }

    func testOneAwakeDisplayKeepsPlaybackOn() {
        // The flag gates every renderer, so one lit display keeps it open.
        XCTAssertFalse(DisplaySleep.allAsleep([true, false, true]))
        XCTAssertFalse(DisplaySleep.allAsleep([false]))
    }

    func testNoOnlineDisplayIsNotSleep() {
        // An empty list (mid-reconfiguration, or the query failed) says nothing.
        XCTAssertFalse(DisplaySleep.allAsleep([]))
    }

    func testOnlyAMissedSleepIsCaughtUp() {
        XCTAssertTrue(DisplaySleep.missedSleep(flagAsleep: false, displays: [true, true]))
        XCTAssertFalse(DisplaySleep.missedSleep(flagAsleep: true, displays: [true, true]), "already gated")
        // Waking stays with screensDidWake, which follows every real sleep.
        XCTAssertFalse(DisplaySleep.missedSleep(flagAsleep: true, displays: [false]))
        XCTAssertFalse(DisplaySleep.missedSleep(flagAsleep: false, displays: [false, true]))
    }

    // MARK: Ordering against notifications

    func testCatchUpSampledBeforeAWakeDoesNotUndoIt() {
        // Acquire sampled every display asleep, then screensDidWake cleared
        // the flag before the catch-up wrote it: playback stayed gated.
        var gate = SleepGate()
        let sampled = gate.epoch
        XCTAssertTrue(gate.notified(asleep: true))
        XCTAssertTrue(gate.notified(asleep: false))
        XCTAssertFalse(gate.catchUp(sampledAt: sampled, displays: [true, true]))
        XCTAssertFalse(gate.asleep)
    }

    func testCatchUpWithNoNotificationSinceItsSampleCloses() {
        var gate = SleepGate()
        XCTAssertTrue(gate.catchUp(sampledAt: gate.epoch, displays: [true]))
        XCTAssertTrue(gate.asleep)
        let sampled = gate.epoch
        XCTAssertFalse(gate.catchUp(sampledAt: sampled, displays: [true]), "already gated")
        XCTAssertTrue(gate.notified(asleep: false), "the wake still opens it")
        XCTAssertFalse(gate.asleep)
    }

    func testRepeatedNotificationStillOrdersLaterCatchUps() {
        var gate = SleepGate()
        let sampled = gate.epoch
        XCTAssertFalse(gate.notified(asleep: false), "no change")
        XCTAssertFalse(gate.catchUp(sampledAt: sampled, displays: [true]), "the wake is newer than the sample")
    }
}
