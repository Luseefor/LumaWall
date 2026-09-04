import CoreGraphics
import Foundation
import Testing
@testable import LumaWallCore

/// Display-model helpers: filter matching, crop defaults, labels, and legacy
/// decoding. All pure logic with specific assertions per branch.
struct WallpaperModelsTests {
    @Test func resolutionFilterMatchesBands() {
        #expect(ResolutionFilter.all.matches(CGSize(width: 640, height: 480)))
        #expect(ResolutionFilter.hd.matches(CGSize(width: 1920, height: 1080)))
        #expect(!ResolutionFilter.hd.matches(CGSize(width: 1280, height: 720)))
        #expect(ResolutionFilter.qhd.matches(CGSize(width: 2560, height: 1440)))
        #expect(!ResolutionFilter.qhd.matches(CGSize(width: 1920, height: 1080)))
        #expect(ResolutionFilter.fourK.matches(CGSize(width: 3840, height: 2160)))
        #expect(ResolutionFilter.fourK.matches(CGSize(width: 2160, height: 3840)))
        #expect(!ResolutionFilter.fourK.matches(CGSize(width: 2560, height: 1440)))
    }

    @Test func categoryAndSortTitlesAreDistinctAndNonEmpty() {
        let categoryTitles = WallpaperCategory.allCases.map(\.title)
        #expect(Set(categoryTitles).count == categoryTitles.count)
        #expect(categoryTitles.allSatisfy { !$0.isEmpty })
        let sortTitles = LibrarySort.allCases.map(\.title)
        #expect(Set(sortTitles).count == sortTitles.count)
        let filterTitles = ResolutionFilter.allCases.map(\.title)
        #expect(Set(filterTitles).count == filterTitles.count)
    }

    @Test func categorySymbolsAreDistinctSystemNames() {
        let symbols = WallpaperCategory.allCases.map(\.symbol)
        #expect(Set(symbols).count == symbols.count)
        #expect(symbols.allSatisfy { !$0.isEmpty })
        #expect(WallpaperCategory.nature.symbol == "leaf.fill")
        #expect(WallpaperCategory.space.symbol == "sparkles")
    }

    @Test func idRoundTripsThroughRawValues() {
        let uuid = UUID()
        #expect(WallpaperID(rawValue: uuid).rawValue == uuid)
        #expect(WallpaperCategory.nature.id == "nature")
        #expect(LibrarySort.newest.id == "newest")
        #expect(ResolutionFilter.hd.id == "hd")
    }

    @Test func defaultCropDetectsEveryDeviation() {
        #expect(DisplayComposition().usesDefaultCrop)
        #expect(!DisplayComposition(contentMode: .fit).usesDefaultCrop)
        #expect(!DisplayComposition(scale: 1.5).usesDefaultCrop)
        #expect(!DisplayComposition(rotationDegrees: 90).usesDefaultCrop)
        #expect(!DisplayComposition(offset: CGPoint(x: 10, y: 0)).usesDefaultCrop)
        #expect(!DisplayComposition(focalPoint: CGPoint(x: 0, y: 0)).usesDefaultCrop)
        // Spanning canvas alone must NOT trip the crop check (native routing
        // depends on usesDefaultCrop with a canvas set).
        #expect(DisplayComposition(spanningCanvas: CGRect(x: 0, y: 0, width: 3840, height: 1080)).usesDefaultCrop)
    }

    @Test func resolutionLabelBands() {
        #expect(label(for: CGSize(width: 3840, height: 2160)) == "4K")
        #expect(label(for: CGSize(width: 2160, height: 3840)) == "4K")
        #expect(label(for: CGSize(width: 2560, height: 1440)) == "1440p")
        #expect(label(for: CGSize(width: 1920, height: 1080)) == "1080p")
        #expect(label(for: CGSize(width: 1280, height: 720)) == "1280×720")
    }

    @Test func legacyDecodingFillsModernDefaults() throws {
        let legacy = """
        {"id":{"rawValue":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"},"name":"Legacy","mediaURL":"file:///tmp/a.mov","duration":10,"framesPerSecond":30,"pixelSize":[1920,1080],"contentHash":"legacy","containsAudio":false}
        """
        let asset = try JSONDecoder.lumaWall.decode(WallpaperAsset.self, from: Data(legacy.utf8))
        #expect(asset.category == .other)
        #expect(asset.applyCount == 0)
        #expect(asset.lastAppliedAt == nil)
    }

    @Test func assignmentIdentityIsDisplayID() {
        let id = DisplayID(rawValue: "display-x")
        #expect(DisplayAssignment(displayID: id).id == id)
        #expect(DisplayAssignment(displayID: id).isEnabled)
    }

    private func label(for size: CGSize) -> String {
        WallpaperAsset(
            name: "x",
            mediaURL: URL(fileURLWithPath: "/tmp/x.mov"),
            duration: 1,
            framesPerSecond: 30,
            pixelSize: size,
            contentHash: "x",
            containsAudio: false
        ).resolutionLabel
    }
}
