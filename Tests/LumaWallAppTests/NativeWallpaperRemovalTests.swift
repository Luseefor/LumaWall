import Foundation
import XCTest

@testable import LumaWall

/// Removing a wallpaper must not be undone by a restore already running,
/// and must finish on the next launch when this one didn't.
final class NativeWallpaperRemovalTests: XCTestCase {
    private var root: URL!
    private var pendingFile: URL { root.appendingPathComponent("pending-removals.json") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func entry(_ id: String) -> NativeWallpaperDeployment.EntryInfo {
        .init(
            id: id, name: "x", filename: "Wallpaper.mov", duration: 5, fps: 30,
            resolution: CGSize(width: 1920, height: 1080), dateAdded: Date())
    }

    // MARK: Restore race

    func testARestoreLeavesOutAWallpaperRemovedWhileItCollected() {
        let kept = entry(UUID().uuidString)
        let removed = entry(UUID().uuidString)
        let batch = NativeWallpaperEngine.withoutRemoved([1: kept, 2: removed, 3: removed], removed: [removed.id])
        XCTAssertEqual(batch.map, [1: kept])
        XCTAssertEqual(batch.dropped, [2, 3])
    }

    func testARestoreWithNothingRemovedWritesTheWholeBatch() {
        let a = entry(UUID().uuidString)
        let b = entry(UUID().uuidString)
        let batch = NativeWallpaperEngine.withoutRemoved([1: a, 2: b], removed: [UUID().uuidString])
        XCTAssertEqual(batch.map, [1: a, 2: b])
        XCTAssertEqual(batch.dropped, [])
    }

    // MARK: Pending removals

    private typealias Pending = NativeWallpaperDeployment.PendingRemovals

    func testPendingRemovalsSurviveARelaunch() throws {
        let first = UUID().uuidString
        let second = UUID().uuidString
        let before = Pending(fileURL: pendingFile)
        try before.add(first)
        try before.add(second)
        before.markRowRemoved(second)
        before.remove(first)
        XCTAssertEqual(Pending(fileURL: pendingFile).stages, [second: .rowRemoved])
    }

    func testAnUnreadableListReadsAsEmpty() throws {
        try Data("not json".utf8).write(to: pendingFile)
        XCTAssertEqual(Pending(fileURL: pendingFile).stages, [:])
    }

    func testARemovalThatCantBeRecordedIsRefused() {
        // A folder where the list goes: the write fails, and the caller must
        // not remove the library row.
        let blocked = Pending(fileURL: root.appendingPathComponent("missing/pending-removals.json"))
        XCTAssertThrowsError(try blocked.add(UUID().uuidString))
    }

    @MainActor
    func testTheNextLaunchFinishesWhatThePreviousRunLeft() async throws {
        let rowGone = UUID().uuidString
        let requested = UUID().uuidString
        let kept = UUID().uuidString
        let pending = Pending(fileURL: pendingFile)
        for id in [rowGone, requested, kept] { try pending.add(id) }
        pending.markRowRemoved(rowGone)
        var deleted: [String] = []
        await NativeWallpaperDeployment.finishPendingRemovals(
            libraryIDs: [kept, UUID().uuidString], pending: pending, removedThisRun: { [] }
        ) { deleted.append($0) }
        // The library still lists `kept`, so its removal never happened.
        XCTAssertEqual(Set(deleted), [rowGone, requested])
        XCTAssertEqual(pending.stages, [:])
    }

    @MainActor
    func testAnEmptyLibraryOnlyFinishesRemovalsWhoseRowIsKnownGone() async throws {
        // An empty library is also what an unreadable index looks like, so a
        // removal that may not have reached the library waits.
        let rowGone = UUID().uuidString
        let requested = UUID().uuidString
        let pending = Pending(fileURL: pendingFile)
        for id in [rowGone, requested] { try pending.add(id) }
        pending.markRowRemoved(rowGone)
        var deleted: [String] = []
        await NativeWallpaperDeployment.finishPendingRemovals(libraryIDs: [], pending: pending, removedThisRun: { [] }) {
            deleted.append($0)
        }
        XCTAssertEqual(deleted, [rowGone])
        XCTAssertEqual(pending.stages, [requested: .requested])
    }

    @MainActor
    func testARemovalStartedThisRunIsLeftToIt() async throws {
        // The library snapshot still lists it, but a removal running now
        // recorded it again; clearing the record would lose its retry.
        let id = UUID().uuidString
        let pending = Pending(fileURL: pendingFile)
        try pending.add(id)
        var deleted: [String] = []
        await NativeWallpaperDeployment.finishPendingRemovals(libraryIDs: [id], pending: pending, removedThisRun: { [id] }) {
            deleted.append($0)
        }
        XCTAssertEqual(deleted, [])
        XCTAssertEqual(pending.stages, [id: .requested])
    }

    @MainActor
    func testARemovalThatFailsAgainStaysPending() async throws {
        let gone = UUID().uuidString
        let pending = Pending(fileURL: pendingFile)
        try pending.add(gone)
        pending.markRowRemoved(gone)
        await NativeWallpaperDeployment.finishPendingRemovals(libraryIDs: [], pending: pending, removedThisRun: { [] }) { _ in
            throw CocoaError(.fileWriteNoPermission)
        }
        XCTAssertEqual(pending.stages, [gone: .rowRemoved])
    }
}
