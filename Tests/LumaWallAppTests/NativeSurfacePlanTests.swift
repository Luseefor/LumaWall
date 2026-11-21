import Foundation
import XCTest

@testable import LumaWall

/// What a native assignment writes where, per layout (ADR 0004).
final class NativeSurfacePlanTests: XCTestCase {
    private let ours = WallpaperHostCapabilities.extensionBundleID
    private let library = URL(fileURLWithPath: "/Users/someone/Library/Application Support/LumaWall", isDirectory: true)
    private let lockOnly = NativeSurfaceLayout(preset: .lockScreenOnly)
    private let lockOnStill = NativeSurfaceLayout(preset: .lockScreenOnly, settlesOnStill: true)

    private func video(_ id: String) -> NativeSurfacePlan.Video {
        .init(choiceID: id, url: URL(fileURLWithPath: "/videos/\(id)/Wallpaper.mov"))
    }

    private func still(_ id: String) -> URL {
        library.appendingPathComponent("\(id)/Poster.jpg")
    }

    private func target(_ id: String, still hasStill: Bool = true) -> NativeSurfacePlan.Target {
        .init(video: video(id), still: hasStill ? still(id) : nil)
    }

    private func apple(_ name: String) -> NSDictionary {
        ["Content": ["Choices": [["Provider": NativeSurfacePlan.imageProvider, "Configuration": Data(name.utf8)]]]]
    }

    private func lumaWall(_ id: String) -> NSDictionary {
        ["Content": ["Choices": [["Provider": ours, "Configuration": Data(id.utf8)]]]]
    }

    private func store(_ displays: [String: [String: NSDictionary]], spaces: [String: [String: [String: NSDictionary]]] = [:])
        -> NSDictionary
    {
        var root: [String: Any] = ["Displays": displays]
        if !spaces.isEmpty { root["Spaces"] = spaces.mapValues { ["Displays": $0] } }
        return root as NSDictionary
    }

    private func plan(
        _ root: NSDictionary, backup: NSDictionary? = nil, layout: NativeSurfaceLayout,
        targets: [String: NativeSurfacePlan.Target], idleOverride: NativeSurfacePlan.Video? = nil
    ) -> NativeSurfacePlan.Outcome {
        NativeSurfacePlan.changes(
            root: root, backup: backup, layout: layout, targets: targets, idleOverride: idleOverride, ownedFolders: [library])
    }

    func testEverywhereWritesOnlyDesktops() {
        let root = store(["A": ["Desktop": apple("beach"), "Idle": apple("beach")]])

        let outcome = plan(root, layout: .init(), targets: ["A": target("V1")])

        XCTAssertEqual(outcome.changes, [.init(path: ["Displays", "A", "Desktop"], write: .video(video("V1")))])
        XCTAssertEqual(outcome.assigned, ["A"])
    }

    func testLockScreenOnlyPutsTheVideoOnIdleAndLeavesTheUsersDesktop() {
        let root = store(["A": ["Desktop": apple("beach"), "Idle": apple("beach")]])

        let outcome = plan(root, layout: lockOnly, targets: ["A": target("V1")])

        XCTAssertEqual(outcome.changes, [.init(path: ["Displays", "A", "Idle"], write: .video(video("V1")))])
        XCTAssertEqual(outcome.assigned, ["A"])
        XCTAssertTrue(outcome.desktopsLeftPlaying.isEmpty)
    }

    func testLockScreenOnlyGivesBackTheSavedPictureWhereLumaWallPlayed() {
        let root = store(["A": ["Desktop": lumaWall("V1"), "Idle": lumaWall("V1")]])
        let backup = store(["A": ["Desktop": apple("beach"), "Idle": apple("beach")]])

        let outcome = plan(root, backup: backup, layout: lockOnly, targets: ["A": target("V1")])

        XCTAssertEqual(
            outcome.changes,
            [
                .init(path: ["Displays", "A", "Idle"], write: .video(video("V1"))),
                .init(path: ["Displays", "A", "Desktop"], write: .saved(apple("beach"))),
            ])
    }

    func testLockScreenOnlyFallsBackToTheStillWhenNothingIsSaved() {
        let root = store(["A": ["Desktop": lumaWall("V1"), "Idle": lumaWall("V1")]])

        let outcome = plan(root, layout: lockOnly, targets: ["A": target("V1")])

        XCTAssertEqual(outcome.changes.last, .init(path: ["Displays", "A", "Desktop"], write: .image(still("V1"))))
        XCTAssertTrue(outcome.desktopsLeftPlaying.isEmpty)
    }

    func testLockScreenOnlyReportsADesktopItCannotStop() {
        let root = store(["A": ["Desktop": lumaWall("V1"), "Idle": lumaWall("V1")]])

        let outcome = plan(root, layout: lockOnly, targets: ["A": target("V1", still: false)])

        XCTAssertEqual(outcome.changes.map(\.path), [["Displays", "A", "Idle"]])
        XCTAssertEqual(outcome.desktopsLeftPlaying, ["A"])
    }

