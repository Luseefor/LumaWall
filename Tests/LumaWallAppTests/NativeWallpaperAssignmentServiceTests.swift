import Foundation
import XCTest

@testable import LumaWall

/// The wallpaper store, its backup and WallpaperAgent, in memory.
@MainActor
final class FakeSystemWallpaperFiles: SystemWallpaperFiles {
    var store: Data?
    var backup: Data?
    var storeWrites = 0
    var backupWrites = 0
    var agentRestarts = 0
    var readError: (any Error)?

    init(store: [String: Any]) {
        self.store = try? PropertyListSerialization.data(fromPropertyList: store, format: .binary, options: 0)
    }

    func readStore() throws -> Data {
        if let readError { throw readError }
        guard let store else { throw CocoaError(.fileReadNoSuchFile) }
        return store
    }

    func writeStore(_ data: Data) throws {
        storeWrites += 1
        store = data
    }

    func readBackup() throws -> Data? { backup }

    func writeBackup(_ data: Data) throws {
        backupWrites += 1
        backup = data
    }

    func restartWallpaperAgent() { agentRestarts += 1 }

    func storeRoot() throws -> [String: Any] {
        try XCTUnwrap(PropertyListSerialization.propertyList(from: readStore(), format: nil) as? [String: Any])
    }
}

@MainActor
final class NativeWallpaperAssignmentServiceTests: XCTestCase {
    private let ours = WallpaperHostCapabilities.extensionBundleID
    private let entry = NativeWallpaperDeployment.EntryInfo(
        id: "ENTRY-A", name: "Waves", filename: "Wallpaper.mov", duration: 10, fps: 30,
        resolution: CGSize(width: 3840, height: 2160), dateAdded: Date(timeIntervalSince1970: 0)
    )

    private func surface(provider: String, config: String) -> [String: Any] {
        ["Content": ["Choices": [["Provider": provider, "Configuration": Data(config.utf8)]], "Shuffle": "$null"]]
    }

    /// Two displays, both on the user's own Apple wallpaper.
    private func appleStore() -> [String: Any] {
        [
            "Displays": [
                "DISPLAY-A": ["Desktop": surface(provider: "com.apple.wallpaper.choice.image", config: "beach")],
                "DISPLAY-B": ["Desktop": surface(provider: "com.apple.wallpaper.choice.image", config: "forest")],
            ]
        ]
    }

    private func provider(_ root: [String: Any], _ display: String) -> String? {
        let displays = root["Displays"] as? [String: Any]
        let desktop = (displays?[display] as? [String: Any])?["Desktop"] as? [String: Any]
        let choices = (desktop?["Content"] as? [String: Any])?["Choices"] as? [[String: Any]]
        return choices?.first?["Provider"] as? String
    }

    private func config(_ root: [String: Any], _ display: String) -> String? {
        let displays = root["Displays"] as? [String: Any]
        let desktop = (displays?[display] as? [String: Any])?["Desktop"] as? [String: Any]
        let choices = (desktop?["Content"] as? [String: Any])?["Choices"] as? [[String: Any]]
        return (choices?.first?["Configuration"] as? Data).map { String(decoding: $0, as: UTF8.self) }
    }

    private let library = URL(fileURLWithPath: "/Users/someone/Library/Application Support/LumaWall", isDirectory: true)

    private func service(_ files: FakeSystemWallpaperFiles, nativeModeEnabled: Bool) -> NativeWallpaperAssignmentService {
        NativeWallpaperAssignmentService(files: files, ownedFolders: [library], nativeModeEnabled: { nativeModeEnabled })
    }

    /// What the overlay's `setDesktopImageURL` leaves in the store: an Apple
    /// image choice pointing at a LumaWall poster.
    private func posterSurface() -> [String: Any] {
        let poster = library.appendingPathComponent("WALLPAPER-1/poster.jpg").absoluteString
        return [
            "Content": [
                "Choices": [["Provider": "com.apple.wallpaper.choice.image", "Files": [["relative": poster]]]],
                "Shuffle": "$null",
            ]
        ]
    }

    // MARK: Native mode off

