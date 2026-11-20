import Foundation
import XCTest

@testable import LumaWall

/// Library scans no longer delete anything (#81), so the app sweeps entry
/// folders older versions or interrupted deploys left in `videos/`.
final class DeploymentSweepTests: XCTestCase {
    private var root: URL!
    private var videos: URL { root.appendingPathComponent("videos") }
    // Not "TemporaryItems": the app can't open a folder by that name.
    private var temporaryItems: URL { root.appendingPathComponent("Temporary") }
    private var journal: URL { root.appendingPathComponent("deploy-staging.json") }
    private let now = Date()
    private var old: Date { now.addingTimeInterval(-2 * 3600) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for dir in [videos, temporaryItems] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// An entry folder holding `files`, dated `modified`. "metadata.json"
    /// gets a valid entry for `id` naming "Wallpaper.mov".
    @discardableResult
    private func entry(_ id: String, files: [String], modified: Date? = nil) throws -> URL {
        let dir = videos.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in files {
            let data =
                name == "metadata.json"
                ? try JSONEncoder().encode(
                    NativeWallpaperDeployment.EntryInfo(
                        id: id, name: "W", filename: "Wallpaper.mov", duration: 5, fps: 30,
                        resolution: CGSize(width: 1920, height: 1080), dateAdded: now))
                : Data("x".utf8)
            try data.write(to: dir.appendingPathComponent(name))
        }
        try FileManager.default.setAttributes([.modificationDate: modified ?? old], ofItemAtPath: dir.path)
        return dir
    }

    /// A folder like the one `makeStagingFolder` returns, holding one
    /// staged entry, listed in the journal unless `journaled` is false.
    @discardableResult
    private func stagingFolder(_ name: String, modified: Date, journaled: Bool = true) throws -> URL {
        let fm = FileManager.default
        let folder = temporaryItems.appendingPathComponent(name, isDirectory: true)
        let staged = folder.appendingPathComponent("\(UUID().uuidString).\(UUID().uuidString)")
        try fm.createDirectory(at: staged, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: staged.appendingPathComponent("Wallpaper.mov"))
        for url in [staged, folder] { try fm.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
        if journaled { StagingJournal(fileURL: journal).add(folder) }
        return folder
    }

    private func sweep(referenced: Set<String>? = [], activeStaging: Set<URL> = []) -> NativeWallpaperDeployment.SweepResult {
        NativeWallpaperDeployment.sweepAbandonedEntries(
            referenced: referenced, videosFolderURL: videos, trustedAncestor: root,
            stagingJournalURL: journal, activeStaging: activeStaging, now: now)
    }

    private var journaled: [String] { StagingJournal(fileURL: journal).folders.map(\.lastPathComponent) }

    private func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    func testAnAbandonedEntryIsRemoved() throws {
        let empty = try entry(UUID().uuidString, files: [])
        let thumbnailOnly = try entry(UUID().uuidString, files: ["thumbnail.jpg"])
        let metadataWithoutVideo = try entry(UUID().uuidString, files: ["metadata.json", "thumbnail.jpg"])

        let result = sweep()
        for dir in [empty, thumbnailOnly, metadataWithoutVideo] {
            XCTAssertFalse(exists(dir), dir.lastPathComponent)
        }
        XCTAssertEqual(result.entries.count, 3)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: videos.path), [])
    }

    func testAValidPublishedEntryIsKept() throws {
        let dir = try entry(UUID().uuidString, files: ["metadata.json", "Wallpaper.mov", "thumbnail.jpg"])
        XCTAssertEqual(sweep().entries, [])
        XCTAssertTrue(exists(dir.appendingPathComponent("Wallpaper.mov")))
    }

