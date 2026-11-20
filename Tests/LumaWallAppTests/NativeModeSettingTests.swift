import Foundation
import XCTest

@testable import LumaWall

final class NativeModeSettingTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        suiteName = "NativeModeSettingTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func setting(usedNativeBefore: Bool = false) -> NativeModeSetting {
        NativeModeSetting(defaults: defaults, usedNativeBefore: { usedNativeBefore })
    }

    func testNewInstallStartsInOverlayMode() {
        let setting = setting()
        setting.migrateIfNeeded()
        XCTAssertFalse(setting.isEnabled)
        XCTAssertFalse(setting.needsDisclosure)
    }

    func testExistingNativeUserKeepsNativeModeAndSeesTheDisclosureOnce() {
        let setting = setting(usedNativeBefore: true)
        setting.migrateIfNeeded()
        XCTAssertTrue(setting.isEnabled)
        XCTAssertTrue(setting.needsDisclosure)

        setting.acknowledgeDisclosure()
        XCTAssertTrue(setting.isEnabled)
        XCTAssertFalse(setting.needsDisclosure)
    }

    func testMigrationDoesNotOverrideAStoredChoice() {
        setting().disable()
        let later = setting(usedNativeBefore: true)
        later.migrateIfNeeded()
        XCTAssertFalse(later.isEnabled)
    }

    func testMigrationRunsOnlyOnce() {
        setting().migrateIfNeeded()
        let later = setting(usedNativeBefore: true)
        later.migrateIfNeeded()
        XCTAssertFalse(later.isEnabled)
    }

    func testEnablingAfterConfirmationNeedsNoSecondDisclosure() {
        let setting = setting()
        setting.migrateIfNeeded()
        setting.enable()
        XCTAssertTrue(setting.isEnabled)
        XCTAssertFalse(setting.needsDisclosure)
    }

    func testUnmigratedSettingIsOff() {
        XCTAssertFalse(setting(usedNativeBefore: true).isEnabled)
    }

    func testDisablingTurnsNativeModeOff() {
        let setting = setting(usedNativeBefore: true)
        setting.migrateIfNeeded()
        setting.disable()
        XCTAssertFalse(setting.isEnabled)
        XCTAssertFalse(setting.needsDisclosure)
    }
}