    func testSettleOnStillShowsEachDisplaysOwnStill() {
        // Mixed displays: a laptop panel and a portrait external, each with
        // its own wallpaper.
        let root = store([
            "LAPTOP": ["Desktop": apple("beach"), "Idle": apple("beach")],
            "PORTRAIT": ["Desktop": lumaWall("V2"), "Idle": apple("forest")],
        ])

        let outcome = plan(root, layout: lockOnStill, targets: ["LAPTOP": target("V1"), "PORTRAIT": target("V2")])

        XCTAssertEqual(
            outcome.changes,
            [
                .init(path: ["Displays", "LAPTOP", "Idle"], write: .video(video("V1"))),
                .init(path: ["Displays", "LAPTOP", "Desktop"], write: .image(still("V1"))),
                .init(path: ["Displays", "PORTRAIT", "Idle"], write: .video(video("V2"))),
                .init(path: ["Displays", "PORTRAIT", "Desktop"], write: .image(still("V2"))),
            ])
        XCTAssertEqual(outcome.assigned, ["LAPTOP", "PORTRAIT"])
    }

    func testSettleOnStillDoesNotRewriteAStillAlreadyShown() throws {
        let root = NSMutableDictionary(dictionary: store(["A": ["Desktop": apple("beach"), "Idle": apple("beach")]]))
        let first = plan(root, layout: lockOnStill, targets: ["A": target("V1")])
        let mutable = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0),
                options: [.mutableContainersAndLeaves], format: nil) as? NSMutableDictionary)
        NativeSurfacePlan.apply(first.changes, to: mutable)

        let second = plan(mutable, layout: lockOnStill, targets: ["A": target("V1")])

        XCTAssertEqual(second.changes.map(\.path), [["Displays", "A", "Idle"]])
    }

    func testTheLockScreenPickGoesOnEveryIdle() {
        let root = store(["A": ["Desktop": apple("beach"), "Idle": apple("beach")], "B": ["Idle": apple("forest")]])

        let outcome = plan(root, layout: lockOnly, targets: ["A": target("V1"), "B": target("V2")], idleOverride: video("PICK"))

        XCTAssertEqual(
            outcome.changes,
            [
                .init(path: ["Displays", "A", "Idle"], write: .video(video("PICK"))),
                .init(path: ["Displays", "B", "Idle"], write: .video(video("PICK"))),
            ])
    }

    func testEveryCopyOfADisplayIsPlannedIncludingSpaces() {
        let root = store(
            ["A": ["Desktop": apple("beach"), "Idle": apple("beach")]],
            spaces: ["SPACE-1": ["A": ["Desktop": lumaWall("V1")]]])

        let outcome = plan(root, layout: lockOnStill, targets: ["A": target("V1")])

        XCTAssertEqual(
            outcome.changes.map(\.path),
            [["Displays", "A", "Idle"], ["Displays", "A", "Desktop"], ["Spaces", "SPACE-1", "Displays", "A", "Desktop"]])
    }

    func testADisplayWithoutThePresetsSurfaceIsNotAssigned() {
        let root = store(["A": ["Desktop": apple("beach")]])

        XCTAssertEqual(plan(root, layout: lockOnly, targets: ["A": target("V1")]).assigned, [])
        XCTAssertEqual(plan(root, layout: .init(), targets: ["B": target("V1")]).assigned, [])
    }

    func testTheWrittenStillIsAnAppleImageChoiceLumaWallRecognises() throws {
        let root = NSMutableDictionary(dictionary: [
            "Displays": ["A": ["Desktop": ["Content": ["Choices": [] as [Any], "Shuffle": "$null"]]]]
        ])
        let mutable = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0),
                options: [.mutableContainersAndLeaves], format: nil) as? NSMutableDictionary)

        NativeSurfacePlan.apply([.init(path: ["Displays", "A", "Desktop"], write: .image(still("V1")))], to: mutable)

        let desktop = try XCTUnwrap(NativeWallpaperAssignmentStore.value(at: ["Displays", "A", "Desktop"], in: mutable) as? NSDictionary)
        let choice = try XCTUnwrap(((desktop["Content"] as? NSDictionary)?["Choices"] as? [NSDictionary])?.first)
        XCTAssertEqual(choice["Provider"] as? String, NativeSurfacePlan.imageProvider)
        XCTAssertEqual(NativeSurfacePlan.imageURL(of: choice), still("V1"))
        XCTAssertTrue(NativeWallpaperAssignmentStore.isOurs(desktop, ownedFolders: [library]))
        XCTAssertNoThrow(try PropertyListSerialization.data(fromPropertyList: mutable, format: .binary, options: 0))
    }

    func testLayoutRoundTripsThroughDefaults() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "NativeSurfacePlanTests"))
        defaults.removePersistentDomain(forName: "NativeSurfacePlanTests")
        XCTAssertEqual(NativeSurfaceLayout(defaults: defaults), NativeSurfaceLayout())

        lockOnStill.save(to: defaults)

        XCTAssertEqual(NativeSurfaceLayout(defaults: defaults), lockOnStill)
        XCTAssertFalse(lockOnStill.playsOnDesktop)
        XCTAssertNotEqual(lockOnStill.tag, lockOnly.tag)
        XCTAssertEqual(NativeSurfaceLayout(settlesOnStill: true).tag, NativeSurfaceLayout().tag)
        defaults.removePersistentDomain(forName: "NativeSurfacePlanTests")
    }
}
