import XCTest

/// Orderings on the renderer queue that kept a surface decoding with the
/// displays off, or overlapped two decoder flushes (#10).
final class RendererLifecycleTests: XCTestCase {
    private typealias Effect = RendererLifecycle.Effect

    /// A renderer that has started and is playing on an awake display.
    private func playing() -> RendererLifecycle {
        var life = RendererLifecycle()
        XCTAssertEqual(life.handle(.started(displayAsleep: false)), [.setRate(1), .startFeeding(generation: 0)])
        return life
    }

    private func assertStoppedAndIdle(_ life: RendererLifecycle, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(life.clock, .stopped, file: file, line: line)
        XCTAssertFalse(life.feeding, file: file, line: line)
    }

    // MARK: Policy updates and sleep

    func testPolicyUpdateDuringSleepRecordsTheTierWithoutPlaying() {
        var life = playing()
        XCTAssertEqual(life.handle(.displaySleep), [.setRate(0), .stopFeeding, .armDeepPause])
        for tier in [PlaybackPolicy.reduced, .minimal, .full] {
            XCTAssertEqual(life.handle(.policy(tier, animated: true)), [], "\(tier)")
            XCTAssertEqual(life.policy, tier)
        }
        assertStoppedAndIdle(life)
    }

    func testUpdateDecidedBeforeSleepIsUndoneBySleep() {
        // A power update queued its resume before the sleep event: the sleep
        // event still lands after it on the same queue and stops playback.
        var life = playing()
        _ = life.handle(.policy(.paused, animated: false))
        XCTAssertEqual(life.handle(.policy(.full, animated: true)), [.ramp(to: 1), .startFeeding(generation: 0), .disarmDeepPause])
        XCTAssertEqual(life.handle(.displaySleep), [.setRate(0), .stopFeeding, .armDeepPause])
        assertStoppedAndIdle(life)
    }

    func testWakeResumesTheLatestTierWithoutARecompute() {
        // Previews get no policy recompute on wake; their tier never changed.
        var life = playing()
        _ = life.handle(.displaySleep)
        XCTAssertEqual(life.handle(.displayWake(assetChanged: false)), [.setRate(1), .startFeeding(generation: 0), .disarmDeepPause])
    }

    func testWakeIntoAPausedTierStaysPaused() {
        var life = playing()
        _ = life.handle(.displaySleep)
        _ = life.handle(.policy(.paused, animated: false))
        XCTAssertEqual(life.handle(.displayWake(assetChanged: false)), [])
        assertStoppedAndIdle(life)
        XCTAssertTrue(life.deepPauseArmed)
    }

    func testSleepCutsARampDownShort() {
        var life = playing()
        XCTAssertEqual(life.handle(.policy(.paused, animated: true)), [.ramp(to: 0)])
        XCTAssertTrue(life.feeding, "the ramp-down still shows frames")
        XCTAssertEqual(life.handle(.displaySleep), [.setRate(0), .stopFeeding, .armDeepPause])
        // The cancelled ramp's completion, if it was already queued, is a no-op.
        XCTAssertEqual(life.handle(.rampFinished), [])
    }

    func testAwakeRampsAreUnchanged() {
        var life = playing()
        XCTAssertEqual(life.handle(.policy(.paused, animated: true)), [.ramp(to: 0)])
        XCTAssertEqual(life.handle(.rampFinished), [.stopFeeding, .armDeepPause])
        XCTAssertEqual(life.handle(.policy(.full, animated: true)), [.ramp(to: 1), .startFeeding(generation: 0), .disarmDeepPause])
        XCTAssertEqual(life.handle(.rampFinished), [])
        XCTAssertEqual(life.clock, .playing)
    }

    // MARK: Start

    func testStartDuringSleepHoldsTheClock() {
        var life = RendererLifecycle()
        XCTAssertEqual(life.handle(.started(displayAsleep: true)), [.armDeepPause])
        assertStoppedAndIdle(life)
    }

    func testSwitchBeforeStartIsLeftToStart() {
        var life = RendererLifecycle()
        XCTAssertEqual(life.handle(.assetChanged), [])
        XCTAssertEqual(life.handle(.started(displayAsleep: false)), [.setRate(1), .startFeeding(generation: 0)])
    }

    // MARK: Feed, loop, and deep pause

    func testLoopBoundaryQueuedBeforeSleepWaitsForWake() {
        var life = playing()
        _ = life.handle(.displaySleep)
        XCTAssertEqual(life.handle(.readerExhausted(generation: 0)), [])
        XCTAssertTrue(life.loopPending)
        XCTAssertEqual(
            life.handle(.displayWake(assetChanged: false)),
            [.setRate(1), .swapToNextReader, .startFeeding(generation: 0), .disarmDeepPause],
        )
    }

