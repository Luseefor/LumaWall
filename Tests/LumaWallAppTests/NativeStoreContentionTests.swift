import Foundation
import XCTest

@testable import LumaWall

/// WallpaperAgent rewrites its store for a second or so after a display
/// wakes or joins. A restore that lost to it moved every display to Safe
/// mode, though restoring again a moment later would have worked.
@MainActor
final class NativeStoreContentionTests: XCTestCase {
    func testABusyStoreIsRestoredAgainAfterGrowingWaits() {
        XCTAssertEqual(WallpaperEngine.busyStoreRetryDelay(afterAttempt: 0), Duration.seconds(1))
        XCTAssertEqual(WallpaperEngine.busyStoreRetryDelay(afterAttempt: 1), Duration.seconds(2))
        XCTAssertEqual(WallpaperEngine.busyStoreRetryDelay(afterAttempt: 2), Duration.seconds(4))
    }

    func testAfterTheLastRetryTheDisplaysGoToTheOverlay() {
        XCTAssertNil(WallpaperEngine.busyStoreRetryDelay(afterAttempt: 3))
    }
}
