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

    func testBatteryTiersIgnoreTheQHDCopy() {
        let reduced = VariantSelection.variant(for: .reduced, sourceFPS: 60, sourceResolution: source, variants: variants, displayPixels: CGSize(width: 2560, height: 1440))
        let minimal = VariantSelection.variant(for: .minimal, sourceFPS: 60, sourceResolution: source, variants: variants, displayPixels: CGSize(width: 2560, height: 1440))
        XCTAssertEqual(reduced?.filename, "Wallpaper.reduced.mov")
        XCTAssertEqual(minimal?.filename, "Wallpaper.minimal.mov")
    }

    func testBatteryTiersPlayTheirOwn30FPSCopies() {
        let copies = [
            VideoVariant(filename: "Wallpaper.qhd.mov", fps: 60, resolution: CGSize(width: 2560, height: 1440)),
            VideoVariant(filename: "Wallpaper.reduced.mov", fps: 30, resolution: CGSize(width: 1920, height: 1080)),
            VideoVariant(filename: "Wallpaper.minimal.mov", fps: 30, resolution: CGSize(width: 1280, height: 720)),
        ]
        let pick = { (policy: PlaybackPolicy) in
            VariantSelection.variant(for: policy, sourceFPS: 60, sourceResolution: self.source, variants: copies)?.filename
        }
        XCTAssertEqual(pick(.reduced), "Wallpaper.reduced.mov")
        XCTAssertEqual(pick(.minimal), "Wallpaper.minimal.mov")
    }

    func testThirtyFPSSourceOnBatteryPlaysThe1080pCopyNotThe1440pOne() {
        // All copies share the source rate here; "below the source rate"
        // found nothing and fell through to 720p, or could pick 1440p.
        let copies = [
            VideoVariant(filename: "Wallpaper.qhd.mov", fps: 30, resolution: CGSize(width: 2560, height: 1440)),
            VideoVariant(filename: "Wallpaper.reduced.mov", fps: 30, resolution: CGSize(width: 1920, height: 1080)),
            VideoVariant(filename: "Wallpaper.minimal.mov", fps: 30, resolution: CGSize(width: 1280, height: 720)),
        ]
        let reduced = VariantSelection.variant(for: .reduced, sourceFPS: 30, sourceResolution: source, variants: copies)
        XCTAssertEqual(reduced?.filename, "Wallpaper.reduced.mov")
    }

    /// Same table as `NativeWallpaperDeploymentTests.qhdFitFixtures` in the
    /// app, which plans the 1440p copy only where this side would play it.
    /// Change both together.
    private let qhdFitFixtures: [(source: CGSize, fps: Double, display: CGSize, playsQHD: Bool)] = [
        (CGSize(width: 3840, height: 2160), 60, CGSize(width: 3840, height: 2160), false),
        (CGSize(width: 3840, height: 2160), 60, CGSize(width: 2560, height: 1440), true),
        (CGSize(width: 3840, height: 2160), 60, CGSize(width: 1920, height: 1080), true),
        // At 30 fps the 1080p battery copy keeps the source rate and wins.
        (CGSize(width: 3840, height: 2160), 30, CGSize(width: 1920, height: 1080), false),
        (CGSize(width: 3840, height: 2160), 30, CGSize(width: 2560, height: 1440), true),
        // A 2.39:1 source's 1440p copy is 2560x1072, too short to fill.
        (CGSize(width: 4096, height: 1716), 60, CGSize(width: 2560, height: 1440), false),
        (CGSize(width: 3840, height: 2160), 60, CGSize(width: 1440, height: 2560), false),
    ]

    func testFullQualityPicksTheQHDCopyWhereTheAppPlansIt() {
        for fixture in qhdFitFixtures {
            // The copies the app makes: battery ones capped at 30 fps, the
            // 1440p one at the source rate, sized as `copySize` scales them.
            let wide = fixture.source.width / fixture.source.height > 2
            let battery = Int(min(fixture.fps, 30).rounded())
            let copies = [
                VideoVariant(filename: "Wallpaper.reduced.mov", fps: battery,
                             resolution: wide ? CGSize(width: 1920, height: 804) : CGSize(width: 1920, height: 1080)),
                VideoVariant(filename: "Wallpaper.minimal.mov", fps: battery,
                             resolution: wide ? CGSize(width: 1280, height: 536) : CGSize(width: 1280, height: 720)),
                VideoVariant(filename: "Wallpaper.qhd.mov", fps: Int(fixture.fps.rounded()),
                             resolution: wide ? CGSize(width: 2560, height: 1072) : CGSize(width: 2560, height: 1440)),
            ]
            let pick = VariantSelection.variant(
                for: .full, sourceFPS: Int(fixture.fps.rounded()), sourceResolution: fixture.source,
                variants: copies, displayPixels: fixture.display
            )
            XCTAssertEqual(pick?.filename == "Wallpaper.qhd.mov", fixture.playsQHD, "\(fixture)")
        }
    }
}
