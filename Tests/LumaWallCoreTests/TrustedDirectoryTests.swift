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

    @Test func aSymlinkAboveTheFolderIsRefusedBelowATrustedAncestor() throws {
        // O_NOFOLLOW guards only the last component. A sandboxed process that
        // swaps its own Data/Documents for a symlink must not redirect the
        // app into a real folder elsewhere.
        let (root, victim, cleanup) = try makeTree()
        defer { cleanup() }
        let staging = victim.appendingPathComponent("copy-staging", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: root.appendingPathComponent("Documents"), withDestinationURL: victim)
        let path = root.appendingPathComponent("Documents/copy-staging", isDirectory: true)

        #expect(throws: (any Error).self) { try TrustedDirectory(url: path, below: root) }
        try fm.createDirectory(at: root.appendingPathComponent("Real/copy-staging"), withIntermediateDirectories: true)
        _ = try TrustedDirectory(url: root.appendingPathComponent("Real/copy-staging"), below: root)
        _ = try TrustedDirectory(url: root, below: root)
        #expect(throws: (any Error).self) { try TrustedDirectory(url: victim, below: root) }
    }

    @Test func readsAFileButNotThroughASymlink() throws {
        let (root, victim, cleanup) = try makeTree()
        defer { cleanup() }
        try Data("{}".utf8).write(to: root.appendingPathComponent("metadata.json"))
        try fm.createSymbolicLink(
            at: root.appendingPathComponent("linked.json"), withDestinationURL: victim.appendingPathComponent("precious.txt"))
        let dir = try TrustedDirectory(url: root)
        #expect(try dir.readFile(named: "metadata.json") == Data("{}".utf8))
        #expect(throws: (any Error).self) { try dir.readFile(named: "linked.json") }
        #expect(throws: (any Error).self) { try dir.readFile(named: "..") }
    }

    @Test func publishMovesAFolderIntoPlace() throws {
        let (root, _, cleanup) = try makeTree()
        defer { cleanup() }
        let staging = root.appendingPathComponent("staging/new", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("v2".utf8).write(to: staging.appendingPathComponent("a.mov"))
        let videos = root.appendingPathComponent("videos", isDirectory: true)
        try fm.createDirectory(at: videos, withIntermediateDirectories: true)

        try TrustedDirectory(url: root.appendingPathComponent("staging"))
            .publishItem(named: "new", into: TrustedDirectory(url: videos), as: "entry")
        #expect(try Data(contentsOf: videos.appendingPathComponent("entry/a.mov")) == Data("v2".utf8))
        #expect(!fm.fileExists(atPath: staging.path))
    }

    @Test func publishReplacesAnExistingFolderInOneStep() throws {
        let (root, _, cleanup) = try makeTree()
        defer { cleanup() }
        let staging = root.appendingPathComponent("staging/new", isDirectory: true)
        let old = root.appendingPathComponent("videos/entry", isDirectory: true)
        for dir in [staging, old] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        try Data("v2".utf8).write(to: staging.appendingPathComponent("a.mov"))
        try Data("v1".utf8).write(to: old.appendingPathComponent("old.mov"))

        try TrustedDirectory(url: root.appendingPathComponent("staging"))
            .publishItem(named: "new", into: TrustedDirectory(url: root.appendingPathComponent("videos")), as: "entry")
        #expect(try fm.contentsOfDirectory(atPath: old.path) == ["a.mov"])
        #expect(try fm.contentsOfDirectory(atPath: root.appendingPathComponent("staging").path).isEmpty)
    }

    @Test func publishOverASymlinkLeavesItsTargetAlone() throws {
        let (root, victim, cleanup) = try makeTree()
        defer { cleanup() }
        let staging = root.appendingPathComponent("staging/new", isDirectory: true)
        let videos = root.appendingPathComponent("videos", isDirectory: true)
        for dir in [staging, videos] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        try fm.createSymbolicLink(at: videos.appendingPathComponent("entry"), withDestinationURL: victim)

        try TrustedDirectory(url: root.appendingPathComponent("staging"))
            .publishItem(named: "new", into: TrustedDirectory(url: videos), as: "entry")
        #expect(fm.fileExists(atPath: victim.appendingPathComponent("precious.txt").path))
        #expect((try? fm.destinationOfSymbolicLink(atPath: videos.appendingPathComponent("entry").path)) == nil)
        #expect(try TrustedDirectory(url: videos).kind(ofItemNamed: "entry") == .directory)
    }

    @Test func removingAMissingItemThrowsNoSuchFile() throws {
        let (root, _, cleanup) = try makeTree()
        defer { cleanup() }
        #expect(throws: POSIXError(.ENOENT)) { try TrustedDirectory(url: root).removeItem(named: "gone") }
    }

    @Test func identityNamesTheFolderNotItsPath() throws {
        let (root, victim, cleanup) = try makeTree()
        defer { cleanup() }
        let folder = root.appendingPathComponent("staging", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let first = try TrustedDirectory(url: folder).identity()
        #expect(try TrustedDirectory(url: folder).identity() == first)
        #expect(try TrustedDirectory(url: victim).identity() != first)
        // A new folder at the same path is a different folder. The old one
        // stays alive so its inode can't be reused.
        try fm.moveItem(at: folder, to: root.appendingPathComponent("aside"))
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(try TrustedDirectory(url: folder).identity() != first)
    }

    @Test func renameMovesAnItemButNeverOverAnother() throws {
        let (root, _, cleanup) = try makeTree()
        defer { cleanup() }
        let dir = try TrustedDirectory(url: root)
        try fm.createDirectory(at: root.appendingPathComponent("a"), withIntermediateDirectories: false)
        try Data("x".utf8).write(to: root.appendingPathComponent("a/clip.mov"))
        try fm.createDirectory(at: root.appendingPathComponent("taken"), withIntermediateDirectories: false)

        try dir.renameItem(named: "a", to: ".a")
        #expect(fm.fileExists(atPath: root.appendingPathComponent(".a/clip.mov").path))
        #expect(throws: POSIXError.self) { try dir.renameItem(named: ".a", to: "taken") }
        #expect(fm.fileExists(atPath: root.appendingPathComponent(".a/clip.mov").path))
        #expect(throws: POSIXError.self) { try dir.renameItem(named: ".a", to: "../out") }
    }
}
