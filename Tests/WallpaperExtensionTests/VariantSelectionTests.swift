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

    func testFullQualityPicksTheQHDCopyWhereTheAppPlansIt() {
        // Rows shared with the app's planning test (QHDFitFixtures.swift).
        for fixture in QHDFitFixtures.rows {
            // Battery copies are capped at 30 fps; the 1440p one keeps the source rate.
            let battery = Int(min(fixture.fps, 30).rounded())
            let copies = [
                VideoVariant(filename: "Wallpaper.reduced.mov", fps: battery, resolution: fixture.reduced),
                VideoVariant(filename: "Wallpaper.minimal.mov", fps: battery, resolution: fixture.minimal),
                VideoVariant(filename: "Wallpaper.qhd.mov", fps: Int(fixture.fps.rounded()), resolution: fixture.qhd),
            ]
            let pick = VariantSelection.variant(
                for: .full, sourceFPS: Int(fixture.fps.rounded()), sourceResolution: fixture.source,
                variants: copies, displayPixels: fixture.display
            )
            XCTAssertEqual(pick?.filename == "Wallpaper.qhd.mov", fixture.playsQHD, "\(fixture)")
        }
    }
}

/// The file a renderer opens for a new asset, before any loop boundary.
final class OpeningURLTests: XCTestCase {
    private let original = URL(fileURLWithPath: "/videos/a/Wallpaper.mp4")
    private let qhdDisplay = CGSize(width: 2560, height: 1440)

    /// Stands in for `makeVariantSelector`: names the copy after the tier
    /// and records the display size it was asked for.
    private func selector(_ display: CGSize, _ tier: PlaybackPolicy) -> URL {
        URL(fileURLWithPath: "/videos/a/\(tier)-\(Int(display.width))x\(Int(display.height)).mov")
    }

    private func opening(_ tier: PlaybackPolicy) -> String {
        VariantSelection.openingURL(requested: original, tier: tier, displayPixels: qhdDisplay, selector: selector).lastPathComponent
    }

    func testOpensTheCopyForTheDisplayAndTierInsteadOfTheOriginal() {
        // Acquire, shuffle, and automation hand over the original; a 1440p
        // display decoded 4K for one loop before the preload swapped in its copy.
        XCTAssertEqual(opening(.full), "full-2560x1440.mov")
        XCTAssertEqual(opening(.reduced), "reduced-2560x1440.mov")
        XCTAssertEqual(opening(.minimal), "minimal-2560x1440.mov")
    }

    func testPausedOpensTheFullCopy() {
        // Paused resolves to the original, which would decode 4K for the held
        // frame and then rebuild on the copy when playback resumes.
        XCTAssertEqual(opening(.paused), "full-2560x1440.mov")
    }

    func testWithoutASelectorOpensTheRequestedFile() {
        let url = VariantSelection.openingURL(requested: original, tier: .full, displayPixels: qhdDisplay, selector: nil)
        XCTAssertEqual(url, original)
    }
}

/// The file preloaded for the next loop.
final class PreloadURLTests: XCTestCase {
    private let reducedCopy = URL(fileURLWithPath: "/videos/a/Wallpaper.reduced.mov")
    private let display = CGSize(width: 2560, height: 1440)

    private func selector(_: CGSize, _ tier: PlaybackPolicy) -> URL {
        URL(fileURLWithPath: "/videos/a/\(tier).mov")
    }

    func testPlayingTiersPreloadWhatTheyWouldOpen() {
        for tier in [PlaybackPolicy.full, .reduced, .minimal] {
            XCTAssertEqual(
                VariantSelection.preloadURL(current: reducedCopy, tier: tier, displayPixels: display, selector: selector),
                VariantSelection.openingURL(requested: reducedCopy, tier: tier, displayPixels: display, selector: selector),
                "\(tier)",
            )
        }
    }

    func testPausedKeepsTheCurrentCopy() {
        XCTAssertEqual(
            VariantSelection.preloadURL(current: reducedCopy, tier: .paused, displayPixels: display, selector: selector),
            reducedCopy,
        )
    }
}
