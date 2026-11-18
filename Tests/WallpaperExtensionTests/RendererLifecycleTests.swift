import XCTest

/// Orderings on the renderer queue that kept a surface decoding with the
/// displays off, overlapped two decoder flushes, or stranded it frozen (#10).
final class RendererLifecycleTests: XCTestCase {
    private let b = URL(fileURLWithPath: "/b.mov")

    /// A renderer that has started and is playing on an awake display, fed by
    /// registration 1.
    private func playing() -> RendererLifecycle {
        var life = RendererLifecycle()
        XCTAssertEqual(life.handle(.started(displayAsleep: false)), [])
        XCTAssertEqual(life.handle(.pipelineBuilt(true)), [.setRate(1), .startFeeding(token: 1)])
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
        XCTAssertEqual(life.handle(.policy(.full, animated: true)), [.ramp(to: 1), .startFeeding(token: 2), .disarmDeepPause])
        XCTAssertEqual(life.handle(.displaySleep), [.setRate(0), .stopFeeding, .armDeepPause])
        assertStoppedAndIdle(life)
    }

    func testWakeResumesTheLatestTierWithoutARecompute() {
        // Previews get no policy recompute on wake; their tier never changed.
        var life = playing()
        _ = life.handle(.displaySleep)
        XCTAssertEqual(life.handle(.displayWake(assetChanged: false)), [.setRate(1), .startFeeding(token: 2), .disarmDeepPause])
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
        XCTAssertEqual(life.handle(.policy(.full, animated: true)), [.ramp(to: 1), .startFeeding(token: 2), .disarmDeepPause])
        XCTAssertEqual(life.handle(.rampFinished), [])
        XCTAssertEqual(life.clock, .playing)
    }

    func testAnimatedResumeThatSwitchesCopiesStillRamps() {
        // Lock screen with "always pause desktop" on battery: the resume also
        // switches to the tier's copy, so the ramp waits for the rebuild.
        var life = playing()
        _ = life.handle(.policy(.paused, animated: true))
        _ = life.handle(.rampFinished)
        XCTAssertEqual(life.handle(.assetChanged), [.disarmDeepPause, .beginReset(.restart, generation: 1)])
        XCTAssertEqual(life.handle(.policy(.minimal, animated: true)), [])
        XCTAssertEqual(life.handle(.resetFlushed(generation: 1)), [.buildPipeline(.restart)])
        XCTAssertEqual(life.handle(.pipelineBuilt(true)), [.ramp(to: 1), .startFeeding(token: 2)])
    }

    // MARK: Start

    func testStartDuringSleepHoldsTheClock() {
        var life = RendererLifecycle()
        _ = life.handle(.started(displayAsleep: true))
        XCTAssertEqual(life.handle(.pipelineBuilt(true)), [.armDeepPause])
        assertStoppedAndIdle(life)
    }

    func testSwitchBeforeStartIsLeftToStart() {
        var life = RendererLifecycle()
        XCTAssertEqual(life.handle(.assetChanged), [])
        _ = life.handle(.started(displayAsleep: false))
        XCTAssertEqual(life.handle(.pipelineBuilt(true)), [.setRate(1), .startFeeding(token: 1)])
    }

    // MARK: Feed registrations

    func testCallbackFromACancelledRegistrationIsRejected() {
        // A readiness callback submitted before sleep runs after it: it must
        // not feed, and its end-of-clip event must not swap readers.
        var life = playing()
        _ = life.handle(.displaySleep)
        XCTAssertFalse(life.acceptsFeed(token: 1))
        XCTAssertEqual(life.handle(.readerExhausted(token: 1)), [])
        XCTAssertEqual(life.handle(.decoderFailed(token: 1)), [])
        XCTAssertEqual(life.readers, .live)
        // Wake registers a new feed; the old token stays retired. An exhausted
        // reader reports again from the new registration.
        XCTAssertEqual(life.handle(.displayWake(assetChanged: false)), [.setRate(1), .startFeeding(token: 2), .disarmDeepPause])
        XCTAssertFalse(life.acceptsFeed(token: 1))
        XCTAssertTrue(life.acceptsFeed(token: 2))
        XCTAssertEqual(life.handle(.readerExhausted(token: 2)), [.swapToNextReader, .startFeeding(token: 3)])
    }

