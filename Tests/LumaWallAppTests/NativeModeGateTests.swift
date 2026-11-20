import Foundation
import LumaWallCore
import XCTest

@testable import LumaWall

@MainActor
final class NativeModeGateTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var root: URL!

    override func setUp() async throws {
        suiteName = "NativeModeGateTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    func testOffSettingPicksOverlayWithoutProbingTheSystem() {
        var probed = false
        let mode = WallpaperHostCapabilities.mode(nativeModeEnabled: false, forceOverlay: false) {
            probed = true
            return true
        }
        XCTAssertEqual(mode, .overlay)
        XCTAssertFalse(probed)
    }

    func testOnSettingPicksNativeWhenTheSystemSupportsIt() {
        XCTAssertEqual(WallpaperHostCapabilities.mode(nativeModeEnabled: true, forceOverlay: false) { true }, .native)
        XCTAssertEqual(WallpaperHostCapabilities.mode(nativeModeEnabled: true, forceOverlay: false) { false }, .overlay)
        XCTAssertEqual(WallpaperHostCapabilities.mode(nativeModeEnabled: true, forceOverlay: true) { true }, .overlay)
    }

    func testEngineWithNativeModeOffHasNoNativeHost() throws {
        let setting = NativeModeSetting(defaults: defaults) { true }
        setting.disable()
        let engine = WallpaperEngine(
            displays: DisplayCoordinator(),
            assignments: try AssignmentStore(rootURL: root),
            nativeSetting: setting
        )
        XCTAssertEqual(engine.mode, .overlay)
        XCTAssertFalse(engine.hasNativeHost)
        XCTAssertFalse(engine.nativeModeEnabled)
    }

    func testEngineMigratesANewInstallToOverlay() throws {
        let engine = WallpaperEngine(
            displays: DisplayCoordinator(),
            assignments: try AssignmentStore(rootURL: root),
            nativeSetting: NativeModeSetting(defaults: defaults) { false }
        )
        XCTAssertEqual(engine.mode, .overlay)
        XCTAssertFalse(engine.hasNativeHost)
        XCTAssertEqual(defaults.object(forKey: NativeModeSetting.enabledKey) as? Bool, false)
    }

    func testTurningNativeModeOffDropsTheNativeHost() async throws {
        let setting = NativeModeSetting(defaults: defaults) { false }
        let engine = WallpaperEngine(
            displays: DisplayCoordinator(),
            assignments: try AssignmentStore(rootURL: root),
            nativeSetting: setting
        )
        await engine.setNativeMode(enabled: false, library: [])
        XCTAssertEqual(engine.mode, .overlay)
        XCTAssertFalse(engine.hasNativeHost)
        XCTAssertFalse(setting.isEnabled)
    }
}
