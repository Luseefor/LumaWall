import CryptoKit
import Foundation
import LumaWallCore
import Testing

/// Import and deploy check a file, then use it. These tests pin that the
/// bytes copied are the bytes hashed, and that only a regular file is read.
struct VerifiedFileCopyTests {
    private let fm = FileManager.default

    private func makeDir() throws -> URL {
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func copiesTheBytesItHashes() throws {
        let dir = try makeDir()
        defer { try? fm.removeItem(at: dir) }
        let bytes = Data((0..<3_000_000).map { UInt8($0 % 251) })
        let source = dir.appendingPathComponent("clip.mov")
        try bytes.write(to: source)
        let dest = dir.appendingPathComponent("staged.mov")

        let result = try VerifiedFileCopy.copy(from: source, to: dest)
        #expect(try Data(contentsOf: dest) == bytes)
        #expect(result.size == Int64(bytes.count))
        #expect(result.sha256 == SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    }

    @Test func refusesAnythingButARegularFile() throws {
        let dir = try makeDir()
        defer { try? fm.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("folder.mov", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let fifo = dir.appendingPathComponent("pipe.mov")
        #expect(mkfifo(fifo.path, 0o600) == 0)

        for source in [folder, fifo] {
            #expect(throws: VerifiedFileCopy.CopyError.notARegularFile) {
                try VerifiedFileCopy.copy(from: source, to: dir.appendingPathComponent(UUID().uuidString))
            }
        }
        #expect(throws: VerifiedFileCopy.CopyError.notALocalFile) {
            try VerifiedFileCopy.copy(
                from: try #require(URL(string: "https://example.com/clip.mov")), to: dir.appendingPathComponent("x"))
        }
    }

    @Test func neverWritesThroughAnExistingDestination() throws {
        let dir = try makeDir()
        defer { try? fm.removeItem(at: dir) }
        let source = dir.appendingPathComponent("clip.mov")
        try Data("new".utf8).write(to: source)
        let victim = dir.appendingPathComponent("victim.txt")
        try Data("keep".utf8).write(to: victim)
        let link = dir.appendingPathComponent("staged.mov")
        try fm.createSymbolicLink(at: link, withDestinationURL: victim)

        #expect(throws: (any Error).self) { try VerifiedFileCopy.copy(from: source, to: link) }
        #expect(throws: (any Error).self) { try VerifiedFileCopy.copy(from: source, to: victim) }
        #expect(try Data(contentsOf: victim) == Data("keep".utf8))
    }
}
