import Foundation
import XCTest

@testable import LumaWall

/// The lock-screen-only layout through the service: Safe mode, the backup
/// and Restore (ADR 0004).
@MainActor
final class NativeLockScreenOnlyTests: XCTestCase {
    private let ours = WallpaperHostCapabilities.extensionBundleID
    private let library = URL(fileURLWithPath: "/Users/someone/Library/Application Support/LumaWall", isDirectory: true)

    private func surface(_ provider: String, _ config: String) -> [String: Any] {
        ["Content": ["Choices": [["Provider": provider, "Configuration": Data(config.utf8)]], "Shuffle": "$null"]]
    }

    /// A landscape panel and a portrait external, both on the user's pictures.
    private func userStore() -> [String: Any] {
        [
            "Displays": [
                "LAPTOP": [
                    "Desktop": surface(NativeSurfacePlan.imageProvider, "beach"),
                    "Idle": surface(NativeSurfacePlan.imageProvider, "beach"),
                ],
                "PORTRAIT": [
                    "Desktop": surface(NativeSurfacePlan.imageProvider, "forest"),
                    "Idle": surface(NativeSurfacePlan.imageProvider, "forest"),
                ],
            ]
        ]
    }

    private func target(_ id: String) -> NativeSurfacePlan.Target {
        .init(
            video: .init(choiceID: id, url: URL(fileURLWithPath: "/videos/\(id)/Wallpaper.mov")),
            still: library.appendingPathComponent("\(id)/Poster.jpg"))
    }

    private var targets: [String: NativeSurfacePlan.Target] { ["LAPTOP": target("V1"), "PORTRAIT": target("V2")] }

    private func service(_ files: FakeSystemWallpaperFiles, on: Bool = true) -> NativeWallpaperAssignmentService {
        NativeWallpaperAssignmentService(files: files, ownedFolders: [library], nativeModeEnabled: { on })
    }

    private func choice(_ root: [String: Any], _ display: String, _ surface: String) -> [String: Any]? {
        let displays = root["Displays"] as? [String: Any]
        let entry = (displays?[display] as? [String: Any])?[surface] as? [String: Any]
        return ((entry?["Content"] as? [String: Any])?["Choices"] as? [[String: Any]])?.first
    }

    private func config(_ root: [String: Any], _ display: String, _ surface: String) -> String? {
        (choice(root, display, surface)?["Configuration"] as? Data).map { String(decoding: $0, as: UTF8.self) }
    }

    func testSafeModeWritesNothing() {
        let files = FakeSystemWallpaperFiles(store: userStore())
        XCTAssertThrowsError(
            try service(files, on: false).apply(targets: targets, layout: .init(preset: .lockScreenOnly)))
        XCTAssertEqual(files.reads, 0)
        XCTAssertEqual(files.storeWrites, 0)
        XCTAssertEqual(files.backupWrites, 0)
    }

    func testLockScreensPlayAndDesktopsKeepTheUsersPictures() throws {
        let files = FakeSystemWallpaperFiles(store: userStore())

        let missing = try service(files).apply(targets: targets, layout: .init(preset: .lockScreenOnly))

        let root = try files.storeRoot()
        XCTAssertTrue(missing.isEmpty)
        XCTAssertEqual(config(root, "LAPTOP", "Idle"), "V1")
        XCTAssertEqual(config(root, "PORTRAIT", "Idle"), "V2")
        XCTAssertEqual(config(root, "LAPTOP", "Desktop"), "beach")
        XCTAssertEqual(config(root, "PORTRAIT", "Desktop"), "forest")
        XCTAssertEqual(files.agentRestarts, 1)
    }

    func testSwitchingFromEverywhereGivesTheDesktopsBack() throws {
        let files = FakeSystemWallpaperFiles(store: userStore())
        try service(files).apply(targets: targets, layout: .init())
        XCTAssertEqual(choice(try files.storeRoot(), "LAPTOP", "Desktop")?["Provider"] as? String, ours)

        try service(files).apply(targets: targets, layout: .init(preset: .lockScreenOnly))

        let root = try files.storeRoot()
        XCTAssertEqual(config(root, "LAPTOP", "Desktop"), "beach")
        XCTAssertEqual(config(root, "PORTRAIT", "Desktop"), "forest")
        XCTAssertEqual(config(root, "PORTRAIT", "Idle"), "V2")
    }

    func testSettleOnStillShowsEachDisplaysStillAndRestoreUndoesAll() throws {
        let files = FakeSystemWallpaperFiles(store: userStore())
        try service(files).apply(targets: targets, layout: .init(preset: .lockScreenOnly, settlesOnStill: true))

        var root = try files.storeRoot()
        let laptop = try XCTUnwrap(choice(root, "LAPTOP", "Desktop") as NSDictionary?)
        let portrait = try XCTUnwrap(choice(root, "PORTRAIT", "Desktop") as NSDictionary?)
        XCTAssertEqual(NativeSurfacePlan.imageURL(of: laptop), target("V1").still)
        XCTAssertEqual(NativeSurfacePlan.imageURL(of: portrait), target("V2").still)

        let result = try service(files, on: false).restoreOriginalWallpaper()

        root = try files.storeRoot()
        XCTAssertEqual(result, .init(restored: 4, missing: 0))
        XCTAssertEqual(config(root, "LAPTOP", "Desktop"), "beach")
        XCTAssertEqual(config(root, "LAPTOP", "Idle"), "beach")
        XCTAssertEqual(config(root, "PORTRAIT", "Desktop"), "forest")
        XCTAssertEqual(config(root, "PORTRAIT", "Idle"), "forest")
    }

    func testTheBackupNeverSavesTheStillAsTheUsersPicture() throws {
        let files = FakeSystemWallpaperFiles(store: userStore())
        let still = NativeSurfaceLayout(preset: .lockScreenOnly, settlesOnStill: true)
        try service(files).apply(targets: targets, layout: still)
        // A second write backs up the store again, stills and all.
        try service(files).apply(targets: ["LAPTOP": target("V3"), "PORTRAIT": target("V2")], layout: still)

        _ = try service(files, on: false).restoreOriginalWallpaper()

        XCTAssertEqual(config(try files.storeRoot(), "LAPTOP", "Desktop"), "beach")
    }
}