    func testAssignmentWithNativeModeOffTouchesNothing() throws {
        let files = FakeSystemWallpaperFiles(store: appleStore())
        let before = files.store
        XCTAssertThrowsError(try service(files, nativeModeEnabled: false).apply(assignments: ["DISPLAY-A": entry])) {
            guard case NativeWallpaperAssignmentService.AssignmentError.nativeModeOff = $0 else {
                return XCTFail("unexpected error \($0)")
            }
        }
        XCTAssertEqual(files.storeWrites, 0)
        XCTAssertEqual(files.backupWrites, 0)
        XCTAssertEqual(files.agentRestarts, 0)
        XCTAssertEqual(files.store, before)
    }

    func testLockScreenAssignmentWithNativeModeOffTouchesNothing() throws {
        let files = FakeSystemWallpaperFiles(store: appleStore())
        XCTAssertThrowsError(try service(files, nativeModeEnabled: false).applyLockScreen(entry: entry))
        XCTAssertEqual(files.storeWrites, 0)
        XCTAssertEqual(files.backupWrites, 0)
        XCTAssertEqual(files.agentRestarts, 0)
    }

    // MARK: Native mode on

    func testAssignmentWritesOurChoiceBacksUpAndRestartsTheAgentOnce() throws {
        let files = FakeSystemWallpaperFiles(store: appleStore())
        try service(files, nativeModeEnabled: true).apply(assignments: ["DISPLAY-A": entry])
        let root = try files.storeRoot()
        XCTAssertEqual(provider(root, "DISPLAY-A"), ours)
        XCTAssertEqual(config(root, "DISPLAY-B"), "forest")
        XCTAssertEqual(files.backupWrites, 1)
        XCTAssertEqual(files.agentRestarts, 1)
    }

    func testAssignsTheKnownDisplaysAndReportsTheMissingOnes() throws {
        let files = FakeSystemWallpaperFiles(store: appleStore())
        let missing = try service(files, nativeModeEnabled: true).apply(assignments: ["DISPLAY-A": entry, "DISPLAY-Z": entry])
        XCTAssertEqual(missing, ["DISPLAY-Z"])
        XCTAssertEqual(provider(try files.storeRoot(), "DISPLAY-A"), ours)
        XCTAssertEqual(files.agentRestarts, 1)
    }

    func testPermissionErrorsReachTheCaller() throws {
        let files = FakeSystemWallpaperFiles(store: appleStore())
        files.store = nil
        files.readError = CocoaError(.fileReadNoPermission)
        XCTAssertThrowsError(try service(files, nativeModeEnabled: true).apply(assignments: ["DISPLAY-A": entry])) {
            XCTAssertTrue(WallpaperHostCapabilities.isPermissionError($0), "\($0)")
        }
    }

    func testUnknownDisplayIsRejectedWithoutWriting() throws {
        let files = FakeSystemWallpaperFiles(store: appleStore())
        XCTAssertThrowsError(try service(files, nativeModeEnabled: true).apply(assignments: ["DISPLAY-Z": entry]))
        XCTAssertEqual(files.storeWrites, 0)
        XCTAssertEqual(files.agentRestarts, 0)
    }

    // MARK: Restore original wallpaper

    func testRestorePutsBackTheUsersWallpaperAfterSeveralAssignments() throws {
        let files = FakeSystemWallpaperFiles(store: appleStore())
        let service = service(files, nativeModeEnabled: true)
        try service.apply(assignments: ["DISPLAY-A": entry])
        try service.apply(assignments: ["DISPLAY-A": entry, "DISPLAY-B": entry])
        files.agentRestarts = 0

        let result = try service.restoreOriginalWallpaper()

        let root = try files.storeRoot()
        XCTAssertEqual(config(root, "DISPLAY-A"), "beach")
        XCTAssertEqual(config(root, "DISPLAY-B"), "forest")
        XCTAssertEqual(result, .init(restored: 2, missing: 0))
        XCTAssertEqual(files.agentRestarts, 1)
    }

