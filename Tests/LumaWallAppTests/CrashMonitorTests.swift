import Darwin
import Foundation
import XCTest

@testable import LumaWall

/// The signal handler writes pending.stack with raw syscalls. It created
/// the file 0644 and followed a symlink planted at that path.
final class CrashMonitorTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func open(_ url: URL) -> Int32 {
        Array(url.path.utf8CString).withUnsafeBufferPointer { CrashMonitor.openDumpFile($0.baseAddress!) }
    }

    private func mode(of url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    func testTheDumpIsCreatedForTheUserOnly() throws {
        let dump = dir.appendingPathComponent("pending.stack")
        let fd = open(dump)
        XCTAssertGreaterThanOrEqual(fd, 0)
        close(fd)
        XCTAssertEqual(try mode(of: dump), 0o600)
    }

    func testAnOlderWorldReadableDumpIsTightened() throws {
        let dump = dir.appendingPathComponent("pending.stack")
        try Data("old".utf8).write(to: dump)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dump.path)
        let fd = open(dump)
        XCTAssertGreaterThanOrEqual(fd, 0)
        close(fd)
        XCTAssertEqual(try mode(of: dump), 0o600)
        XCTAssertEqual(try Data(contentsOf: dump), Data())
    }

    func testTheDumpIsNeverWrittenThroughASymlink() throws {
        let victim = dir.appendingPathComponent("victim.txt")
        try Data("keep".utf8).write(to: victim)
        let dump = dir.appendingPathComponent("pending.stack")
        try FileManager.default.createSymbolicLink(at: dump, withDestinationURL: victim)
        XCTAssertLessThan(open(dump), 0)
        XCTAssertEqual(try Data(contentsOf: victim), Data("keep".utf8))
    }
}
