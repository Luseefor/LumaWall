import LumaWallCore
import XCTest
@testable import LumaWall

final class WallpaperEngineTests: XCTestCase {
    @MainActor
    func testSurfaceRecoverySchedulesNothingWithoutOverlaySessions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = OverlayWallpaperEngine(displays: DisplayCoordinator(),
                                            assignments: try AssignmentStore(rootURL: root))
        engine.scheduleSurfaceRecovery()
        XCTAssertEqual(engine.pendingRecoveryPassCount, 0)
    }
}