    func testDeepPausedRendererRebuildsOnWake() {
        var life = playing()
        _ = life.handle(.displaySleep)
        XCTAssertEqual(life.handle(.deepPauseFired), [.freeReaders])
        XCTAssertEqual(life.handle(.displayWake(assetChanged: false)), [.beginReset(.resume, generation: 1)])
        XCTAssertEqual(life.handle(.resetFlushed(generation: 1)), [.buildPipeline(.resume)])
        XCTAssertEqual(life.handle(.pipelineBuilt(true)), [.setRate(1), .startFeeding(token: 2)])
    }

    // MARK: Switches and resets

    func testSwitchDuringSleepWaitsForWake() {
        var life = playing()
        _ = life.handle(.displaySleep)
        XCTAssertEqual(life.handle(.switchDeferred(b)), [])
        XCTAssertEqual(life.handle(.switchDeferred(URL(fileURLWithPath: "/a.mov"))), [])
        XCTAssertEqual(life.deferredSwitch, URL(fileURLWithPath: "/a.mov"))
        XCTAssertEqual(life.handle(.displayWake(assetChanged: true)), [.disarmDeepPause, .beginReset(.restart, generation: 1)])
        XCTAssertNil(life.deferredSwitch)
        XCTAssertEqual(life.handle(.resetFlushed(generation: 1)), [.buildPipeline(.restart)])
        XCTAssertEqual(life.handle(.pipelineBuilt(true)), [.setRate(1), .startFeeding(token: 2)])
    }

    func testDeferredSwitchIntoAPausedDesktopShowsTheFrameAndRearmsDeepPause() {
        var life = playing()
        _ = life.handle(.policy(.paused, animated: false))
        _ = life.handle(.displaySleep)
        XCTAssertEqual(life.handle(.deepPauseFired), [.freeReaders])
        _ = life.handle(.switchDeferred(b))
        XCTAssertEqual(life.handle(.displayWake(assetChanged: true)), [.beginReset(.restart, generation: 1)])
        XCTAssertEqual(life.handle(.resetFlushed(generation: 1)), [.buildPipeline(.restart)])
        XCTAssertEqual(life.handle(.pipelineBuilt(true)), [.armDeepPause])
        assertStoppedAndIdle(life)
    }

    func testDeferredSwitchMeetingQueuedRecoveryFlushesOnce() {
        // The feed saw a failed decoder just before sleep and queued recovery
        // behind the wake switch. Only the switch's reset may flush.
        var life = playing()
        _ = life.handle(.displaySleep)
        _ = life.handle(.switchDeferred(b))
        var effects = life.handle(.displayWake(assetChanged: true))
        effects += life.handle(.decoderFailed(token: 1))
        effects += life.handle(.resetFlushed(generation: 1))
        effects += life.handle(.pipelineBuilt(true))
        XCTAssertEqual(effects.filter(\.isReset), [.beginReset(.restart, generation: 1)])
        XCTAssertEqual(life.clock, .playing)
    }

    func testDiscontinuityThenSwitchFlushesOnce() {
        // requiresFlushToResumeDecoding goes through the same reset, resumes
        // from a keyframe, and a switch during its flush merges into it.
        var life = playing()
        XCTAssertEqual(life.handle(.decoderInterrupted(token: 1)), [.beginReset(.resume, generation: 1)])
        XCTAssertEqual(life.handle(.assetChanged), [])
        XCTAssertEqual(life.handle(.resetFlushed(generation: 1)), [.buildPipeline(.restart)])
        XCTAssertEqual(life.handle(.pipelineBuilt(true)), [.setRate(1), .startFeeding(token: 2)])
    }

