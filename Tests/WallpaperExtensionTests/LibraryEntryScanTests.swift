import Foundation
import XCTest

/// A library scan reads entry directories and never changes them (#68 S9,
/// S11): only regular files directly in the entry count, and nothing is
/// pruned or written, since the app may still be staging an entry.
final class LibraryEntryScanTests: XCTestCase {
    private var videos: URL!
    private let id = "5C99B113-4BED-4EB9-9219-24B3E7E6169C"
    private var entryDir: URL { videos.appendingPathComponent(id, isDirectory: true) }

    override func setUpWithError() throws {
        videos = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: entryDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: videos)
    }

    private func write(_ name: String, _ data: Data = Data("x".utf8)) throws {
        try data.write(to: entryDir.appendingPathComponent(name))
    }

    private func writeMetadata(filename: String = "Wallpaper.mp4", variants: [String] = []) throws {
        let variantJSON = variants.map { #"{"filename":"\#($0)","fps":30,"resolution":[1280,720]}"# }.joined(separator: ",")
        let json = """
            {"id":"\(id)","name":"Wallpaper","filename":"\(filename)","duration":10,"fps":30,\
            "resolution":[1920,1080],"dateAdded":0,"variants":[\(variantJSON)]}
            """
        try write("metadata.json", Data(json.utf8))
    }

    private func contents() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: entryDir.path).sorted()
    }

    func testReadsAnEntryWithItsVariants() throws {
        try writeMetadata(variants: ["Wallpaper.reduced.mov"])
        try write("Wallpaper.mp4")
        try write("Wallpaper.reduced.mov")
        guard case let .entry(entry) = LibraryEntryScan.read(directory: entryDir) else { return XCTFail() }
        XCTAssertEqual(entry.filename, "Wallpaper.mp4")
        XCTAssertEqual(entry.variants?.map(\.filename), ["Wallpaper.reduced.mov"])
    }

    func testAnEntryWhoseVideoIsMissingIsSkippedNotPruned() throws {
        try writeMetadata()
        XCTAssertEqual(LibraryEntryScan.read(directory: entryDir), .skipped("video file missing or not a regular file"))
        XCTAssertEqual(try contents(), ["metadata.json"])
    }

    func testAnEmptyDirectoryTheAppIsStagingIsLeftAlone() throws {
        XCTAssertEqual(LibraryEntryScan.read(directory: entryDir), .skipped("no metadata and no video file"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: entryDir.path))
    }

    func testAVideoThatIsASymlinkIsRefused() throws {
        try writeMetadata()
        let outside = videos.appendingPathComponent("elsewhere.mp4")
        try Data("x".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: entryDir.appendingPathComponent("Wallpaper.mp4"), withDestinationURL: outside)
        XCTAssertEqual(LibraryEntryScan.read(directory: entryDir), .skipped("video file missing or not a regular file"))
    }

    func testAVariantThatIsASymlinkIsDropped() throws {
        try writeMetadata(variants: ["Wallpaper.reduced.mov", "Wallpaper.minimal.mov"])
        try write("Wallpaper.mp4")
        try write("Wallpaper.minimal.mov")
        let outside = videos.appendingPathComponent("elsewhere.mov")
        try Data("x".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: entryDir.appendingPathComponent("Wallpaper.reduced.mov"), withDestinationURL: outside)
        guard case let .entry(entry) = LibraryEntryScan.read(directory: entryDir) else { return XCTFail() }
        XCTAssertEqual(entry.variants?.map(\.filename), ["Wallpaper.minimal.mov"])
    }

    func testAnEntryDirectoryThatIsASymlinkIsSkipped() throws {
        let real = videos.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let linkID = "7D2FB754-DAC3-4925-A7DE-07352E6D4DCE"
        let link = videos.appendingPathComponent(linkID)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertEqual(LibraryEntryScan.read(directory: link), .skipped("not a directory"))
    }

    func testRecoveryTakesARegularVideoFileAndWritesNothing() throws {
        try write("Clip.mov")
        guard case let .entry(entry) = LibraryEntryScan.read(directory: entryDir) else { return XCTFail() }
        XCTAssertEqual(entry.id, id)
        XCTAssertEqual(entry.filename, "Clip.mov")
        XCTAssertEqual(try contents(), ["Clip.mov"])
    }

    func testRecoveryIgnoresSymlinksAndDirectoriesWithAVideoSuffix() throws {
        try FileManager.default.createDirectory(at: entryDir.appendingPathComponent("Folder.mov"), withIntermediateDirectories: true)
        let outside = videos.appendingPathComponent("elsewhere.mp4")
        try Data("x".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: entryDir.appendingPathComponent("Link.mp4"), withDestinationURL: outside)
        XCTAssertEqual(LibraryEntryScan.read(directory: entryDir), .skipped("no metadata and no video file"))
    }

    func testMetadataNamingAnotherEntryIsSkipped() throws {
        let json =
            #"{"id":"7D2FB754-DAC3-4925-A7DE-07352E6D4DCE","name":"x","filename":"Wallpaper.mp4","duration":0,"fps":0,"resolution":[0,0],"dateAdded":0}"#
        try write("metadata.json", Data(json.utf8))
        try write("Wallpaper.mp4")
        XCTAssertEqual(LibraryEntryScan.read(directory: entryDir), .skipped("metadata id or filename mismatch or unsafe"))
    }

    func testAFileIsPlayableOnlyInARealEntryDirectory() throws {
        try write("Wallpaper.mp4")
        let file = entryDir.appendingPathComponent("Wallpaper.mp4")
        XCTAssertTrue(LibraryEntryScan.isPlayable(file))

        // After a scan, the entry directory is swapped for a symlink to a
        // directory holding a file of the same name.
        let elsewhere = videos.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: elsewhere.appendingPathComponent("Wallpaper.mp4"))
        try FileManager.default.removeItem(at: entryDir)
        try FileManager.default.createSymbolicLink(at: entryDir, withDestinationURL: elsewhere)
        XCTAssertFalse(LibraryEntryScan.isPlayable(file))
    }
}
