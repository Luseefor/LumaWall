import XCTest

final class DisplayStatusBuilderTests: XCTestCase {
    private func build(
        _ tier: PlaybackPolicy, _ reason: PlaybackStatusReason? = nil, asleep: Bool = false,
        filename: String = "Wallpaper.mov", fps: Int = 60, decodeFailed: Bool = false
    ) -> DisplayPlaybackStatus {
        DisplayStatusBuilder.status(
            .init(
                displayID: 7, decision: .init(tier: tier, reason: reason), displayAsleep: asleep,
                filename: filename, frameRate: fps, decodeFailed: decodeFailed))
    }

    func testFullPlaysTheOriginalAtItsRate() {
        let status = build(.full)
        XCTAssertEqual(status.state, .playing)
        XCTAssertNil(status.reason)
        XCTAssertEqual(status.copy, .full)
        XCTAssertEqual(status.frameRate, 60)
    }

    func testABatteryCopyReportsItsOwnRate() {
        let status = build(.reduced, .batteryTier, filename: "Wallpaper.reduced.mov", fps: 30)
        XCTAssertEqual(status.copy, .p1080)
        XCTAssertEqual(status.frameRate, 30)
        XCTAssertEqual(status.reason, .batteryTier)
        XCTAssertEqual(status.state, .playing)
    }

    func testPausedKeepsTheReasonAndTheHeldCopy() {
        let status = build(.paused, .covered, filename: "Wallpaper.minimal.mov")
        XCTAssertEqual(status.state, .paused)
        XCTAssertEqual(status.reason, .covered)
        XCTAssertEqual(status.copy, .p720)
    }

    func testASleepingDisplayIsPausedForSleepWhateverTheTier() {
        let status = build(.full, asleep: true)
        XCTAssertEqual(status.state, .paused)
        XCTAssertEqual(status.reason, .displayAsleep)
    }

    func testUnknownRateIsLeftOut() {
        let status = DisplayStatusBuilder.status(
            .init(
                displayID: 1, decision: .init(tier: .full, reason: nil), displayAsleep: false,
                filename: "Wallpaper.mov", frameRate: 0, decodeFailed: false))
        XCTAssertNil(status.frameRate)
    }

    func testAStillAfterDecoderFailureIsNotPlaying() {
        let status = build(.full, decodeFailed: true)
        XCTAssertEqual(status.state, .paused)
        XCTAssertEqual(status.reason, .decodeFailed)
        // A pause that already applies keeps its own reason.
        XCTAssertEqual(build(.paused, .covered, decodeFailed: true).reason, .covered)
    }
}
