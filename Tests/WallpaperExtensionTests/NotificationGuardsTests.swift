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

    func testOnlyAConfirmedUnlockAfterALockCountsAsAWake() {
        var tracker = LockHintTracker(sessionLocked: false)
        XCTAssertFalse(tracker.confirm(locked: false), "unlock while already unlocked")
        XCTAssertFalse(tracker.confirm(locked: true))
        XCTAssertTrue(tracker.confirm(locked: false))
        XCTAssertFalse(tracker.confirm(locked: false), "a repeated unlock")
    }

    func testALockTheAgentReportedCountsUntilAnUnlockConsumesIt() {
        // The lock hint was missed while the process was suspended; the
        // Agent's later desktop update doesn't undo what it saw.
        var tracker = LockHintTracker(sessionLocked: false)
        tracker.noteAgentLocked()
        XCTAssertTrue(tracker.confirm(locked: false))
        XCTAssertFalse(tracker.confirm(locked: false))
    }

    func testAnUnknownStartingStateNeverCountsAsAWake() {
        var tracker = LockHintTracker(sessionLocked: nil)
        XCTAssertFalse(tracker.confirm(locked: false))
    }

    func testStartingLockedTheFirstUnlockIsAWake() {
        var tracker = LockHintTracker(sessionLocked: true)
        XCTAssertTrue(tracker.confirm(locked: false))
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

    func testARequestThatIsADirectoryIsRefusedAndLeftAlone() throws {
        let request = dir.appendingPathComponent(CacheClearRequest.fileName)
        try FileManager.default.createDirectory(at: request, withIntermediateDirectories: true)
        let inside = request.appendingPathComponent("keep.txt")
        try Data().write(to: inside)
        XCTAssertFalse(CacheClearRequest.consume(in: dir))
        XCTAssertTrue(FileManager.default.fileExists(atPath: inside.path))
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

    func testAClearSkipsNamesTheWriterNeverEmits() throws {
        let nearMisses = [
            String(repeating: "z", count: 64) + "-2560-1440-0-41d9f4c2a1b00000.bmp",
            String(repeating: "a", count: 64) + "-2560-1440-0-1.bmp",
            String(repeating: "a", count: 64) + "-+2560-1440-0-41d9f4c2a1b00000.bmp",
            String(repeating: "A", count: 64) + "-2560-1440-0-41d9f4c2a1b00000.bmp",
        ]
        for name in nearMisses {
            try Data().write(to: dir.appendingPathComponent(name))
        }
        XCTAssertEqual(StillCacheSweep.filesToClear(in: dir), [])
    }

    func testAClearDeletesOurStillsAndLeavesEverythingElse() throws {
        try Data().write(to: dir.appendingPathComponent(still))
        try Data().write(to: dir.appendingPathComponent("cacheVersion.db"))
        XCTAssertEqual(StillCacheSweep.clear(in: dir), 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["cacheVersion.db"])
    }

    func testAClearNeverDeletesADirectoryRecursively() throws {
        // A still swapped for a directory between the scan and the delete.
        let swapped = dir.appendingPathComponent(still)
        try FileManager.default.createDirectory(at: swapped, withIntermediateDirectories: true)
        try Data().write(to: swapped.appendingPathComponent("keep.txt"))
        XCTAssertEqual(StillCacheSweep.remove([swapped], in: dir), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: swapped.appendingPathComponent("keep.txt").path))
    }

    func testAClearReportsNothingForADirectoryThatIsASymlink() throws {
        let link = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dir)
        defer { try? FileManager.default.removeItem(at: link) }
        try Data().write(to: dir.appendingPathComponent(still))
        XCTAssertNil(StillCacheSweep.clear(in: link))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(still).path))
    }

    func testAClearRefusesADirectoryThatIsASymlink() throws {
        let link = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dir)
        defer { try? FileManager.default.removeItem(at: link) }
        try Data().write(to: dir.appendingPathComponent(still))
        XCTAssertNil(StillCacheSweep.filesToClear(in: link))
    }

    // MARK: Playlist notifications

    /// Nothing posts `nextPlaylistItem` or `previousPlaylistItem`, and any
    /// process could, so the extension must not observe them. Stepping a
    /// playlist goes through the XPC `skip` call, which checks its caller.
    func testExtensionObservesNoPlaylistStepNotifications() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("WallpaperExtension", isDirectory: true)
        // The target takes the whole folder, subfolders included.
        let files = (FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?.allObjects ?? [])
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "no extension sources at \(sources.path)")
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for name in ["nextPlaylistItem", "previousPlaylistItem"] {
                XCTAssertFalse(text.contains(name), "\(file.lastPathComponent) still names \(name)")
            }
        }
    }
}