    func testAFolderHoldingAVideoIsKept() throws {
        // The extension lists a bare video, and its legacy migration moves
        // a user's only copy into the folder before writing metadata.
        let bare = try entry(UUID().uuidString, files: ["wallpaper.MP4"])
        let quickTime = try entry(UUID().uuidString, files: ["metadata.json", "Wallpaper.qt"])
        let unknown = try entry(UUID().uuidString, files: ["thumbnail.jpg", "notes"])
        let other = UUID().uuidString
        let mismatched = try entry(UUID().uuidString, files: ["Wallpaper.mov"])
        try FileManager.default.copyItem(
            at: try entry(other, files: ["metadata.json", "Wallpaper.mov"]).appendingPathComponent("metadata.json"),
            to: mismatched.appendingPathComponent("metadata.json"))
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: mismatched.path)
        XCTAssertEqual(sweep().entries, [])
        XCTAssertTrue(exists(bare.appendingPathComponent("wallpaper.MP4")))
        XCTAssertTrue(exists(mismatched.appendingPathComponent("Wallpaper.mov")))
        XCTAssertTrue(exists(quickTime.appendingPathComponent("Wallpaper.qt")))
        XCTAssertTrue(exists(unknown.appendingPathComponent("notes")))
    }

    func testAReferenceMatchesAFolderInAnyCase() throws {
        let id = UUID().uuidString
        let dir = try entry(id.lowercased(), files: ["thumbnail.jpg"])
        XCTAssertEqual(sweep(referenced: [id]).entries, [])
        XCTAssertTrue(exists(dir))
    }

    func testAFolderHoldingASymlinkIsKeptAndItsTargetUntouched() throws {
        let fm = FileManager.default
        let victim = root.appendingPathComponent("movie.mov")
        try Data("keep".utf8).write(to: victim)
        let dir = try entry(UUID().uuidString, files: ["metadata.json"])
        try fm.createSymbolicLink(at: dir.appendingPathComponent("Wallpaper.mov"), withDestinationURL: victim)
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: dir.path)
        XCTAssertEqual(sweep().entries, [])
        XCTAssertTrue(exists(dir.appendingPathComponent("Wallpaper.mov")))
        XCTAssertTrue(exists(victim))
    }

    func testAFolderThatCannotBeListedIsKept() throws {
        let fm = FileManager.default
        let dir = try entry(UUID().uuidString, files: ["thumbnail.jpg"])
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dir.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        XCTAssertEqual(sweep().entries, [])
        XCTAssertTrue(exists(dir))
    }

    func testAFolderLeftAsideByAStoppedSweepIsFinished() throws {
        let fm = FileManager.default
        func aside(_ files: [String]) throws -> (id: String, url: URL) {
            let id = UUID().uuidString.lowercased()
            let url = videos.appendingPathComponent(".sweep-" + id)
            try fm.moveItem(at: try entry(id, files: files), to: url)
            return (id, url)
        }
        let gainedVideo = try aside(["thumbnail.jpg", "wallpaper.mov"])
        let bookkeeping = try aside(["thumbnail.jpg"])
        let referenced = try aside(["metadata.json"])

        XCTAssertEqual(sweep(referenced: [referenced.id.uppercased()]).entries, [bookkeeping.id])
        XCTAssertTrue(exists(videos.appendingPathComponent(gainedVideo.id).appendingPathComponent("wallpaper.mov")))
        XCTAssertTrue(exists(videos.appendingPathComponent(referenced.id).appendingPathComponent("metadata.json")))
        for leftover in [gainedVideo, bookkeeping, referenced] { XCTAssertFalse(exists(leftover.url)) }
    }

    func testAReferencedEntryIsKept() throws {
        let id = UUID().uuidString
        let dir = try entry(id, files: ["thumbnail.jpg"])
        XCTAssertEqual(sweep(referenced: [id]).entries, [])
        XCTAssertTrue(exists(dir.appendingPathComponent("thumbnail.jpg")))
    }

    func testARecentEntryIsKept() throws {
        // The extension's legacy migration builds an entry in place.
        let dir = try entry(UUID().uuidString, files: ["metadata.json"], modified: now.addingTimeInterval(-60))
        XCTAssertEqual(sweep().entries, [])
        XCTAssertTrue(exists(dir))
    }

    func testASymlinkedEntryIsNotFollowed() throws {
        let fm = FileManager.default
        let victim = root.appendingPathComponent("Documents", isDirectory: true)
        try fm.createDirectory(at: victim, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: victim.appendingPathComponent("thesis.pages"))
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: victim.path)
        let link = videos.appendingPathComponent(UUID().uuidString)
        try fm.createSymbolicLink(at: link, withDestinationURL: victim)
        // Old enough to sweep, so only the symlink check keeps it.
        var times = [
            timespec(tv_sec: Int(old.timeIntervalSince1970), tv_nsec: 0), timespec(tv_sec: Int(old.timeIntervalSince1970), tv_nsec: 0),
        ]
        XCTAssertEqual(utimensat(AT_FDCWD, link.path, &times, AT_SYMLINK_NOFOLLOW), 0)

        XCTAssertEqual(sweep().entries, [])
        XCTAssertTrue(exists(victim.appendingPathComponent("thesis.pages")))
        XCTAssertNotNil(try? fm.destinationOfSymbolicLink(atPath: link.path))
    }

    func testOnlyEntryFoldersAreTouched() throws {
        let fm = FileManager.default
        let notAnEntry = videos.appendingPathComponent("Wallpapers", isDirectory: true)
        try fm.createDirectory(at: notAnEntry, withIntermediateDirectories: true)
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: notAnEntry.path)
        let file = videos.appendingPathComponent(UUID().uuidString)
        try Data("x".utf8).write(to: file)
        _ = sweep()
        XCTAssertTrue(exists(notAnEntry))
        XCTAssertTrue(exists(file))
    }

    func testASymlinkedVideosFolderIsNotSwept() throws {
        let fm = FileManager.default
        let real = root.appendingPathComponent("elsewhere", isDirectory: true)
        try fm.moveItem(at: videos, to: real)
        try fm.createSymbolicLink(at: videos, withDestinationURL: real)
        let id = UUID().uuidString
        let dir = real.appendingPathComponent(id)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: dir.path)
        XCTAssertEqual(sweep().entries, [])
        XCTAssertTrue(exists(dir))
    }

    func testAnUntrustedLibraryStillCleansStagingButKeepsEntryFolders() throws {
        // An empty library (or a lost index) skipped the whole sweep, so
        // staging a crash left stayed until a wallpaper was added.
        let dir = try entry(UUID().uuidString, files: ["thumbnail.jpg"])
        let stale = try stagingFolder("NSIRD_LumaWall_old123", modified: old)
        let result = sweep(referenced: nil)
        XCTAssertEqual(result.entries, [])
        XCTAssertTrue(exists(dir))
        XCTAssertEqual(result.stagingFolders, ["NSIRD_LumaWall_old123"])
        XCTAssertFalse(exists(stale))
    }

    func testAFolderSkippedForItsAgeAsksForARetryWhenItIsOldEnough() throws {
        // A folder skipped as too new waited for the next deploy or launch.
        XCTAssertNil(sweep().retryAfter)
        try entry(UUID().uuidString, files: ["metadata.json"], modified: now.addingTimeInterval(-600))
        let entryWait = try XCTUnwrap(sweep().retryAfter)
        XCTAssertEqual(entryWait, 3000, accuracy: 1)
        try stagingFolder("NSIRD_LumaWall_new123", modified: now.addingTimeInterval(-3000))
        let wait = try XCTUnwrap(sweep().retryAfter)
        XCTAssertEqual(wait, 600, accuracy: 1)
    }

    func testAnEarlierRetryReplacesAPendingLaterOne() {
        // A pending timer kept its own deadline, so a folder due sooner
        // waited for the later one.
        var retry = SweepRetry()
        XCTAssertTrue(retry.replaces(now.addingTimeInterval(3300)))
        XCTAssertFalse(retry.replaces(now.addingTimeInterval(3400)))
        XCTAssertTrue(retry.replaces(now.addingTimeInterval(60)))
        XCTAssertEqual(retry.deadline, now.addingTimeInterval(60))
        retry.deadline = nil
        XCTAssertTrue(retry.replaces(now.addingTimeInterval(3400)))
    }

    func testARecentFolderHoldingAVideoAsksForNoRetry() throws {
        try entry(UUID().uuidString, files: ["Wallpaper.mov"], modified: now.addingTimeInterval(-60))
        XCTAssertNil(sweep().retryAfter)
        XCTAssertNil(sweep(referenced: nil).retryAfter)
    }

    func testOldStagingIsRemovedAndFreshStagingKept() throws {
        let stale = try stagingFolder("NSIRD_LumaWall_old123", modified: old)
        let fresh = try stagingFolder("NSIRD_LumaWall_new123", modified: now.addingTimeInterval(-60))
        let result = sweep()
        XCTAssertFalse(exists(stale))
        XCTAssertTrue(exists(fresh))
        XCTAssertEqual(result.stagingFolders, ["NSIRD_LumaWall_old123"])
        XCTAssertEqual(journaled, ["NSIRD_LumaWall_new123"])
    }

    func testStagingOfARunningDeployIsKept() throws {
        let running = try stagingFolder("NSIRD_LumaWall_slow99", modified: old)
        _ = sweep(activeStaging: [running])
        XCTAssertTrue(exists(running))
        XCTAssertEqual(journaled, ["NSIRD_LumaWall_slow99"])
    }

    func testAnEmptyStagingFolderFromACrashIsRemoved() throws {
        let fm = FileManager.default
        let folder = temporaryItems.appendingPathComponent("NSIRD_LumaWall_crash", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: folder.path)
        StagingJournal(fileURL: journal).add(folder)
        XCTAssertEqual(sweep().stagingFolders, ["NSIRD_LumaWall_crash"])
        XCTAssertFalse(exists(folder))
    }

    func testOnlyJournaledStagingOfStagedEntriesIsRemoved() throws {
        let fm = FileManager.default
        let unlisted = try stagingFolder("NSIRD_LumaWall_other", modified: old, journaled: false)
        let notStaging = try stagingFolder("Downloads", modified: old)
        // A folder holding a file, not a staged entry, is left alone.
        let odd = temporaryItems.appendingPathComponent("NSIRD_LumaWall_odd", isDirectory: true)
        try fm.createDirectory(at: odd, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: odd.appendingPathComponent("clip.mov"))
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: odd.path)
        StagingJournal(fileURL: journal).add(odd)
        XCTAssertEqual(sweep().stagingFolders, [])
        for url in [unlisted, notStaging, odd] { XCTAssertTrue(exists(url), url.lastPathComponent) }
        XCTAssertEqual(journaled, ["NSIRD_LumaWall_odd"])
    }

    func testStagingThatIsASymlinkIsNotFollowed() throws {
        let fm = FileManager.default
        // Journaled as a real folder, then replaced by a symlink to another.
        let link = try stagingFolder("NSIRD_LumaWall_link", modified: old)
        try fm.moveItem(at: link, to: temporaryItems.appendingPathComponent("moved"))
        let victim = try stagingFolder("victim", modified: old, journaled: false)
        try fm.createSymbolicLink(at: link, withDestinationURL: victim)
        XCTAssertEqual(sweep().stagingFolders, [])
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: victim.path).count, 1)
        XCTAssertTrue(exists(link))
        XCTAssertEqual(journaled, [])
    }

    func testDeployStagingIsJournaledUntilItEnds() throws {
        let folder = temporaryItems.appendingPathComponent("NSIRD_LumaWall_live", isDirectory: true)
        NativeWallpaperDeployment.beginStaging(folder, journalURL: journal)
        XCTAssertTrue(NativeWallpaperDeployment.activeStagingFolders.contains(folder))
        XCTAssertEqual(journaled, ["NSIRD_LumaWall_live"])
        NativeWallpaperDeployment.endStaging(folder, deleted: true, journalURL: journal)
        XCTAssertFalse(NativeWallpaperDeployment.activeStagingFolders.contains(folder))
        XCTAssertEqual(journaled, [])
    }

    func testStagingADeployCouldNotDeleteStaysJournaled() throws {
        let folder = try stagingFolder("NSIRD_LumaWall_stuck", modified: old, journaled: false)
        NativeWallpaperDeployment.beginStaging(folder, journalURL: journal)
        NativeWallpaperDeployment.endStaging(folder, deleted: false, journalURL: journal)
        XCTAssertFalse(NativeWallpaperDeployment.activeStagingFolders.contains(folder))
        XCTAssertEqual(sweep().stagingFolders, ["NSIRD_LumaWall_stuck"])
    }

    func testAJournaledPathNowNamingAnotherFolderIsNotSwept() throws {
        let fm = FileManager.default
        let folder = try stagingFolder("NSIRD_LumaWall_reused", modified: old)
        // Kept alive, so the new folder can't reuse its inode.
        try fm.moveItem(at: folder, to: temporaryItems.appendingPathComponent("original"))
        try stagingFolder("NSIRD_LumaWall_reused", modified: old, journaled: false)
        XCTAssertEqual(sweep().stagingFolders, [])
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: folder.path).count, 1)
        XCTAssertEqual(journaled, [])
    }

    func testARealStagingFolderCanBeSwept() throws {
        // The system's TemporaryItems can't be opened from the app; the
        // folder has to go without opening its parent.
        let fm = FileManager.default
        let folder = try NativeWallpaperDeployment.makeStagingFolder(appropriateFor: videos)
        defer { try? fm.removeItem(at: folder) }
        let staged = folder.appendingPathComponent("\(UUID().uuidString).\(UUID().uuidString)")
        try fm.createDirectory(at: staged, withIntermediateDirectories: false)
        try Data("x".utf8).write(to: staged.appendingPathComponent("Wallpaper.mov"))
        for url in [staged, folder] { try fm.setAttributes([.modificationDate: old], ofItemAtPath: url.path) }
        StagingJournal(fileURL: journal).add(folder)
        XCTAssertEqual(sweep().stagingFolders, [folder.lastPathComponent])
        XCTAssertFalse(exists(folder))
    }
}
