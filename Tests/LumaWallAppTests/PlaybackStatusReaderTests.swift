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

    private var file: URL { dir.appendingPathComponent(PlaybackStatusSnapshot.fileName) }

    func testReadsAWrittenSnapshot() throws {
        let snapshot = PlaybackStatusSnapshot(statuses: [
            DisplayPlaybackStatus(displayID: 4, state: .paused, reason: .gameMode, copy: .full, frameRate: 60)
        ])
        try snapshot.encoded().write(to: file)
        XCTAssertEqual(PlaybackStatusReader.read(from: file), snapshot)
    }

    func testMissingGarbledAndOversizedFilesReadAsNil() throws {
        XCTAssertNil(PlaybackStatusReader.read(from: file))
        try Data("{".utf8).write(to: file)
        XCTAssertNil(PlaybackStatusReader.read(from: file))
        try Data(repeating: 0x20, count: PlaybackStatusReader.maxBytes + 1).write(to: file)
        XCTAssertNil(PlaybackStatusReader.read(from: file))
    }

    func testASymlinkIsNotFollowed() throws {
        let real = dir.appendingPathComponent("real.json")
        try PlaybackStatusSnapshot(statuses: []).encoded().write(to: real)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: real)
        XCTAssertNil(PlaybackStatusReader.read(from: file))
    }
}
