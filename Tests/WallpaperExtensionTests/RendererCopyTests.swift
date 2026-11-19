import Foundation
import XCTest

/// The files a renderer opens on create, switch, tier change, and wake. A
/// fake track loader stands in for AVFoundation: it opens only the files in
/// `playable` and records every attempt.
final class RendererCopyTests: XCTestCase {
    private let display = CGSize(width: 2560, height: 1440)
    private var playable: Set<String> = []
    private var attempts: [String] = []

    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/videos/\(name)") }

    /// Stands in for `makeVariantSelector`: choice `id`'s copy for a tier.
    private func selector(_ id: String) -> RendererCopy.Selector {
        { _, tier in URL(fileURLWithPath: "/videos/\(id).\(tier).mov") }
    }

    private func open(_ url: URL) -> String? {
        attempts.append(url.lastPathComponent)
        return playable.contains(url.lastPathComponent) ? url.lastPathComponent : nil
    }

    private func opened(_ name: String) -> RendererCopy.Opened<String> { .opened(name) }

    override func setUp() {
        playable = ["a.mp4", "a.full.mov", "a.reduced.mov", "b.mp4", "b.full.mov", "c.mp4", "c.reduced.mov"]
        attempts = []
    }

    // MARK: Create

    func testCreateOpensTheCopyForTheDisplayAndTier() async {
        let first = await RendererCopy.opening(url("a.mp4"), selector: selector("a"), tier: .reduced, displayPixels: display) { self.open($0) }
        XCTAssertEqual(first, "a.reduced.mov")
    }

    func testCreateFallsBackToTheOriginalWhenTheCopyHasNoVideo() async {
        playable.remove("a.reduced.mov")
        let first = await RendererCopy.opening(url("a.mp4"), selector: selector("a"), tier: .reduced, displayPixels: display) { self.open($0) }
        XCTAssertEqual(first, "a.mp4")
        XCTAssertEqual(attempts, ["a.reduced.mov", "a.mp4"])
    }

    // MARK: Switch

    func testSwitchFallsBackToTheOriginalWhenTheCopyHasNoVideo() {
        // An audio-only or deleted copy left the old wallpaper on screen
        // with the new wallpaper's selector installed.
        playable.remove("b.full.mov")
        var copy = RendererCopy(original: url("a.mp4"), selector: selector("a"))
        let result = copy.switchTo(url("b.mp4"), selector: selector("b"), current: url("a.full.mov"), tier: .full, displayPixels: display, hold: false, open: open)
        XCTAssertEqual(result, opened("b.mp4"))
        XCTAssertEqual(copy.preloadURL(current: url("b.mp4"), tier: .full, displayPixels: display).lastPathComponent, "b.full.mov")
    }

    func testSwitchThatOpensNothingKeepsTheCurrentChoice() {
        playable.subtract(["b.full.mov", "b.mp4"])
        var copy = RendererCopy(original: url("a.mp4"), selector: selector("a"))
        let result = copy.switchTo(url("b.mp4"), selector: selector("b"), current: url("a.full.mov"), tier: .full, displayPixels: display, hold: false, open: open)
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(copy.preloadURL(current: url("a.full.mov"), tier: .reduced, displayPixels: display).lastPathComponent, "a.reduced.mov")
    }

    func testSwitchToTheFilePlayingAdoptsTheSelectorWithoutReopening() {
        var copy = RendererCopy(original: url("old.mp4"), selector: selector("old"))
        let result = copy.switchTo(url("a.mp4"), selector: selector("a"), current: url("a.full.mov"), tier: .full, displayPixels: display, hold: false, open: open)
        XCTAssertEqual(result, .unchanged)
        XCTAssertEqual(attempts, [])
        XCTAssertEqual(copy.preloadURL(current: url("a.full.mov"), tier: .reduced, displayPixels: display).lastPathComponent, "a.reduced.mov")
    }

    // MARK: Sleep

    func testLatestSwitchHeldThroughSleepOpensOnWakeForTheWakeTier() {
        var copy = RendererCopy(original: url("a.mp4"), selector: selector("a"))
        for id in ["b", "c"] {
            let result = copy.switchTo(url("\(id).mp4"), selector: selector(id), current: url("a.full.mov"), tier: .full, displayPixels: display, hold: true, open: open)
            XCTAssertEqual(result, .held)
        }
        XCTAssertEqual(attempts, [], "nothing opens while the displays sleep")
        XCTAssertEqual(copy.wake(current: url("a.full.mov"), tier: .reduced, displayPixels: display, open: open), opened("c.reduced.mov"))
        XCTAssertEqual(copy.wake(current: url("c.reduced.mov"), tier: .reduced, displayPixels: display, open: open), .unchanged)
    }