    func testRequestsDuringAFlushMergeIntoIt() {
        var life = playing()
        XCTAssertEqual(life.handle(.decoderFailed(token: 1)), [.beginReset(.recover, generation: 1)])
        XCTAssertEqual(life.handle(.assetChanged), [])
        XCTAssertEqual(life.handle(.policy(.reduced, animated: false)), [])
        XCTAssertEqual(life.handle(.resetFlushed(generation: 1)), [.buildPipeline(.recover)])
    }

    func testFlushCompletingDuringSleepBuildsOnWake() {
        var life = playing()
        XCTAssertEqual(life.handle(.assetChanged), [.beginReset(.restart, generation: 1)])
        XCTAssertEqual(life.handle(.displaySleep), [])
        XCTAssertEqual(life.handle(.resetFlushed(generation: 1)), [])
        XCTAssertEqual(life.readers, .awaitingBuild(.restart))
        XCTAssertEqual(life.handle(.displayWake(assetChanged: true)), [.buildPipeline(.restart)])
        XCTAssertEqual(life.handle(.pipelineBuilt(true)), [.setRate(1), .startFeeding(token: 2)])
    }

    // MARK: Failed builds

    func testFailedBuildRetriesThenShowsTheFallback() {
        var life = playing()
        var effects = life.handle(.assetChanged)
        var generation = 1
        for _ in 0 ..< RendererLifecycle.maxFailures {
            XCTAssertEqual(effects, [.beginReset(.restart, generation: generation)])
            XCTAssertEqual(life.handle(.resetFlushed(generation: generation)), [.buildPipeline(.restart)])
            // Nothing starts the clock or feed before the build reports back.
            assertStoppedAndIdle(life)
            effects = life.handle(.pipelineBuilt(false))
            generation += 1
        }
        XCTAssertEqual(effects, [.beginReset(.restart, generation: generation)])
        XCTAssertEqual(life.handle(.resetFlushed(generation: generation)), [.showFallback])
        XCTAssertEqual(life.readers, .failed)
        // Policy and wake leave the fallback alone; a new asset tries again.
        XCTAssertEqual(life.handle(.policy(.reduced, animated: false)), [])
        XCTAssertEqual(life.handle(.assetChanged), [.beginReset(.restart, generation: generation + 1)])
    }

    func testFailedStartRetriesWithoutClearingTheStill() {
        var life = RendererLifecycle()
        _ = life.handle(.started(displayAsleep: false))
        XCTAssertEqual(life.handle(.pipelineBuilt(false)), [.beginReset(.restart, generation: 1)])
    }

    func testRepeatedDecoderFailureStopsRetrying() {
        var life = playing()
        var token = 1
        for attempt in 1 ... RendererLifecycle.maxFailures {
            XCTAssertEqual(life.handle(.decoderFailed(token: token)), [.beginReset(.recover, generation: attempt)])
            if attempt == RendererLifecycle.maxFailures {
                XCTAssertEqual(life.handle(.resetFlushed(generation: attempt)), [.showFallback])
            } else {
                _ = life.handle(.resetFlushed(generation: attempt))
                _ = life.handle(.pipelineBuilt(true))
                token += 1
            }
        }
        assertStoppedAndIdle(life)
    }

    func testACompletedLoopClearsTheFailureCount() {
        var life = playing()
        _ = life.handle(.decoderFailed(token: 1))
        _ = life.handle(.resetFlushed(generation: 1))
        _ = life.handle(.pipelineBuilt(true))
        XCTAssertEqual(life.failures, 1)
        _ = life.handle(.readerExhausted(token: 2))
        XCTAssertEqual(life.failures, 0)
    }
}

private extension RendererLifecycle.Effect {
    var isReset: Bool {
        if case .beginReset = self { return true }
        return false
    }
}
