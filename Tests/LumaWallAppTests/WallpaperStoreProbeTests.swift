import Foundation
import XCTest
@testable import LumaWall

@MainActor
final class WallpaperStoreProbeTests: XCTestCase {
    private var storeURL: URL!

    override func setUp() async throws {
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("plist")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: storeURL)
    }

    private func writeStore(idleProvider: String, padding: Int = 0) throws {
        let root: [String: Any] = [
            "Idle": ["Content": ["Choices": [["Provider": idleProvider]]]],
            "Spaces": ["space": ["Padding": String(repeating: "x", count: padding)]],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
        try data.write(to: storeURL)
    }

    func testDetectsOurIdleChoice() throws {
        try writeStore(idleProvider: WallpaperHostCapabilities.extensionBundleID)
        XCTAssertTrue(WallpaperStoreProbe.screenSaverIsOurs(storeURL: storeURL))
    }

    func testUnchangedStoreIsParsedOnce() throws {
        // The system store holds every Space (hundreds of KB). Policy runs on
        // every power and workspace event, so re-parsing it each time showed
        // up as steady CPU in the idle controller.
        try writeStore(idleProvider: "com.apple.other")
        let before = WallpaperStoreProbe.parseCount
        XCTAssertFalse(WallpaperStoreProbe.screenSaverIsOurs(storeURL: storeURL))
        XCTAssertFalse(WallpaperStoreProbe.screenSaverIsOurs(storeURL: storeURL))
        XCTAssertFalse(WallpaperStoreProbe.screenSaverIsOurs(storeURL: storeURL))
        XCTAssertEqual(WallpaperStoreProbe.parseCount - before, 1)
    }

    func testChangedStoreIsReparsed() throws {
        try writeStore(idleProvider: "com.apple.other")
        XCTAssertFalse(WallpaperStoreProbe.screenSaverIsOurs(storeURL: storeURL))
        try writeStore(idleProvider: WallpaperHostCapabilities.extensionBundleID, padding: 64)
        XCTAssertTrue(WallpaperStoreProbe.screenSaverIsOurs(storeURL: storeURL))
    }

    func testMissingStoreIsNotOurs() {
        XCTAssertFalse(WallpaperStoreProbe.screenSaverIsOurs(storeURL: storeURL))
    }
}
