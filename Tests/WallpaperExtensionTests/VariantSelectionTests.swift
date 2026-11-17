import Foundation
import XCTest

/// The extension target can't host tests, so this bundle compiles the
/// extension's pure selection sources directly (see project.yml).
final class VariantSelectionTests: XCTestCase {
    private let source = CGSize(width: 3840, height: 2160)
    private let variants = [
        VideoVariant(filename: "Wallpaper.qhd.mov", fps: 60, resolution: CGSize(width: 2560, height: 1440)),
        VideoVariant(filename: "Wallpaper.reduced.mov", fps: 60, resolution: CGSize(width: 1920, height: 1080)),
        VideoVariant(filename: "Wallpaper.minimal.mov", fps: 60, resolution: CGSize(width: 1280, height: 720)),
    ]

    private func full(display: CGSize?) -> String? {
        VariantSelection.variant(for: .full, sourceFPS: 60, sourceResolution: source, variants: variants, displayPixels: display)?.filename
    }

    func testFullOnA1440pMonitorPlaysTheQHDCopy() {
        // A 2560x1440 monitor at 1x can't show more than 1440p, so decoding
        // the 4K original wasted 56% of the decode work.
        XCTAssertEqual(full(display: CGSize(width: 2560, height: 1440)), "Wallpaper.qhd.mov")
    }

    func testFullOnA1080pMonitorPlaysThe1080pCopy() {
        XCTAssertEqual(full(display: CGSize(width: 1920, height: 1080)), "Wallpaper.reduced.mov")
    }

    func testFullOnARetinaPanelKeepsTheOriginal() {
        // 1800x1169 points at 2x needs more than 4K under aspect fill.
        XCTAssertNil(full(display: CGSize(width: 3600, height: 2338)))
    }

    func testPortraitMonitorKeepsTheOriginal() {
        // Aspect-filling 1080x1920 from a 16:9 video scales by height:
        // 1080p would be upscaled 1.78x, so only the original is sharp.
        XCTAssertNil(full(display: CGSize(width: 1080, height: 1920)))
    }

    func testCopiesBelowTheSourceFrameRateNeverServeFull() {
        let slow = [VideoVariant(filename: "Wallpaper.reduced.mov", fps: 30, resolution: CGSize(width: 1920, height: 1080))]
        let pick = VariantSelection.variant(for: .full, sourceFPS: 60, sourceResolution: source, variants: slow, displayPixels: CGSize(width: 1920, height: 1080))
        XCTAssertNil(pick)
    }

    func testUnknownDisplayKeepsTheOriginal() {
        XCTAssertNil(full(display: nil))
    }

    func testBatteryTiersAreUnchangedByTheQHDCopy() {
        let reduced = VariantSelection.variant(for: .reduced, sourceFPS: 60, sourceResolution: source, variants: variants, displayPixels: CGSize(width: 2560, height: 1440))
        let minimal = VariantSelection.variant(for: .minimal, sourceFPS: 60, sourceResolution: source, variants: variants, displayPixels: CGSize(width: 2560, height: 1440))
        XCTAssertEqual(reduced?.filename, "Wallpaper.minimal.mov")
        XCTAssertEqual(minimal?.filename, "Wallpaper.minimal.mov")
    }
}
