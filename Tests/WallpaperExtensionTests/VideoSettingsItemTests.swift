import Foundation
import XCTest

/// macOS's Settings removal request never names the wallpaper (see
/// ChoiceRemoval), so a Remove offered there always fails. LumaWall's
/// videos are marked not removable; they're removed in the app.
final class VideoSettingsItemTests: XCTestCase {
    func testVideoChoicesAreNotRemovableInSettings() throws {
        let item = makeVideoSettingsItem(
            bundleID: "app.lumawall.personal.wallpaper",
            entryID: "5C99B113-4BED-4EB9-9219-24B3E7E6169C",
            name: "Waves",
            videoURL: URL(fileURLWithPath: "/tmp/Waves.mov"),
            thumbnailURL: URL(fileURLWithPath: "/tmp/Waves.png"),
            contextMenu: ContextMenu(items: []))
        let encoded = try JSONEncoder().encode(item.disposability)
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), #"{"none":{}}"#)
        XCTAssertEqual(item.choice.identifier, "5C99B113-4BED-4EB9-9219-24B3E7E6169C")
        XCTAssertEqual(item.id.descriptor.configuration, Data("5C99B113-4BED-4EB9-9219-24B3E7E6169C".utf8))
    }
}
