import Foundation
import XCTest

@testable import LumaWall

/// Removing a wallpaper must not be undone by a restore already running,
/// and must finish on the next launch when this one didn't.
final class NativeWallpaperRemovalTests: XCTestCase {
    private var root: URL!

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
}
