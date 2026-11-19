import CoreMedia
import XCTest

/// Resuming a looped clip: the renderer's timeline keeps growing across loops,
/// but a reader seeks in asset time (#27).
final class LoopTimingTests: XCTestCase {
    private func t(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }

    func testFirstLoopResumesAtTheTimelineTime() {
        let point = LoopTiming.resumePoint(timeline: t(5), loopStart: .zero, previousLoopStart: .zero)
        XCTAssertEqual(point, LoopTiming.ResumePoint(assetTime: t(5), loopStart: .zero))
    }

    func testResumeAfterCompletedLoopsSeeksIntoTheDisplayedLoop() {
        // A 30 s clip paused 5 s into its third loop.
        let point = LoopTiming.resumePoint(timeline: t(65), loopStart: t(60), previousLoopStart: t(30))
        XCTAssertEqual(point, LoopTiming.ResumePoint(assetTime: t(5), loopStart: t(60)))
    }

    func testPauseBeforeTheReadAheadLoopShowsResumesInTheLoopOnScreen() {
        // The feed had already swapped to loop 3 while loop 2's tail showed.
        let point = LoopTiming.resumePoint(timeline: t(59.5), loopStart: t(60), previousLoopStart: t(30))
        XCTAssertEqual(point, LoopTiming.ResumePoint(assetTime: t(29.5), loopStart: t(30)))
    }

    func testTimeBeforeBothKnownLoopsClampsToTheStartOfTheOlder() {
        let point = LoopTiming.resumePoint(timeline: t(10), loopStart: t(60), previousLoopStart: t(30))
        XCTAssertEqual(point, LoopTiming.ResumePoint(assetTime: .zero, loopStart: t(30)))
    }
}
