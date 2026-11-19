import Foundation
import XCTest

/// A Settings build reuses a library scan from the last few seconds (#14).
/// Overlapping scans must not let an older listing win.
final class LibraryScanRecordTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)

    func testAScanSupersededByANewerOneIsDropped() {
        // A Settings query lists the library, a video is imported, and the
        // import's notification scans and publishes first. The query's
        // older listing must not replace it and look fresh to the push.
        var record = LibraryScanRecord()
        let query = record.begin()
        let notification = record.begin()
        XCTAssertTrue(record.finish(notification, startedAt: t0 + 1))
        XCTAssertFalse(record.finish(query, startedAt: t0))
        XCTAssertEqual(record.publishedStart, t0 + 1)
    }

    func testScansThatFinishInOrderBothPublish() {
        var record = LibraryScanRecord()
        let first = record.begin()
        let second = record.begin()
        XCTAssertTrue(record.finish(first, startedAt: t0))
        XCTAssertTrue(record.finish(second, startedAt: t0 + 1))
    }

    func testFreshnessCountsFromWhenThePublishedScanStarted() {
        var record = LibraryScanRecord()
        XCTAssertFalse(record.isFresh(now: t0, maxAge: 10))
        _ = record.finish(record.begin(), startedAt: t0)
        XCTAssertTrue(record.isFresh(now: t0 + 9, maxAge: 10))
        XCTAssertFalse(record.isFresh(now: t0 + 10, maxAge: 10))
        XCTAssertFalse(record.isFresh(now: t0 - 1, maxAge: 10), "the clock moved back")
    }
}