    func testHeldSwitchFallsBackToTheOriginalOnWake() {
        var copy = RendererCopy(original: url("a.mp4"), selector: selector("a"))
        _ = copy.switchTo(url("c.mp4"), selector: selector("c"), current: url("a.full.mov"), tier: .full, displayPixels: display, hold: true, open: open)
        XCTAssertEqual(copy.wake(current: url("a.full.mov"), tier: .full, displayPixels: display, open: open), opened("c.mp4"))
        XCTAssertEqual(attempts, ["c.full.mov", "c.mp4"])
    }

    func testPausedWakeWithNothingHeldKeepsTheCurrentCopy() {
        var copy = RendererCopy(original: url("a.mp4"), selector: selector("a"))
        XCTAssertEqual(copy.wake(current: url("a.reduced.mov"), tier: .paused, displayPixels: display, open: open), .unchanged)
        XCTAssertEqual(attempts, [])
    }

    // MARK: Closed surfaces

    func testSwitchHeldWhileClosedOpensOnReopen() {
        // A shuffle or automation switch reaching an invalidated surface
        // used to decode the new video's first frame into the held image.
        var copy = RendererCopy(original: url("a.mp4"), selector: selector("a"))
        XCTAssertEqual(copy.switchTo(url("b.mp4"), selector: selector("b"), current: url("a.full.mov"), tier: .full, displayPixels: display, hold: true, open: open), .held)
        XCTAssertEqual(attempts, [])
        XCTAssertEqual(copy.reopen(current: url("a.full.mov"), tier: .full, displayPixels: display, open: open), opened("b.full.mov"))
    }

    func testReopenWithNothingHeldKeepsTheCurrentCopyThroughATierChange() {
        // Reopening resumes in place; the tier's copy waits for the loop.
        var copy = RendererCopy(original: url("a.mp4"), selector: selector("a"))
        XCTAssertEqual(copy.reopen(current: url("a.full.mov"), tier: .reduced, displayPixels: display, open: open), .unchanged)
        XCTAssertEqual(attempts, [])
    }

    // MARK: Tier changes

    func testPausedRendererResumingOnBatteryMovesToTheBatteryCopy() async {
        let first = await RendererCopy.opening(url("a.mp4"), selector: selector("a"), tier: .paused, displayPixels: display) { self.open($0) }
        XCTAssertEqual(first, "a.full.mov")
        var copy = RendererCopy(original: url("a.mp4"), selector: selector("a"))
        XCTAssertEqual(copy.preloadURL(current: url("a.full.mov"), tier: .paused, displayPixels: display).lastPathComponent, "a.full.mov")
        XCTAssertEqual(copy.retier(current: url("a.full.mov"), tier: .reduced, displayPixels: display, open: open), opened("a.reduced.mov"))
    }

    func testTierCopyThatWontOpenFallsBackToTheOriginal() {
        // Create opened the reduced copy; the tier went to Full while it
        // loaded and the Full copy has no video. The original still plays.
        playable.remove("a.full.mov")
        var copy = RendererCopy(original: url("a.mp4"), selector: selector("a"))
        XCTAssertEqual(copy.retier(current: url("a.reduced.mov"), tier: .full, displayPixels: display, open: open), opened("a.mp4"))
        XCTAssertEqual(attempts, ["a.full.mov", "a.mp4"])
    }

    func testPauseRecordedBeforeStartOpensTheFullCopy() {
        // Created on Reduced; a pause reached the renderer before start(),
        // so start reselects for the tier now, not the one it recorded.
        var copy = RendererCopy(original: url("a.mp4"), selector: selector("a"))
        XCTAssertEqual(copy.retier(current: url("a.reduced.mov"), tier: .paused, displayPixels: display, open: open), opened("a.full.mov"))
    }

    func testWakeTierChangeFallsBackToTheOriginal() {
        playable.remove("a.reduced.mov")
        var copy = RendererCopy(original: url("a.mp4"), selector: selector("a"))
        XCTAssertEqual(copy.wake(current: url("a.full.mov"), tier: .reduced, displayPixels: display, open: open), opened("a.mp4"))
    }

    func testTierChangeAfterASwitchFallsBackToTheNewChoicesOriginal() {
        var copy = RendererCopy(original: url("a.mp4"), selector: selector("a"))
        XCTAssertEqual(copy.switchTo(url("b.mp4"), selector: selector("b"), current: url("a.full.mov"), tier: .full, displayPixels: display, hold: false, open: open), opened("b.full.mov"))
        XCTAssertEqual(copy.retier(current: url("b.full.mov"), tier: .reduced, displayPixels: display, open: open), opened("b.mp4"))
    }
}
