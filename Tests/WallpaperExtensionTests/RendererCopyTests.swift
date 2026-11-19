import Foundation
import os
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

    func testTheActiveOriginalChangesOnlyWhenASwitchOpens() {
        // The give-up still is looked up for this file, so a held or failed
        // switch must not move it.
        var copy = RendererCopy(original: url("a.mp4"), selector: selector("a"))
        _ = copy.switchTo(url("c.mp4"), selector: selector("c"), current: url("a.full.mov"), tier: .full, displayPixels: display, hold: true, open: open)
        XCTAssertEqual(copy.activeOriginal, url("a.mp4"))
        _ = copy.wake(current: url("a.full.mov"), tier: .reduced, displayPixels: display, open: open)
        XCTAssertEqual(copy.activeOriginal, url("c.mp4"))
        _ = copy.switchTo(url("b.mp4"), selector: selector("b"), current: url("c.reduced.mov"), tier: .full, displayPixels: display, hold: true, open: open)
        _ = copy.reopen(current: url("c.reduced.mov"), tier: .full, displayPixels: display, open: open)
        XCTAssertEqual(copy.activeOriginal, url("b.mp4"))
        playable.subtract(["c.full.mov", "c.mp4"])
        XCTAssertEqual(copy.switchTo(url("c.mp4"), selector: selector("c"), current: url("b.full.mov"), tier: .full, displayPixels: display, hold: false, open: open), .failed)
        XCTAssertEqual(copy.activeOriginal, url("b.mp4"))
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

    func testLoopBoundaryReplacesAPreloadMadeForAnOlderTier() {
        // The tier moved to Reduced while the surface was closed; the reader
        // preloaded at Full would have played one more loop of the Full copy.
        let copy = RendererCopy(original: url("a.mp4"), selector: selector("a"))
        XCTAssertEqual(copy.loopReplacement(preloaded: url("a.full.mov"), current: url("a.full.mov"), tier: .reduced, displayPixels: display), url("a.reduced.mov"))
        XCTAssertNil(copy.loopReplacement(preloaded: url("a.full.mov"), current: url("a.full.mov"), tier: .full, displayPixels: display))
        XCTAssertNil(copy.loopReplacement(preloaded: url("a.full.mov"), current: url("a.full.mov"), tier: .paused, displayPixels: display), "paused keeps the current copy")
    }

    /// Starts every reader except those in `failing`, recording each try.
    private func loopReader(_ copy: RendererCopy, preloaded: URL?, tier: PlaybackPolicy, failing: Set<RendererCopy.LoopSource>) -> RendererCopy.LoopSource? {
        copy.loopReader(preloaded: preloaded, current: url("a.full.mov"), tier: tier, displayPixels: display) { source -> RendererCopy.LoopSource? in
            attempts.append("\(source)")
            return failing.contains(source) ? nil : source
        }?.source
    }

    func testALoopReplacementThatWontStartKeepsThePreload() {
        // The swap dropped the preload before the replacement's reader
        // started, so a failed start sent recovery to the replacement and
        // the wallpaper could fall back to a still.
        let copy = RendererCopy(original: url("a.mp4"), selector: selector("a"))
        let replacement = RendererCopy.LoopSource.replacement(url("a.reduced.mov"))
        XCTAssertEqual(loopReader(copy, preloaded: url("a.full.mov"), tier: .reduced, failing: [replacement]), .preload)
        XCTAssertEqual(attempts, ["\(replacement)", "preload"])
    }

    func testALoopReplacementThatStartsIsPlayedWithoutTouchingThePreload() {
        let copy = RendererCopy(original: url("a.mp4"), selector: selector("a"))
        XCTAssertEqual(loopReader(copy, preloaded: url("a.full.mov"), tier: .reduced, failing: []), .replacement(url("a.reduced.mov")))
        XCTAssertEqual(attempts.count, 1)
    }

    func testALoopWithNoUsablePreloadReadsTheCurrentFileAgain() {
        let copy = RendererCopy(original: url("a.mp4"), selector: selector("a"))
        XCTAssertEqual(loopReader(copy, preloaded: url("a.full.mov"), tier: .full, failing: [.preload]), .current)
        XCTAssertEqual(loopReader(copy, preloaded: nil, tier: .reduced, failing: [.replacement(url("a.reduced.mov"))]), .current)
        XCTAssertNil(loopReader(copy, preloaded: nil, tier: .full, failing: [.current]), "nothing starts: the feed reports the missing reader")
    }

    // MARK: Previews

    func testPreviewWithoutACopyForItsTierHoldsAFrame() {
        // The Settings picker decoded the full-resolution original for a
        // small tile when no copy fit its viewport (#35).
        let onlyReduced: RendererCopy.Selector = { _, tier in
            URL(fileURLWithPath: tier == .reduced ? "/videos/a.reduced.mov" : "/videos/a.mp4")
        }
        let copy = RendererCopy(original: url("a.mp4"), selector: onlyReduced)
        XCTAssertEqual(copy.previewTier(.full, displayPixels: display), .paused)
        XCTAssertEqual(copy.previewTier(.minimal, displayPixels: display), .paused)
        XCTAssertEqual(copy.previewTier(.reduced, displayPixels: display), .reduced)
        XCTAssertEqual(copy.previewTier(.paused, displayPixels: display), .paused)
    }

    func testPreviewPlayingTheOriginalBecauseItsCopyFailedHoldsAFrame() {
        // The selector names a copy, but it had no video and the original
        // opened instead: judge the file that is actually playing.
        let copy = RendererCopy(original: url("a.mp4"), selector: selector("a"))
        XCTAssertEqual(copy.previewTier(.full, displayPixels: display, playing: url("a.mp4")), .paused)
        XCTAssertEqual(copy.previewTier(.full, displayPixels: display, playing: url("a.full.mov")), .full)
    }

    func testPreviewTierFollowsTheChoiceAHeldSwitchOpened() {
        let originalOnly: RendererCopy.Selector = { _, _ in URL(fileURLWithPath: "/videos/b.mp4") }
        var copy = RendererCopy(original: url("a.mp4"), selector: selector("a"))
        XCTAssertEqual(copy.previewTier(.full, displayPixels: display), .full)
        _ = copy.switchTo(url("b.mp4"), selector: originalOnly, current: url("a.full.mov"), tier: .full, displayPixels: display, hold: true, open: open)
        XCTAssertEqual(copy.reopen(current: url("a.full.mov"), tier: .full, displayPixels: display, open: open), opened("b.mp4"))
        XCTAssertEqual(copy.previewTier(.full, displayPixels: display, playing: url("b.mp4")), .paused)
    }

    func testPreviewWithAViewportCopyPlaysIt() {
        let copy = RendererCopy(original: url("a.mp4"), selector: selector("a"))
        XCTAssertEqual(copy.previewTier(.full, displayPixels: display), .full)
    }

    /// Create's open and seed: records the seed's hold decision in
    /// `attempts` after the opens that led to it.
    private func openSeeded(_ selector: @escaping RendererCopy.Selector, tier: PlaybackPolicy, isPreview: Bool = true) async -> (loaded: String, seed: Bool)? {
        await RendererCopy.openingSeeded(url("a.mp4"), selector: selector, tier: tier, displayPixels: display, isPreview: isPreview) {
            self.open($0)
        } seed: { holds in
            self.attempts.append("seed(holds: \(holds))")
            return holds
        }
    }

    func testPreviewThatOpensTheOriginalHoldsItWithoutDecoding() async {
        let originalOnly: RendererCopy.Selector = { _, _ in URL(fileURLWithPath: "/videos/a.mp4") }
        let noCopy = await openSeeded(originalOnly, tier: .full)
        XCTAssertEqual(noCopy?.loaded, "a.mp4")
        XCTAssertEqual(noCopy?.seed, true)
        let withCopy = await openSeeded(selector("a"), tier: .full)
        XCTAssertEqual(withCopy?.loaded, "a.full.mov")
        XCTAssertEqual(withCopy?.seed, false)
        // A paused preview opens the Full copy, which is cheap to decode.
        let paused = await openSeeded(selector("a"), tier: .paused)
        XCTAssertEqual(paused?.seed, false)
        let live = await openSeeded(originalOnly, tier: .full, isPreview: false)
        XCTAssertEqual(live?.seed, false, "a live renderer plays the original")
        let copy = RendererCopy(original: url("a.mp4"), selector: selector("a"))
        XCTAssertTrue(copy.isOriginal(URL(fileURLWithPath: "/videos/./a.mp4")))
        XCTAssertFalse(copy.isOriginal(url("a.full.mov")))
    }

    func testPreviewSeedIsDecidedFromTheFileCreateOpened() async {
        // The seed used to be decided from its own tier read before create
        // read the tier again. Now it follows the open: a copy with no
        // video leaves the renderer on the original, holding, so the seed
        // mustn't decode the original's first frame.
        playable.remove("a.reduced.mov")
        let result = await openSeeded(selector("a"), tier: .reduced)
        XCTAssertEqual(result?.loaded, "a.mp4")
        XCTAssertEqual(result?.seed, true)
        XCTAssertEqual(attempts, ["a.reduced.mov", "a.mp4", "seed(holds: true)"])
    }

    func testNothingOpensSeedsNothing() async {
        playable.subtract(["a.full.mov", "a.mp4"])
        let result = await openSeeded(selector("a"), tier: .full)
        XCTAssertNil(result)
        XCTAssertEqual(attempts, ["a.full.mov", "a.mp4"])
    }

    func testStartKeepsAPreviewThatCreateLeftOnACopyOffTheOriginal() {
        // Create opened the Reduced copy and seeded with no hold. The tier
        // moved before start to one with no copy: moving to the original
        // would hold a frame of it the seed had just decoded.
        let reducedOnly: RendererCopy.Selector = { _, tier in
            URL(fileURLWithPath: tier == .reduced ? "/videos/a.reduced.mov" : "/videos/a.mp4")
        }
        var preview = RendererCopy(original: url("a.mp4"), selector: reducedOnly)
        XCTAssertEqual(preview.retierAtStart(current: url("a.reduced.mov"), tier: .full, displayPixels: display, isPreview: true, open: open), .failed)
        XCTAssertEqual(attempts, [], "the original isn't opened")
        var live = RendererCopy(original: url("a.mp4"), selector: reducedOnly)
        XCTAssertEqual(live.retierAtStart(current: url("a.reduced.mov"), tier: .full, displayPixels: display, isPreview: false, open: open), opened("a.mp4"))
        // A preview create left on the original still moves to a copy.
        var held = RendererCopy(original: url("a.mp4"), selector: reducedOnly)
        XCTAssertEqual(held.retierAtStart(current: url("a.mp4"), tier: .reduced, displayPixels: display, isPreview: true, open: open), opened("a.reduced.mov"))
    }

    func testPreviewHoldsItsSeedOnlyWhileTheSeedIsOfTheChoiceItOpened() {
        // A switch before start() leaves the previous choice's still in the
        // layer; holding it would show the wrong wallpaper.
        var copy = RendererCopy(original: url("a.mp4"), selector: { _, _ in URL(fileURLWithPath: "/videos/a.mp4") })
        XCTAssertTrue(copy.previewHoldsSeed(playing: url("a.mp4"), seedOf: url("a.mp4")))
        XCTAssertFalse(copy.previewHoldsSeed(playing: url("a.mp4"), seedOf: nil), "nothing seeded")
        XCTAssertFalse(copy.previewHoldsSeed(playing: url("a.full.mov"), seedOf: url("a.mp4")), "a copy plays")
        let originalOnly: RendererCopy.Selector = { _, _ in URL(fileURLWithPath: "/videos/b.mp4") }
        XCTAssertEqual(copy.switchTo(url("b.mp4"), selector: originalOnly, current: url("a.mp4"), tier: .full, displayPixels: display, hold: false, open: open), opened("b.mp4"))
        XCTAssertFalse(copy.previewHoldsSeed(playing: url("b.mp4"), seedOf: url("a.mp4")))
    }

    func testHeldPreviewPlaysACopyPublishedLater() {
        // The selector reads the library each time, so the recheck after a
        // rescan moves a held preview onto the new copy.
        let published = OSAllocatedUnfairLock(initialState: false)
        let library: RendererCopy.Selector = { _, tier in
            URL(fileURLWithPath: published.withLock { $0 } ? "/videos/a.\(tier).mov" : "/videos/a.mp4")
        }
        var copy = RendererCopy(original: url("a.mp4"), selector: library)
        XCTAssertEqual(copy.previewTier(.full, displayPixels: display, playing: url("a.mp4")), .paused)
        published.withLock { $0 = true }
        XCTAssertEqual(copy.previewTier(.full, displayPixels: display), .full)
        XCTAssertEqual(copy.retier(current: url("a.mp4"), tier: .full, displayPixels: display, open: open), opened("a.full.mov"))
    }

    func testLiveTakeoverKeepsOnlyAStillOfTheActiveChoice() {
        let copy = RendererCopy(original: url("a.mp4"), selector: selector("a"))
        XCTAssertTrue(copy.liveKeepsSeed(seedOf: url("a.mp4"), seedIsStill: true))
        XCTAssertFalse(copy.liveKeepsSeed(seedOf: url("a.mp4"), seedIsStill: false), "the gradient")
        XCTAssertFalse(copy.liveKeepsSeed(seedOf: url("b.mp4"), seedIsStill: true), "another choice's still")
        XCTAssertFalse(copy.liveKeepsSeed(seedOf: nil, seedIsStill: false), "nothing seeded")
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
