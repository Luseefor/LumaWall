import XCTest

/// Every prefs notification re-read the file, both power sources, and every
/// renderer's policy (#14). The app posts one per occlusion update, so a
/// window drag sent bursts of them.
final class PrefsReloadTests: XCTestCase {
    func testUnchangedPrefsNeedNothing() {
        let prefs = WallpaperPrefsFile(occludedDisplays: [1])
        XCTAssertEqual(PrefsReload.between(prefs, prefs), .none)
    }

    func testOcclusionChangeAppliesPoliciesWithoutReadingPower() {
        let old = WallpaperPrefsFile(occludedDisplays: [1])
        let new = WallpaperPrefsFile(occludedDisplays: [1, 2])
        XCTAssertEqual(PrefsReload.between(old, new), .applyPolicies(refreshPower: false))
    }

    func testProfileChangeReadsPowerFirst() {
        // Battery Saver picked right after unplugging must see the battery.
        let old = WallpaperPrefsFile()
        let new = WallpaperPrefsFile(powerProfile: "batterySaver")
        XCTAssertEqual(PrefsReload.between(old, new), .applyPolicies(refreshPower: true))
    }

    func testABurstOfNotificationsSchedulesOneReload() {
        var coalescer = ReloadCoalescer()
        XCTAssertTrue(coalescer.request())
        XCTAssertFalse(coalescer.request())
        XCTAssertFalse(coalescer.request())
        coalescer.begin()
        // A write landing while the reload reads the file gets its own.
        XCTAssertTrue(coalescer.request())
    }

    func testDecodesAFileFromAnOlderApp() throws {
        let json = #"{"userPaused":true,"alwaysPauseDesktop":false,"pauseWhenOccluded":true,"desktopOccluded":false}"#
        let prefs = try JSONDecoder().decode(WallpaperPrefsFile.self, from: Data(json.utf8))
        XCTAssertEqual(prefs, WallpaperPrefsFile(userPaused: true, pauseWhenOccluded: true))
    }
}
