import Foundation
import XCTest

/// Verbose request dumps show a value's shape without its file names, path
/// components or free text (#91 S15).
final class MirrorDumpTests: XCTestCase {
    private let entry = "5C99B113-4BED-4EB9-9219-24B3E7E6169C"

    func testAFileURLIsReducedToAHashOfItsLastComponent() {
        let request = Request.image(URL(fileURLWithPath: "/Users/alice/Movies/Holiday Trip.mov"))
        XCTAssertEqual(
            MirrorDump.lines(request, label: "removeRequest"),
            [
                "[removeRequest] Request",
                "  .image: URL = …/#3f74020b.mov",
            ])
    }

    func testNoPathComponentSurvivesInAnyForm() {
        let path = "/Volumes/Backup/alice/Movies/Holiday Trip.mov"
        let request = Holder(
            url: URL(fileURLWithPath: path), path: path, encoded: URL(fileURLWithPath: path).absoluteString,
            nested: Request.image(URL(fileURLWithPath: path)))
        let text = MirrorDump.lines(request).joined(separator: "\n")
        for part in ["Volumes", "Backup", "alice", "Movies", "Holiday", "Trip", "%20"] {
            XCTAssertFalse(text.contains(part), "\(part) in\n\(text)")
        }
    }

    func testALibraryFileKeepsItsEntryIDAndTheAppsFileName() {
        let url = URL(fileURLWithPath: "/Users/alice/Library/Containers/x/Data/Documents/videos/\(entry)/Wallpaper.mp4")
        XCTAssertEqual(MirrorDump.leaf(url), "…/\(entry)/Wallpaper.mp4")
        XCTAssertEqual(MirrorDump.leaf(URL(fileURLWithPath: "/x/videos/\(entry)")), "…/\(entry)")
    }

    func testTextIsHashedAndOnlyEntryIDsAreKept() {
        XCTAssertEqual(MirrorDump.leaf("Holiday in Rome"), "<text #9a91ef42>")
        XCTAssertEqual(MirrorDump.leaf(entry), entry)
        XCTAssertEqual(MirrorDump.leaf("Movies"), "<text #dff924b6>")
        // A file can be named like a bundle ID.
        XCTAssertEqual(MirrorDump.leaf("com.apple.Movies"), "<text #27875e03>")
        XCTAssertEqual(MirrorDump.leaf("app.lumawall.personal.wallpaper"), "<text #68cb7a60>")
        XCTAssertEqual(MirrorDump.leaf("Holiday in Rome".dropFirst(0)), "<text #9a91ef42>")
        XCTAssertEqual(MirrorDump.leaf("Holiday in Rome" as NSString), "<text #9a91ef42>")
    }

    func testOnlyMediaExtensionsAreKept() {
        XCTAssertEqual(MirrorDump.leaf(URL(fileURLWithPath: "/Users/x/Pictures/Family.alice")), "…/#f09483d5")
        XCTAssertEqual(MirrorDump.leaf(URL(fileURLWithPath: "/Users/x/Pictures/Family.alice", isDirectory: true)), "…/#f09483d5")
        XCTAssertEqual(MirrorDump.leaf(URL(fileURLWithPath: "/Users/x/Movies/Holiday Trip.MOV")), "…/#b09248e7.mov")
    }

    func testTheAppsFileNameIsKeptOnlyInsideAnEntry() {
        XCTAssertEqual(MirrorDump.leaf(URL(fileURLWithPath: "/Users/x/Movies/Wallpaper.mp4")), "…/#bb67c42a.mp4")
    }

    func testANonFileURLIsHashedWhole() {
        XCTAssertEqual(MirrorDump.leaf(URL(string: "lumawall-private://alice/Holiday")!), "<URL #036ef482>")
        XCTAssertEqual(MirrorDump.leaf(NSURL(string: "lumawall-private://alice/Holiday")!), "<URL #036ef482>")
    }

    func testACustomDescriptionOrMirrorDoesntReachTheLog() {
        XCTAssertEqual(MirrorDump.leaf(Described.folder), "")
        XCTAssertEqual(
            MirrorDump.lines(Labelled()),
            [
                "[root] Labelled",
                "  .#0: Int = 1",
            ])
    }

    func testNumbersFlagsCasesAndDataStayReadable() {
        XCTAssertEqual(MirrorDump.leaf(42), "42")
        XCTAssertEqual(MirrorDump.leaf(true), "true")
        XCTAssertEqual(MirrorDump.leaf(Kind.removable), "removable")
        XCTAssertEqual(MirrorDump.leaf(Data(entry.utf8)), "<36 bytes>")
        XCTAssertEqual(MirrorDump.leaf(Optional<Int>.none as Any), "nil")
    }

    func testAnOpaqueObjectShowsOnlyItsType() {
        // Its description could be anything, a path included.
        XCTAssertEqual(MirrorDump.leaf(Opaque()), "")
        XCTAssertEqual(MirrorDump.lines(Opaque()), ["[root] Opaque"])
    }

    func testTheDumpStopsAtItsDepth() {
        let lines = MirrorDump.lines(Nest(inner: Nest(inner: Nest(inner: nil))), depth: 1)
        XCTAssertEqual(
            lines,
            [
                "[root] Nest",
                "  .inner: Optional<Nest>",
                "    …",
            ])
    }
}

private enum Request {
    case image(URL)
}

private enum Kind {
    case removable
}

private enum Described: CustomStringConvertible {
    case folder
    var description: String { "PrivateFolder" }
}

private struct Labelled: CustomReflectable {
    var customMirror: Mirror { Mirror(self, children: ["Holiday Trip.mov": 1]) }
}

private struct Holder {
    let url: URL
    let path: String
    let encoded: String
    let nested: Request
}

private final class Opaque: NSObject {
    override var description: String { "/Users/alice/Movies/Holiday Trip.mov" }
}

private final class Nest {
    let inner: Nest?
    init(inner: Nest?) { self.inner = inner }
}
