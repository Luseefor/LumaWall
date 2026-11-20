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
        #expect(try VerifiedFileCopy.sha256(ofFileAt: source) == result)
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
        for source in [folder, fifo] {
            #expect(throws: VerifiedFileCopy.CopyError.notARegularFile) { try VerifiedFileCopy.sha256(ofFileAt: source) }
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

    @Test func copiesAFileOutOfATrustedFolder() throws {
        let dir = try makeDir()
        defer { try? fm.removeItem(at: dir) }
        let bytes = Data("deployed".utf8)
        try bytes.write(to: dir.appendingPathComponent("Wallpaper.mov"))
        let dest = dir.appendingPathComponent("private.mov")

        let result = try VerifiedFileCopy.copy(named: "Wallpaper.mov", in: TrustedDirectory(url: dir), to: dest)
        #expect(try Data(contentsOf: dest) == bytes)
        #expect(result == (try VerifiedFileCopy.sha256(ofFileAt: dest)))
    }

    /// The extension can swap a deployed video for a symlink to a user's
    /// file. The target here has the same bytes, so only a refusal to follow
    /// the link, not a hash check, makes the copy fail.
    @Test func neverReadsThroughASymlinkInATrustedFolder() throws {
        let dir = try makeDir()
        defer { try? fm.removeItem(at: dir) }
        let target = dir.appendingPathComponent("user-file.mov")
        try Data("private".utf8).write(to: target)
        try fm.createSymbolicLink(at: dir.appendingPathComponent("Wallpaper.mov"), withDestinationURL: target)
        let fifo = dir.appendingPathComponent("pipe.mov")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        let dest = dir.appendingPathComponent("private.mov")

        let folder = try TrustedDirectory(url: dir)
        for name in ["Wallpaper.mov", "pipe.mov", "missing.mov", ".."] {
            #expect(throws: (any Error).self) { try VerifiedFileCopy.copy(named: name, in: folder, to: dest) }
            #expect(!fm.fileExists(atPath: dest.path))
        }
    }

    /// The private copy of a deployed video must not fill the disk. The
    /// extension can keep appending to the file it owns, so the copy stops
    /// at the size the file had when it was opened.
    @Test func stopsWhenTheSourceGrowsWhileCopying() throws {
        let dir = try makeDir()
        defer { try? fm.removeItem(at: dir) }
        let source = dir.appendingPathComponent("Wallpaper.mov")
        try Data(repeating: 1, count: 1_000).write(to: source)
        let dest = dir.appendingPathComponent("private.mov")

        #expect(throws: VerifiedFileCopy.CopyError.sourceChangedSize) {
            try VerifiedFileCopy.copy(named: "Wallpaper.mov", in: TrustedDirectory(url: dir), to: dest) { _ in
                // Called after the open: grow the file under the copy.
                let handle = try? FileHandle(forWritingTo: source)
                _ = try? handle?.seekToEnd()
                try? handle?.write(contentsOf: Data(repeating: 2, count: 3_000_000))
                try? handle?.close()
                return .max
            }
        }
        #expect(!fm.fileExists(atPath: dest.path))
    }

    @Test func refusesToStartWithoutRoomForTheCopy() throws {
        let dir = try makeDir()
        defer { try? fm.removeItem(at: dir) }
        try Data(repeating: 1, count: 1_000).write(to: dir.appendingPathComponent("Wallpaper.mov"))
        let dest = dir.appendingPathComponent("private.mov")
        var asked: URL?

        #expect(throws: VerifiedFileCopy.CopyError.notEnoughSpace) {
            try VerifiedFileCopy.copy(named: "Wallpaper.mov", in: TrustedDirectory(url: dir), to: dest) { folder in
                asked = folder
                return 999
            }
        }
        #expect(asked?.standardizedFileURL == dir.standardizedFileURL)
        #expect(!fm.fileExists(atPath: dest.path))
    }

    @Test func measuresFreeSpaceOnTheDestinationVolume() throws {
        let dir = try makeDir()
        defer { try? fm.removeItem(at: dir) }
        let free = try #require(VerifiedFileCopy.availableSpace(in: dir))
        #expect(free > 0)
        #expect(VerifiedFileCopy.availableSpace(in: dir.appendingPathComponent("missing")) == nil)
    }
}