    func testDeepPausedRendererRebuildsOnWake() {
        var life = playing()
        _ = life.handle(.displaySleep)
        XCTAssertEqual(life.handle(.deepPauseFired), [.freeReaders])
        XCTAssertEqual(life.handle(.displayWake(assetChanged: false)), [.beginReset(.resume, generation: 2)])
        XCTAssertEqual(life.handle(.resetFlushed(generation: 2)), [.buildPipeline(.resume), .setRate(1), .startFeeding(generation: 2)])
    }

    func testFeedCallbackFromAFreedPipelineIsDropped() {
        var life = playing()
        _ = life.handle(.displaySleep)
        _ = life.handle(.deepPauseFired)
        XCTAssertEqual(life.handle(.readerExhausted(generation: 0)), [])
        XCTAssertEqual(life.handle(.decoderFailed(generation: 0)), [])
        XCTAssertFalse(life.loopPending)
    }

    // MARK: Switches and resets

    func testSwitchDuringSleepWaitsForWake() {
        var life = playing()
        _ = life.handle(.displaySleep)
        XCTAssertEqual(life.handle(.switchDeferred(URL(fileURLWithPath: "/b.mov"))), [])
        XCTAssertEqual(life.handle(.switchDeferred(URL(fileURLWithPath: "/a.mov"))), [])
        XCTAssertEqual(life.deferredSwitch, URL(fileURLWithPath: "/a.mov"))
        XCTAssertEqual(life.handle(.displayWake(assetChanged: true)), [.disarmDeepPause, .beginReset(.restart, generation: 1)])
        XCTAssertNil(life.deferredSwitch)
        XCTAssertEqual(life.handle(.resetFlushed(generation: 1)), [.buildPipeline(.restart), .setRate(1), .startFeeding(generation: 1)])
    }

    func testDeferredSwitchIntoAPausedDesktopShowsTheFrameAndRearmsDeepPause() {
        var life = playing()
        _ = life.handle(.policy(.paused, animated: false))
        _ = life.handle(.displaySleep)
        XCTAssertEqual(life.handle(.deepPauseFired), [.freeReaders])
        _ = life.handle(.switchDeferred(URL(fileURLWithPath: "/b.mov")))
        XCTAssertEqual(life.handle(.displayWake(assetChanged: true)), [.beginReset(.restart, generation: 2)])
        XCTAssertEqual(life.handle(.resetFlushed(generation: 2)), [.buildPipeline(.restart), .armDeepPause])
        assertStoppedAndIdle(life)
    }

    func testDeferredSwitchMeetingQueuedRecoveryFlushesOnce() {
        // The feed saw a failed decoder just before sleep and queued recovery
        // behind the wake switch. Only the switch's reset may flush.
        var life = playing()
        _ = life.handle(.displaySleep)
        _ = life.handle(.switchDeferred(URL(fileURLWithPath: "/b.mov")))
        var effects = life.handle(.displayWake(assetChanged: true))
        effects += life.handle(.decoderFailed(generation: 0))
        effects += life.handle(.resetFlushed(generation: 1))
        XCTAssertEqual(effects.filter(\.isReset), [.beginReset(.restart, generation: 1)])
        XCTAssertEqual(life.clock, .playing)
    }

    func testRequestsDuringAFlushMergeIntoIt() {
        var life = playing()
        XCTAssertEqual(life.handle(.decoderFailed(generation: 0)), [.beginReset(.recover, generation: 1)])
        XCTAssertEqual(life.handle(.assetChanged), [])
        XCTAssertEqual(life.handle(.policy(.reduced, animated: false)), [])
        XCTAssertEqual(life.handle(.resetFlushed(generation: 1)), [.buildPipeline(.recover), .setRate(1), .startFeeding(generation: 1)])
    }

    func testFlushCompletingDuringSleepBuildsOnWake() {
        var life = playing()
        XCTAssertEqual(life.handle(.assetChanged), [.beginReset(.restart, generation: 1)])
        XCTAssertEqual(life.handle(.displaySleep), [])
        XCTAssertEqual(life.handle(.resetFlushed(generation: 1)), [])
        XCTAssertEqual(life.readers, .awaitingBuild(.restart))
        // A second switch while asleep keeps the build a restart.
        XCTAssertEqual(life.handle(.displayWake(assetChanged: true)), [.buildPipeline(.restart), .setRate(1), .startFeeding(generation: 1)])
    }

    func testDecoderFailureDuringSleepRecoversOnWake() {
        var life = playing()
        _ = life.handle(.displaySleep)
        XCTAssertEqual(life.handle(.decoderFailed(generation: 0)), [.freeReaders, .disarmDeepPause])
        XCTAssertEqual(life.readers, .broken)
        XCTAssertEqual(life.handle(.displayWake(assetChanged: false)), [.beginReset(.recover, generation: 2)])
    }
}

private extension RendererLifecycle.Effect {
    var isReset: Bool {
        if case .beginReset = self { return true }
        return false
    }
}
