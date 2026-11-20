import Foundation
import XCTest

/// Any process can post the notifications the extension listens for, so
/// each one is checked before it acts (#68 S7).
final class NotificationGuardsTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: Lock hints

    func testALockHintAppliesWhenTheSessionIsLocked() {
        XCTAssertTrue(ScreenLockHint.shouldApply(claimsLocked: true, sessionLocked: true))
        XCTAssertTrue(ScreenLockHint.shouldApply(claimsLocked: false, sessionLocked: false))
    }

    func testAHintTheSessionContradictsIsIgnored() {
        XCTAssertFalse(ScreenLockHint.shouldApply(claimsLocked: true, sessionLocked: false))
        XCTAssertFalse(ScreenLockHint.shouldApply(claimsLocked: false, sessionLocked: true))
    }

    func testAHintIsIgnoredWhenTheSessionStateCantBeRead() {
        XCTAssertFalse(ScreenLockHint.shouldApply(claimsLocked: true, sessionLocked: nil))
        XCTAssertFalse(ScreenLockHint.shouldApply(claimsLocked: false, sessionLocked: nil))
    }

    func testReadsTheLockFlagFromTheSessionDictionary() {
        XCTAssertEqual(ScreenLockHint.isLocked(session: ["CGSSessionScreenIsLocked": true]), true)
        XCTAssertEqual(ScreenLockHint.isLocked(session: ["kCGSSessionOnConsoleKey": true]), false)
        XCTAssertNil(ScreenLockHint.isLocked(session: nil))
    }

    // MARK: Clear-cache request

    func testAClearNeedsTheAppsRequestFile() {
        XCTAssertFalse(CacheClearRequest.consume(in: dir))
    }

    func testAFreshRequestIsHonouredOnce() throws {
        try Data().write(to: dir.appendingPathComponent(CacheClearRequest.fileName))
        XCTAssertTrue(CacheClearRequest.consume(in: dir))
        XCTAssertFalse(CacheClearRequest.consume(in: dir))
    }

    func testAStaleRequestIsRefusedAndRemoved() throws {
        let file = dir.appendingPathComponent(CacheClearRequest.fileName)
        try Data().write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -120)], ofItemAtPath: file.path)
        XCTAssertFalse(CacheClearRequest.consume(in: dir))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testARequestThatIsASymlinkIsRefused() throws {
        let target = dir.appendingPathComponent("elsewhere")
        try Data().write(to: target)
        try FileManager.default.createSymbolicLink(
            at: dir.appendingPathComponent(CacheClearRequest.fileName), withDestinationURL: target)
        XCTAssertFalse(CacheClearRequest.consume(in: dir))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }

    func testRequestFreshnessWindow() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(CacheClearRequest.isFresh(modified: now.addingTimeInterval(-29), now: now))
        XCTAssertFalse(CacheClearRequest.isFresh(modified: now.addingTimeInterval(-31), now: now))
        XCTAssertFalse(CacheClearRequest.isFresh(modified: now.addingTimeInterval(60), now: now))
    }

    // MARK: Which files a clear removes

    private let still = String(repeating: "a", count: 64) + "-2560-1440-0-41d9f4c2a1b00000.bmp"

    func testAClearRemovesOnlyOurStills() throws {
        for name in [still, "agent-poster.bmp", "cacheVersion.db"] {
            try Data().write(to: dir.appendingPathComponent(name))
        }
        XCTAssertEqual(StillCacheSweep.filesToClear(in: dir)?.map(\.lastPathComponent), [still])
    }

    func testAClearSkipsAStillNamedSymlink() throws {
        let target = dir.appendingPathComponent("keep.txt")
        try Data().write(to: target)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent(still), withDestinationURL: target)
        XCTAssertEqual(StillCacheSweep.filesToClear(in: dir), [])
    }

    func testAClearRefusesADirectoryThatIsASymlink() throws {
        let link = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dir)
        defer { try? FileManager.default.removeItem(at: link) }
        try Data().write(to: dir.appendingPathComponent(still))
        XCTAssertNil(StillCacheSweep.filesToClear(in: link))
    }
}
