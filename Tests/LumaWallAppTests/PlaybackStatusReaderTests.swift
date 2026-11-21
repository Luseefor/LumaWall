import LumaWallCore
import XCTest

@testable import LumaWall

final class PlaybackStatusReaderTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("status-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ statuses: [DisplayPlaybackStatus], pid: Int32) throws {
        try PlaybackStatusSnapshot(statuses: statuses).encoded()
            .write(to: dir.appendingPathComponent(PlaybackStatusSnapshot.fileName(pid: pid)))
    }

    func testReadsAWrittenSnapshot() throws {
        let status = DisplayPlaybackStatus(displayID: 4, state: .paused, reason: .gameMode, copy: .full, frameRate: 60)
        try write([status], pid: 10)
        XCTAssertEqual(PlaybackStatusReader.read(in: dir, isAlive: { _ in true }).statuses, [status])
    }

    func testProcessesMergeAndAnEmptyOneErasesNothing() throws {
        let desktop = DisplayPlaybackStatus(displayID: 4, state: .playing, copy: .full, frameRate: 60)
        try write([desktop], pid: 10)
        try write([], pid: 20)  // a Settings preview process
        XCTAssertEqual(PlaybackStatusReader.read(in: dir, isAlive: { _ in true }).statuses, [desktop])
    }

    func testAFileOfADeadProcessIsSkipped() throws {
        try write([DisplayPlaybackStatus(displayID: 4, state: .playing)], pid: 10)
        XCTAssertTrue(PlaybackStatusReader.read(in: dir, isAlive: { _ in false }).statuses.isEmpty)
    }

    func testMissingGarbledAndOversizedFilesAreSkipped() throws {
        XCTAssertTrue(PlaybackStatusReader.read(in: dir, isAlive: { _ in true }).statuses.isEmpty)
        let file = dir.appendingPathComponent(PlaybackStatusSnapshot.fileName(pid: 10))
        try Data("{".utf8).write(to: file)
        XCTAssertNil(PlaybackStatusReader.read(file: file))
        try Data(repeating: 0x20, count: PlaybackStatusReader.maxBytes + 1).write(to: file)
        XCTAssertNil(PlaybackStatusReader.read(file: file))
    }

    func testASymlinkIsNotFollowed() throws {
        let real = dir.appendingPathComponent("real.json")
        try PlaybackStatusSnapshot(statuses: [DisplayPlaybackStatus(displayID: 1, state: .playing)]).encoded().write(to: real)
        let link = dir.appendingPathComponent(PlaybackStatusSnapshot.fileName(pid: 10))
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertNil(PlaybackStatusReader.read(file: link))
    }

    func testThisProcessIsAliveAndAnImpossiblePidIsNot() {
        XCTAssertTrue(PlaybackStatusReader.processIsAlive(ProcessInfo.processInfo.processIdentifier))
        XCTAssertFalse(PlaybackStatusReader.processIsAlive(Int32.max))
    }
}
