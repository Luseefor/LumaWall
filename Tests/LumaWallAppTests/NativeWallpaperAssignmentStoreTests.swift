import Foundation
import XCTest
@testable import LumaWall

final class NativeWallpaperAssignmentStoreTests: XCTestCase {
    func testUpdatedWallpaperStoreRemainsAValidPropertyList() throws {
        let content = NSMutableDictionary(dictionary: [
            "Choices": [],
            "Shuffle": "$null",
        ])
        let desktop = NSMutableDictionary(dictionary: ["Content": content])
        let display = NSMutableDictionary(dictionary: ["Desktop": desktop])
        let displays = NSMutableDictionary(dictionary: ["DISPLAY-A": display])
        let root = NSMutableDictionary(dictionary: ["Displays": displays])

        let changed = NativeWallpaperAssignmentStore.update(
            root: root,
            choiceID: "WALLPAPER-A",
            videoURL: URL(fileURLWithPath: "/tmp/wallpaper.mov"),
            displayUUIDs: ["DISPLAY-A"]
        )

        XCTAssertEqual(changed, ["DISPLAY-A"])
        let encoded = try PropertyListSerialization.data(
            fromPropertyList: root,
            format: .binary,
            options: 0
        )
        var decodedFormat = PropertyListSerialization.PropertyListFormat.binary
        let decoded = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: encoded,
                options: [],
                format: &decodedFormat
            ) as? [String: Any])
        let decodedDisplays = try XCTUnwrap(decoded["Displays"] as? [String: Any])
        let decodedDisplay = try XCTUnwrap(decodedDisplays["DISPLAY-A"] as? [String: Any])
        let decodedDesktop = try XCTUnwrap(decodedDisplay["Desktop"] as? [String: Any])
        let decodedContent = try XCTUnwrap(decodedDesktop["Content"] as? [String: Any])

        XCTAssertEqual(decodedContent["Shuffle"] as? String, "$null")
        XCTAssertNil(decodedContent["Shuffle"] as? NSNull)
    }

    // MARK: Displays another Space shows something else on

    private func desktop(provider: String) -> NSDictionary {
        ["Desktop": ["Content": ["Choices": [["Provider": provider]]]]]
    }

    func testFindsADisplayWhoseOtherSpaceShowsAnotherWallpaper() {
        let ours = WallpaperHostCapabilities.extensionBundleID
        let root: NSDictionary = [
            "Displays": ["A": desktop(provider: ours), "B": desktop(provider: ours)],
            "Spaces": [
                "SPACE-1": ["Displays": ["A": desktop(provider: "com.apple.wallpaper.choice.image")]],
                "SPACE-2": ["Displays": ["B": desktop(provider: ours)]],
            ],
        ]
        XCTAssertEqual(NativeWallpaperAssignmentStore.displaysShowingOthers(in: root), ["A"])
    }

    func testAStoreThatIsAllOursHasNone() {
        let root: NSDictionary = ["Displays": ["A": desktop(provider: WallpaperHostCapabilities.extensionBundleID)]]
        XCTAssertTrue(NativeWallpaperAssignmentStore.displaysShowingOthers(in: root).isEmpty)
    }
}
