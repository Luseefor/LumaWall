import Foundation
import LumaWallCore
import Testing

/// Deletes under a LumaWall folder must stay inside it even when an attacker
/// swaps a folder for a symlink. Each test plants a symlink to a "victim"
/// folder outside the root and checks the victim's files survive.
struct TrustedDirectoryTests {
    private let fm = FileManager.default

    private func makeTree() throws -> (root: URL, victim: URL, cleanup: () -> Void) {
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = base.appendingPathComponent("root", isDirectory: true)
        let victim = base.appendingPathComponent("victim", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: victim, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: victim.appendingPathComponent("precious.txt"))
        return (root, victim, { try? FileManager.default.removeItem(at: base) })
    }

    @Test func removesANestedTree() throws {
        let (root, _, cleanup) = try makeTree()
        defer { cleanup() }
        let entry = root.appendingPathComponent("entry/inner", isDirectory: true)
        try fm.createDirectory(at: entry, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: entry.appendingPathComponent("a.mov"))
        try Data("x".utf8).write(to: root.appendingPathComponent("entry/b.mov"))

        try TrustedDirectory(url: root).removeItem(named: "entry")
        #expect(!fm.fileExists(atPath: root.appendingPathComponent("entry").path))
        #expect(fm.fileExists(atPath: root.path))
    }

    @Test func removingASymlinkedFolderRemovesOnlyTheLink() throws {
        let (root, victim, cleanup) = try makeTree()
        defer { cleanup() }
        let link = root.appendingPathComponent("entry")
        try fm.createSymbolicLink(at: link, withDestinationURL: victim)

        try TrustedDirectory(url: root).removeItem(named: "entry")
        #expect((try? fm.destinationOfSymbolicLink(atPath: link.path)) == nil)
        #expect(fm.fileExists(atPath: victim.appendingPathComponent("precious.txt").path))
    }

    @Test func aSymlinkInsideTheTreeIsNotFollowed() throws {
        let (root, victim, cleanup) = try makeTree()
        defer { cleanup() }
        let entry = root.appendingPathComponent("entry", isDirectory: true)
        try fm.createDirectory(at: entry, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: entry.appendingPathComponent("sub"), withDestinationURL: victim)

        try TrustedDirectory(url: root).removeItem(named: "entry")
        #expect(!fm.fileExists(atPath: entry.path))
        #expect(fm.fileExists(atPath: victim.appendingPathComponent("precious.txt").path))
    }

    @Test func aSymlinkedSubdirectoryIsRefused() throws {
        let (root, victim, cleanup) = try makeTree()
        defer { cleanup() }
        try fm.createSymbolicLink(at: root.appendingPathComponent("staging"), withDestinationURL: victim)

        #expect(throws: (any Error).self) { try TrustedDirectory(url: root).subdirectory("staging") }
        #expect(throws: (any Error).self) { try TrustedDirectory(url: root.appendingPathComponent("staging")) }
    }

    @Test func unsafeNamesAreRefused() throws {
        let (root, victim, cleanup) = try makeTree()
        defer { cleanup() }
        let dir = try TrustedDirectory(url: root)
        for name in ["..", ".", "", "../victim", "a/b"] {
            #expect(throws: (any Error).self) { try dir.removeItem(named: name) }
            #expect(throws: (any Error).self) { try dir.subdirectory(name) }
        }
        #expect(fm.fileExists(atPath: victim.appendingPathComponent("precious.txt").path))
    }

    @Test func removeFileRefusesFoldersAndListsKinds() throws {
        let (root, victim, cleanup) = try makeTree()
        defer { cleanup() }
        try fm.createDirectory(at: root.appendingPathComponent("folder"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appendingPathComponent("file.mov"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("link.mov"), withDestinationURL: victim)

        let dir = try TrustedDirectory(url: root)
        let kinds = Dictionary(uniqueKeysWithValues: try dir.entries().map { ($0.name, $0.kind) })
        #expect(kinds == ["folder": .directory, "file.mov": .file, "link.mov": .symlink])

        #expect(throws: (any Error).self) { try dir.removeFile(named: "folder") }
        try dir.removeFile(named: "file.mov")
        try dir.removeFile(named: "link.mov")
        #expect(try dir.entries().map(\.name) == ["folder"])
        #expect(fm.fileExists(atPath: victim.appendingPathComponent("precious.txt").path))
    }

    @Test func removingAMissingItemThrowsNoSuchFile() throws {
        let (root, _, cleanup) = try makeTree()
        defer { cleanup() }
        #expect(throws: POSIXError(.ENOENT)) { try TrustedDirectory(url: root).removeItem(named: "gone") }
    }
}
