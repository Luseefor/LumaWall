import Foundation
import XCTest

final class LogFileTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("LogFileTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func contents(_ name: String) -> String {
        (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)) ?? ""
    }

    func testWritesAfterARotationLandInTheNewFile() {
        // The crash: after rotating, the closed handle stayed stored, and the
        // next write raised an Objective-C exception that aborted the process.
        let log = LogFile(url: dir.appendingPathComponent("extension.log"), maxSize: 20, rotatedCopies: 2)
        log.append("aaaaaaaaaaaaaaaaaaaaaaaaa\n")
        log.append("b\n")
        log.append("c\n")
        log.append("d\n")
        XCTAssertEqual(contents("extension.1.log"), "aaaaaaaaaaaaaaaaaaaaaaaaa\n")
        XCTAssertEqual(contents("extension.log"), "b\nc\nd\n")
    }

    func testRotationKeepsOnlyTheConfiguredCopies() {
        let log = LogFile(url: dir.appendingPathComponent("extension.log"), maxSize: 4, rotatedCopies: 2)
        for line in ["one\n", "two\n", "three\n", "four\n"] { log.append(line) }
        XCTAssertEqual(contents("extension.log"), "four\n")
        XCTAssertEqual(contents("extension.1.log"), "three\n")
        XCTAssertEqual(contents("extension.2.log"), "two\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("extension.3.log").path))
    }

    func testAMissingFolderDropsWritesWithoutCrashingAndRecovers() throws {
        let folder = dir.appendingPathComponent("missing", isDirectory: true)
        let log = LogFile(url: folder.appendingPathComponent("extension.log"), maxSize: 1_000, rotatedCopies: 2)
        log.append("dropped\n")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        log.append("kept\n")
        XCTAssertEqual(contents("missing/extension.log"), "kept\n")
    }
}