    func testRestoreWorksWithNativeModeOff() throws {
        let files = FakeSystemWallpaperFiles(store: appleStore())
        try service(files, nativeModeEnabled: true).apply(assignments: ["DISPLAY-A": entry])
        let result = try service(files, nativeModeEnabled: false).restoreOriginalWallpaper()
        XCTAssertEqual(config(try files.storeRoot(), "DISPLAY-A"), "beach")
        XCTAssertEqual(result, .init(restored: 1, missing: 0))
    }

    func testRestoreLeavesSurfacesWithoutASavedWallpaperAndCountsThem() throws {
        // A store that was already ours before the first backup existed.
        var store = appleStore()
        store["Displays"] = [
            "DISPLAY-A": ["Desktop": surface(provider: ours, config: "ENTRY-OLD")],
            "DISPLAY-B": ["Desktop": surface(provider: "com.apple.wallpaper.choice.image", config: "forest")],
        ]
        let files = FakeSystemWallpaperFiles(store: store)
        let service = service(files, nativeModeEnabled: true)
        try service.apply(assignments: ["DISPLAY-A": entry])

        let result = try service.restoreOriginalWallpaper()

        XCTAssertEqual(result, .init(restored: 0, missing: 1))
        XCTAssertEqual(provider(try files.storeRoot(), "DISPLAY-A"), ours)
    }

    func testRestoreReplacesTheOverlayPosterToo() throws {
        // Turning native mode off hands the desktop to the overlay, which sets
        // a LumaWall poster as the macOS desktop picture.
        let files = FakeSystemWallpaperFiles(store: appleStore())
        let service = service(files, nativeModeEnabled: true)
        try service.apply(assignments: ["DISPLAY-A": entry])
        var root = try files.storeRoot()
        var displays = try XCTUnwrap(root["Displays"] as? [String: Any])
        displays["DISPLAY-A"] = ["Desktop": posterSurface()]
        root["Displays"] = displays
        files.store = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)

        let result = try service.restoreOriginalWallpaper()

        XCTAssertEqual(result, .init(restored: 1, missing: 0))
        XCTAssertEqual(config(try files.storeRoot(), "DISPLAY-A"), "beach")
    }

    func testBackupNeverRecordsAnOverlayPosterAsTheUsersWallpaper() throws {
        let files = FakeSystemWallpaperFiles(store: appleStore())
        let service = service(files, nativeModeEnabled: true)
        try service.apply(assignments: ["DISPLAY-A": entry])
        var root = try files.storeRoot()
        var displays = try XCTUnwrap(root["Displays"] as? [String: Any])
        displays["DISPLAY-A"] = ["Desktop": posterSurface()]
        root["Displays"] = displays
        files.store = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
        try service.apply(assignments: ["DISPLAY-A": entry])

        _ = try service.restoreOriginalWallpaper()

        XCTAssertEqual(config(try files.storeRoot(), "DISPLAY-A"), "beach")
    }

    func testRestoreWithNothingOfOursDoesNotWriteOrRestart() throws {
        let files = FakeSystemWallpaperFiles(store: appleStore())
        let result = try service(files, nativeModeEnabled: false).restoreOriginalWallpaper()
        XCTAssertEqual(result, .init(restored: 0, missing: 0))
        XCTAssertEqual(files.storeWrites, 0)
        XCTAssertEqual(files.agentRestarts, 0)
    }

    func testBackupKeepsTheUsersNewerWallpaperOnAnotherDisplay() throws {
        let files = FakeSystemWallpaperFiles(store: appleStore())
        let service = service(files, nativeModeEnabled: true)
        try service.apply(assignments: ["DISPLAY-A": entry])
        // The user picks a new Apple wallpaper for display B in System Settings.
        var root = try files.storeRoot()
        var displays = try XCTUnwrap(root["Displays"] as? [String: Any])
        displays["DISPLAY-B"] = ["Desktop": surface(provider: "com.apple.wallpaper.choice.image", config: "desert")]
        root["Displays"] = displays
        files.store = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
        try service.apply(assignments: ["DISPLAY-A": entry, "DISPLAY-B": entry])

        _ = try service.restoreOriginalWallpaper()

        XCTAssertEqual(config(try files.storeRoot(), "DISPLAY-A"), "beach")
        XCTAssertEqual(config(try files.storeRoot(), "DISPLAY-B"), "desert")
    }
}
