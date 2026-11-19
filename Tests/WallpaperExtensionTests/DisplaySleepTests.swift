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
}
