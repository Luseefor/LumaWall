import XCTest

/// A Settings push after a library change reuses the scan its notification
/// ran (#14). Overlapping scans must not let an older listing win.
final class LibraryScanRecordTests: XCTestCase {
    func testAScanSupersededByANewerOneIsDropped() {
        // A Settings query lists the library, a video is imported, and the
        // import's notification scans and publishes first. The query's
        // older listing must not replace it and reach the push.
        var record = LibraryScanRecord()
        let query = record.begin()
        let notification = record.begin()
        XCTAssertTrue(record.finish(notification))
        XCTAssertFalse(record.finish(query))
    }

    func testScansThatFinishInOrderBothPublish() {
        var record = LibraryScanRecord()
        let first = record.begin()
        let second = record.begin()
        XCTAssertTrue(record.finish(first))
        XCTAssertTrue(record.finish(second))
    }
}
