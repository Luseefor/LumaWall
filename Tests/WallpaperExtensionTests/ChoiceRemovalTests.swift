import Foundation
import XCTest

/// A remove request deletes a video only when it names one of our own
/// registered choices (#68 S2), and a refusal replies with an error (#91).
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
            .refuse(.otherProvider))
    }

    func testRefusesAnIdentifierThatIsntInTheLibrary() {
        let request = FakeChoiceIDXPC(provider: own, identifier: video)
        XCTAssertEqual(
            ChoiceRemoval.target(in: request, ownProvider: own) { _ in false },
            .refuse(.notInLibrary))
    }

    func testRefusesARequestWithNoChoiceDescriptor() {
        XCTAssertEqual(
            ChoiceRemoval.target(in: "identifier: \"\(video)\"", ownProvider: own) { _ in true },
            .refuse(.noChoiceID))
    }

    func testRefusesAnAddStyleChoiceRequest() {
        let request = ChoiceRequest.image(URL(fileURLWithPath: "/Users/someone/Videos/\(video)"))
        XCTAssertEqual(
            ChoiceRemoval.target(in: request, ownProvider: own) { _ in true },
            .refuse(.noChoiceID))
    }

    func testIgnoresAnIdentifierOutsideTheDescriptor() {
        // The old parser took the first `identifier: "` in the request's
        // description, wherever it appeared.
        let request = Decoy(note: "identifier: \"\(video)\"", choice: FakeChoiceIDXPC(provider: own, identifier: "other"))
        XCTAssertEqual(
            ChoiceRemoval.target(in: request, ownProvider: own) { $0 == self.video },
            .refuse(.notInLibrary))
    }

    func testRefusesAMissingRequest() {
        XCTAssertEqual(ChoiceRemoval.target(in: nil, ownProvider: own) { _ in true }, .refuse(.noRequest))
    }

    func testRefusesADescriptorWithoutFiles() {
        // WallpaperChoiceDescriptor always has provider, files and configuration.
        let request = Partial(provider: ProviderID(rawValue: own), configuration: Data(video.utf8))
        XCTAssertEqual(
            ChoiceRemoval.target(in: request, ownProvider: own) { _ in true },
            .refuse(.noChoiceID))
    }

    /// The host's remove call sends WallpaperExtensionChoiceRequestXPC, whose
    /// `box` is an XPCBox<WallpaperChoiceRequest>. Built here from the real
    /// WallpaperTypes enum so a future case that names a choice shows up.
    func testRefusesTheRealSettingsRemovalRequest() throws {
        _ = dlopen("/System/Library/PrivateFrameworks/WallpaperTypes.framework/WallpaperTypes", RTLD_NOW)
        guard let type = _typeByName("14WallpaperTypes22WallpaperChoiceRequestO") as? any Decodable.Type else {
            throw XCTSkip("WallpaperTypes.WallpaperChoiceRequest isn't on this system")
        }
        let samples = [
            #"{"type":"image","url":"file:///Users/someone/Movies/\#(video).mov"}"#,
            #"{"type":"photoLibraryAsset","identifier":"\#(video)"}"#,
        ]
        var decoded = 0
        for json in samples {
            guard let value = try? JSONDecoder().decode(type, from: Data(json.utf8)) else { continue }
            decoded += 1
            XCTAssertEqual(
                ChoiceRemoval.target(in: FakeChoiceRequestXPC(box: XPCBox(rawValue: value)), ownProvider: own) { _ in true },
                .refuse(.noChoiceID), json)
        }
        if decoded == 0 { throw XCTSkip("WallpaperChoiceRequest has a different coding on this system") }
    }

    func testARefusalRepliesWithAnErrorThatNamesNoFiles() {
        for refusal in [ChoiceRemoval.Refusal.noRequest, .noChoiceID, .otherProvider, .notInLibrary] {
            let error = refusal.error
            XCTAssertEqual(error.domain, ChoiceRemoval.errorDomain)
            XCTAssertNotEqual(error.code, 0)
            XCTAssertFalse(error.localizedDescription.isEmpty)
            XCTAssertNil(error.userInfo[NSFilePathErrorKey])
            XCTAssertNil(error.userInfo[NSURLErrorKey])
        }
        XCTAssertNotEqual(ChoiceRemoval.Refusal.noChoiceID.error.code, ChoiceRemoval.Refusal.notInLibrary.error.code)
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

private struct Partial {
    let provider: ProviderID
    let configuration: Data
}

// WallpaperExtensionChoiceRequestXPC boxes a WallpaperChoiceRequest, an enum
// of things to add (a color, an image URL, ...). It names no choice of ours.
private enum ChoiceRequest {
    case image(URL)
}

private final class FakeChoiceRequestXPC: NSObject {
    let box: XPCBox
    init(box: XPCBox) { self.box = box }
}

private struct XPCBox {
    let rawValue: Any
}
