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
        let decoded = try XCTUnwrap(PropertyListSerialization.propertyList(
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
}
