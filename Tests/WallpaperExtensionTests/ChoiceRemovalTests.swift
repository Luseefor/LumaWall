import Foundation
import XCTest

/// A remove request deletes a video only when it names one of our own
/// registered choices (#68 S2).
final class ChoiceRemovalTests: XCTestCase {
    private let own = "app.lumawall.personal.wallpaper"
    private let video = "5C99B113-4BED-4EB9-9219-24B3E7E6169C"

    func testRemovesARegisteredChoiceFromOurProvider() {
        let request = FakeChoiceIDXPC(provider: own, identifier: video)
        XCTAssertEqual(
            ChoiceRemoval.target(in: request, ownProvider: own) { $0 == self.video },
            .remove(video))
    }

    func testRefusesAChoiceFromAnotherProvider() {
        let request = FakeChoiceIDXPC(provider: "com.apple.wallpaper.extension.aerials", identifier: video)
        XCTAssertEqual(
            ChoiceRemoval.target(in: request, ownProvider: own) { _ in true },
            .refuse("choice belongs to another provider"))
    }

    func testRefusesAnIdentifierThatIsntInTheLibrary() {
        let request = FakeChoiceIDXPC(provider: own, identifier: video)
        XCTAssertEqual(
            ChoiceRemoval.target(in: request, ownProvider: own) { _ in false },
            .refuse("choice isn't in the library"))
    }

    func testRefusesARequestWithNoChoiceDescriptor() {
        XCTAssertEqual(
            ChoiceRemoval.target(in: "identifier: \"\(video)\"", ownProvider: own) { _ in true },
            .refuse("no choice descriptor in request"))
    }

    func testRefusesAnAddStyleChoiceRequest() {
        let request = ChoiceRequest.image(URL(fileURLWithPath: "/Users/someone/Videos/\(video)"))
        XCTAssertEqual(
            ChoiceRemoval.target(in: request, ownProvider: own) { _ in true },
            .refuse("no choice descriptor in request"))
    }

    func testIgnoresAnIdentifierOutsideTheDescriptor() {
        // The old parser took the first `identifier: "` in the request's
        // description, wherever it appeared.
        let request = Decoy(note: "identifier: \"\(video)\"", choice: FakeChoiceIDXPC(provider: own, identifier: "other"))
        XCTAssertEqual(
            ChoiceRemoval.target(in: request, ownProvider: own) { $0 == self.video },
            .refuse("choice isn't in the library"))
    }
}

// Shaped like WallpaperChoiceIDXPC on macOS 27.2, read from WallpaperTypes'
// Swift metadata: `rawValue` is a WallpaperChoice.ID whose `descriptor` holds
// `provider` (WallpaperChoiceProviderID, a `rawValue` String), `files` and
// `configuration`. SettingsProvider puts the video ID in `configuration`.
private final class FakeChoiceIDXPC: NSObject {
    let rawValue: ChoiceIDValue
    init(provider: String, identifier: String) {
        rawValue = ChoiceIDValue(
            descriptor: Descriptor(
                provider: ProviderID(rawValue: provider), files: [], configuration: Data(identifier.utf8)))
    }
}

private struct ChoiceIDValue {
    let descriptor: Descriptor
}

private struct Descriptor {
    let provider: ProviderID
    let files: [URL]
    let configuration: Data
}

private struct ProviderID {
    let rawValue: String
}

private struct Decoy {
    let note: String
    let choice: FakeChoiceIDXPC
}

// WallpaperExtensionChoiceRequestXPC boxes a WallpaperChoiceRequest, an enum
// of things to add (a color, an image URL, ...). It names no choice of ours.
private enum ChoiceRequest {
    case image(URL)
}
