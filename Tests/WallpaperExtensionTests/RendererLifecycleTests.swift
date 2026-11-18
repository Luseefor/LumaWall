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
        XCTAssertEqual(life.handle(.resetFlushed(generation: generation)), [.showFallback, .armRetry(after: 2)])
        XCTAssertEqual(life.readers, .failed)
        // A tier change keeps the pending retry; a new asset tries at once.
        XCTAssertEqual(life.handle(.policy(.reduced, animated: false)), [])
        XCTAssertEqual(life.handle(.assetChanged), [.disarmRetry, .beginReset(.restart, generation: generation + 1)])
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
                XCTAssertEqual(life.handle(.resetFlushed(generation: attempt)), [.showFallback, .armRetry(after: 2)])
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

    // MARK: Round 3: retries, reader errors, fault classification

    /// Drive a playing renderer through `maxFailures` failed builds of the
    /// current video. Returns the effects of the flush that gives up.
    private func failUntilFallback(_ life: inout RendererLifecycle) -> [RendererLifecycle.Effect] {
        var effects = life.handle(.assetChanged)
        for _ in 0 ..< RendererLifecycle.maxFailures {
            guard case let .beginReset(_, generation)? = effects.last else { XCTFail("no reset: \(effects)"); return [] }
            _ = life.handle(.resetFlushed(generation: generation))
            effects = life.handle(.pipelineBuilt(false))
        }
        guard case let .beginReset(_, generation)? = effects.last else { XCTFail("no reset: \(effects)"); return [] }
        return life.handle(.resetFlushed(generation: generation))
    }

    func testReaderErrorKeepsTheDisplayedFrame() {
        // Only a failed renderer clears the frame; a reader error restarts the
        // clip behind the frame that is showing.
        var life = playing()
        XCTAssertEqual(life.handle(.readerFailed(token: 1)), [.beginReset(.restart, generation: 1)])
    }

    func testFailedVideoRetriesWithBackoffWhilePlaybackIsWanted() {
        var life = playing()
        XCTAssertEqual(failUntilFallback(&life), [.showFallback, .armRetry(after: RendererLifecycle.retryDelay(round: 1))])
        XCTAssertEqual(life.readers, .failed)
        guard case let .beginReset(.restart, generation)? = life.handle(.retryFired).last else {
            return XCTFail("retry did not reset")
        }
        // The retry gets a full set of attempts, then waits longer.
        var effects = life.handle(.resetFlushed(generation: generation))
        XCTAssertEqual(effects, [.buildPipeline(.restart)])
        for attempt in 1 ... RendererLifecycle.maxFailures {
            effects = life.handle(.pipelineBuilt(false))
            guard case let .beginReset(_, next)? = effects.last else { return XCTFail("no reset") }
            effects = life.handle(.resetFlushed(generation: next))
            if attempt < RendererLifecycle.maxFailures {
                XCTAssertEqual(effects, [.buildPipeline(.restart)])
            }
        }
        XCTAssertEqual(effects, [.showFallback, .armRetry(after: RendererLifecycle.retryDelay(round: 2))])
        XCTAssertGreaterThan(RendererLifecycle.retryDelay(round: 2), RendererLifecycle.retryDelay(round: 1))
    }

    func testFailedVideoRetriesOnlyWhilePlaybackIsWanted() {
        var life = playing()
        _ = failUntilFallback(&life)
        XCTAssertEqual(life.handle(.displaySleep), [.disarmRetry])
        XCTAssertEqual(life.handle(.retryFired), [], "a timer that fired before the disarm ran")
        XCTAssertEqual(life.handle(.displayWake(assetChanged: false)), [.armRetry(after: RendererLifecycle.retryDelay(round: 1))])
        XCTAssertEqual(life.handle(.policy(.paused, animated: false)), [.disarmRetry])
        XCTAssertEqual(life.handle(.policy(.reduced, animated: false)), [.armRetry(after: RendererLifecycle.retryDelay(round: 1))])
        // A new video retries at once and drops the pending timer.
        XCTAssertEqual(life.handle(.assetChanged).first, .disarmRetry)
    }

    func testRampSurvivesAFailedFirstBuild() {
        var life = playing()
        _ = life.handle(.policy(.paused, animated: true))
        _ = life.handle(.rampFinished)
        _ = life.handle(.assetChanged)
        _ = life.handle(.policy(.minimal, animated: true))
        _ = life.handle(.resetFlushed(generation: 1))
        XCTAssertEqual(life.handle(.pipelineBuilt(false)), [.beginReset(.restart, generation: 2)])
        XCTAssertEqual(life.handle(.resetFlushed(generation: 2)), [.buildPipeline(.restart)])
        XCTAssertEqual(life.handle(.pipelineBuilt(true)), [.ramp(to: 1), .startFeeding(token: 2)])
    }

    func testFeedFaultClassification() {
        // Apple sets requiresFlushToResumeDecoding alongside .failed; that case
        // resumes behind the frame instead of clearing it.
        typealias L = RendererLifecycle
        XCTAssertEqual(L.feedFault(requiresFlush: true, rendererFailed: true, hasReader: true, token: 4), .decoderInterrupted(token: 4))
        XCTAssertEqual(L.feedFault(requiresFlush: true, rendererFailed: false, hasReader: true, token: 4), .decoderInterrupted(token: 4))
        XCTAssertEqual(L.feedFault(requiresFlush: false, rendererFailed: true, hasReader: true, token: 4), .decoderFailed(token: 4))
        XCTAssertEqual(L.feedFault(requiresFlush: false, rendererFailed: false, hasReader: false, token: 4), .readerFailed(token: 4))
        XCTAssertNil(L.feedFault(requiresFlush: false, rendererFailed: false, hasReader: true, token: 4))
        XCTAssertEqual(L.outOfSamples(readerCompleted: true, token: 4), .readerExhausted(token: 4))
        XCTAssertEqual(L.outOfSamples(readerCompleted: false, token: 4), .readerFailed(token: 4))
    }
}

private extension RendererLifecycle.Effect {
    var isReset: Bool {
        if case .beginReset = self { return true }
        return false
    }
}
