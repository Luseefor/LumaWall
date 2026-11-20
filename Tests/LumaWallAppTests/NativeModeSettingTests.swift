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

    private func store(provider: String) throws -> Data {
        let root: [String: Any] = [
            "Displays": ["DISPLAY-A": ["Desktop": ["Content": ["Choices": [["Provider": provider]]]]]]
        ]
        return try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
    }

    func testNativeUseNeedsABackupAndOurChoiceStillInTheStore() throws {
        let ours = try store(provider: WallpaperHostCapabilities.extensionBundleID)
        let apple = try store(provider: "com.apple.wallpaper.choice.image")
        XCTAssertTrue(NativeModeSetting.showsNativeUse(backupExists: true, store: ours))
        // A backup alone: the old app saved it, then the store write failed.
        XCTAssertFalse(NativeModeSetting.showsNativeUse(backupExists: true, store: apple))
        // Our choice alone: picked in System Settings, never written by the app.
        XCTAssertFalse(NativeModeSetting.showsNativeUse(backupExists: false, store: ours))
        XCTAssertFalse(NativeModeSetting.showsNativeUse(backupExists: true, store: nil))
    }

    func testTurningNativeModeOffWaitsForAPublishInProgress() {
        // A copy publish already past its native-mode check finished writing
        // into the extension's container after native mode was off.
        nonisolated(unsafe) let setting = setting()
        setting.enable()
        let finished = expectation(description: "disabled")
        let early = expectation(description: "disabled while a publish held the lock")
        early.isInverted = true
        NativeWallpaperDeployment.entryLock.lock()
        Thread.detachNewThread {
            setting.disable()
            early.fulfill()
            finished.fulfill()
        }
        wait(for: [early], timeout: 0.2)
        XCTAssertTrue(setting.isEnabled)
        NativeWallpaperDeployment.entryLock.unlock()
        wait(for: [finished], timeout: 5)
        XCTAssertFalse(setting.isEnabled)
    }
}
