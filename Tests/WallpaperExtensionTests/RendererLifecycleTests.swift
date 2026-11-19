import XCTest

/// Orderings on the renderer queue that kept a surface decoding with the
/// displays off, overlapped two decoder flushes, or stranded it frozen (#10).
final class RendererLifecycleTests: XCTestCase {

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

    func testHardPauseCutsARampDownShort() {
        // Unlock started the ramp-down, then the Mac hit critical thermal: the
        // policy is already Paused, so only the hard-pause event stops the
        // seconds of decoding left.
        var life = playing()
        XCTAssertEqual(life.handle(.policy(.paused, animated: true)), [.ramp(to: 0)])
        XCTAssertEqual(life.handle(.policy(.paused, animated: false)), [])
        XCTAssertTrue(life.feeding)
        XCTAssertEqual(life.handle(.hardPause), [.setRate(0), .stopFeeding, .armDeepPause])
        assertStoppedAndIdle(life)
        XCTAssertEqual(life.handle(.rampFinished), [])
    }

    func testHardPauseLeavesOtherClocksAlone() {
        var life = playing()
        XCTAssertEqual(life.handle(.hardPause), [], "playing: the policy event stops it")
        _ = life.handle(.policy(.paused, animated: false))
        XCTAssertEqual(life.handle(.hardPause), [])
        _ = life.handle(.policy(.full, animated: true))
        XCTAssertEqual(life.clock, .rampingUp)
        XCTAssertEqual(life.handle(.hardPause), [])
        XCTAssertEqual(life.clock, .rampingUp)
    }

    func testResumeAfterAHardPauseRampsUp() {
        var life = playing()
        _ = life.handle(.policy(.paused, animated: true))
        _ = life.handle(.hardPause)
        XCTAssertEqual(life.handle(.policy(.full, animated: true)), [.ramp(to: 1), .startFeeding(token: 2), .disarmDeepPause])
        XCTAssertEqual(life.clock, .rampingUp)
    }

    func testResumeAfterAHardPauseAndDeepPauseRebuildsInPlace() {
        var life = playing()
        _ = life.handle(.policy(.paused, animated: true))
        _ = life.handle(.hardPause)
        XCTAssertEqual(life.handle(.deepPauseFired), [.freeReaders])
        XCTAssertEqual(life.handle(.policy(.full, animated: true)), [.beginReset(.resume, generation: 1)])
        XCTAssertEqual(life.handle(.resetFlushed(generation: 1)), [.buildPipeline(.resume)])
        XCTAssertEqual(life.handle(.pipelineBuilt(true)), [.ramp(to: 1), .startFeeding(token: 2)])
    }

    func testLockRevealAfterDeepPauseStillRamps() {
        // The desktop sat paused past the deep-pause delay, then the lock
        // screen asks for an animated resume: rebuild, then ramp up instead
        // of jumping to full speed.
        var life = playing()
        _ = life.handle(.policy(.paused, animated: false))
        XCTAssertEqual(life.handle(.deepPauseFired), [.freeReaders])
        XCTAssertEqual(life.handle(.policy(.full, animated: true)), [.beginReset(.resume, generation: 1)])
        XCTAssertEqual(life.handle(.resetFlushed(generation: 1)), [.buildPipeline(.resume)])
        XCTAssertEqual(life.handle(.pipelineBuilt(true)), [.ramp(to: 1), .startFeeding(token: 2)])
    }

    // MARK: Activity (what keeps PowerMonitor polling)

    func testActiveWhileTheClockRunsIncludingARampDown() {
        var life = playing()
        XCTAssertTrue(life.isActive)
        _ = life.handle(.policy(.paused, animated: true))
        XCTAssertTrue(life.isActive, "the unlock ramp-down still decodes")
        _ = life.handle(.rampFinished)
        XCTAssertFalse(life.isActive)
    }

    func testActiveThroughARebuildTowardPlayback() {
        // A switch on one display must not stop and restart the poll.
        var life = playing()
        _ = life.handle(.assetChanged)
        XCTAssertEqual(life.clock, .stopped)
        XCTAssertTrue(life.isActive)
        _ = life.handle(.policy(.paused, animated: false))
        XCTAssertFalse(life.isActive, "a rebuild nobody will watch")
    }

    func testFallbackStillWaitingToRetryIsNotActive() {
        var life = playing()
        _ = failUntilFallback(&life)
        XCTAssertTrue(life.wantsPlayback)
        XCTAssertFalse(life.isActive)
    }

    func testGatedRendererIsNotActive() {
        var life = playing()
        _ = life.handle(.displaySleep)
        XCTAssertFalse(life.isActive)
        _ = life.handle(.displayWake(assetChanged: false))
        _ = life.handle(.surfaceClosed)
        XCTAssertFalse(life.isActive)
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

    // MARK: Closed surfaces (#12)

    func testClosingASurfaceStopsTheFeedAndKeepsItsReaders() {
        // An invalidated surface used to decode through its 15 s grace.
        var life = playing()
        XCTAssertEqual(life.handle(.surfaceClosed), [.setRate(0), .stopFeeding, .armDeepPause])
        assertStoppedAndIdle(life)
        XCTAssertEqual(life.readers, .live, "the context and frame stay for a re-acquire")
    }

    func testReopeningResumesInPlaceWithoutAFlush() {
        // A re-acquire within the grace must not show a black frame: no reset,
        // the held frame stays until the feed continues from it.
        var life = playing()
        _ = life.handle(.surfaceClosed)
        XCTAssertEqual(life.handle(.surfaceReopened(assetChanged: false)), [.setRate(1), .startFeeding(token: 2), .disarmDeepPause])
    }

    func testPolicyUpdatesDoNotResumeAClosedSurface() {
        var life = playing()
        _ = life.handle(.surfaceClosed)
        XCTAssertEqual(life.handle(.policy(.paused, animated: false)), [])
        XCTAssertEqual(life.handle(.policy(.reduced, animated: true)), [])
        XCTAssertEqual(life.policy, .reduced)
        assertStoppedAndIdle(life)
        XCTAssertEqual(life.handle(.surfaceReopened(assetChanged: false)), [.setRate(1), .startFeeding(token: 2), .disarmDeepPause])
    }

    func testSurfaceClosedBeforeStartShowsItsFirstFrameWithoutPlaying() {
        var life = RendererLifecycle()
        XCTAssertEqual(life.handle(.surfaceClosed), [])
        XCTAssertEqual(life.handle(.started(displayAsleep: false)), [])
        XCTAssertEqual(life.handle(.pipelineBuilt(true)), [.armDeepPause])
        assertStoppedAndIdle(life)
    }

    func testClosingCutsARampDownShort() {
        var life = playing()
        XCTAssertEqual(life.handle(.policy(.paused, animated: true)), [.ramp(to: 0)])
        XCTAssertEqual(life.handle(.surfaceClosed), [.setRate(0), .stopFeeding, .armDeepPause])
    }

    func testDeepPausedClosedSurfaceRestartsOnReopenHoldingItsFrame() {
        // A closed surface frees its readers after 30 s. Its clock counts
        // every loop, so resuming from it can seek past the clip (#27); it
        // restarts instead, and a restart's flush keeps the frame up.
        var life = playing()
        _ = life.handle(.surfaceClosed)
        XCTAssertEqual(life.handle(.deepPauseFired), [.freeReaders])
        XCTAssertEqual(life.handle(.surfaceReopened(assetChanged: false)), [.beginReset(.restart, generation: 1)])
    }

    func testSurfaceFreedWhileClosedRestartsWhenItRebuildsAfterWake() {
        // Reopened while the displays slept: the rebuild waits for wake and
        // must still restart, not resume from the loop-counting clock.
        var life = playing()
        _ = life.handle(.surfaceClosed)
        _ = life.handle(.deepPauseFired)
        _ = life.handle(.displaySleep)
        XCTAssertEqual(life.handle(.surfaceReopened(assetChanged: false)), [])
        XCTAssertEqual(life.handle(.displayWake(assetChanged: false)), [.beginReset(.restart, generation: 1)])
    }

    func testSurfaceFreedWhileClosedRestartsWhenAPauseLifts() {
        var life = playing()
        _ = life.handle(.surfaceClosed)
        _ = life.handle(.deepPauseFired)
        _ = life.handle(.policy(.paused, animated: false))
        XCTAssertEqual(life.handle(.surfaceReopened(assetChanged: false)), [])
        XCTAssertEqual(life.handle(.policy(.full, animated: false)), [.beginReset(.restart, generation: 1)])
        _ = life.handle(.resetFlushed(generation: 1))
        _ = life.handle(.pipelineBuilt(true))
        // Once rebuilt, a later deep pause on an open surface resumes as before.
        _ = life.handle(.policy(.paused, animated: false))
        _ = life.handle(.deepPauseFired)
        XCTAssertEqual(life.handle(.policy(.full, animated: false)), [.beginReset(.resume, generation: 2)])
    }

    func testResetFlushingWhileClosedBuildsOnReopen() {
        // Building decodes a frame into the held image; a closed surface waits.
        var life = playing()
        XCTAssertEqual(life.handle(.assetChanged), [.beginReset(.restart, generation: 1)])
        XCTAssertEqual(life.handle(.surfaceClosed), [])
        XCTAssertEqual(life.handle(.resetFlushed(generation: 1)), [])
        XCTAssertEqual(life.readers, .awaitingBuild(.restart))
        XCTAssertEqual(life.handle(.surfaceReopened(assetChanged: false)), [.buildPipeline(.restart)])
        XCTAssertEqual(life.handle(.pipelineBuilt(true)), [.setRate(1), .startFeeding(token: 2)])
    }

    func testWakeDoesNotBuildAClosedSurface() {
        var life = playing()
        _ = life.handle(.displaySleep)
        _ = life.handle(.assetChanged)
        _ = life.handle(.resetFlushed(generation: 1))
        XCTAssertEqual(life.handle(.surfaceClosed), [])
        XCTAssertEqual(life.handle(.displayWake(assetChanged: false)), [])
        XCTAssertEqual(life.readers, .awaitingBuild(.restart))
        XCTAssertEqual(life.handle(.surfaceReopened(assetChanged: false)), [.buildPipeline(.restart)])
    }

    func testReopenWhileAsleepWaitsForWake() {
        var life = playing()
        _ = life.handle(.surfaceClosed)
        _ = life.handle(.displaySleep)
        XCTAssertEqual(life.handle(.surfaceReopened(assetChanged: false)), [])
        XCTAssertEqual(life.handle(.displayWake(assetChanged: false)), [.setRate(1), .startFeeding(token: 2), .disarmDeepPause])
    }

    func testSwitchHeldWhileClosedRestartsOnReopen() {
        // The renderer holds a shuffle or automation switch while closed and
        // opens it on reopen; the new video restarts behind the held frame.
        var life = playing()
        _ = life.handle(.surfaceClosed)
        XCTAssertEqual(life.handle(.surfaceReopened(assetChanged: true)), [.disarmDeepPause, .beginReset(.restart, generation: 1)])
        XCTAssertEqual(life.handle(.resetFlushed(generation: 1)), [.buildPipeline(.restart)])
    }

    func testClosedSurfaceDoesNotRetryAFailedVideo() {
        var life = playing()
        for token in 1...RendererLifecycle.maxFailures {
            _ = life.handle(.decoderFailed(token: token))
            _ = life.handle(.resetFlushed(generation: token))
            if token < RendererLifecycle.maxFailures { _ = life.handle(.pipelineBuilt(true)) }
        }
        XCTAssertEqual(life.readers, .failed)
        XCTAssertTrue(life.retryArmed)
        XCTAssertEqual(life.handle(.surfaceClosed), [.disarmRetry])
    }

    // MARK: Start

    func testStartDuringSleepHoldsTheClock() {
        var life = RendererLifecycle()
        _ = life.handle(.started(displayAsleep: true))
        XCTAssertEqual(life.handle(.pipelineBuilt(true)), [.armDeepPause])
        assertStoppedAndIdle(life)
    }

    func testRendererStartsOnTheTierItWasCreatedFor() {
        // A new renderer used to begin at Full and learn its tier from the
        // recompute after its first frame. Seeded, that recompute is a no-op,
        // so it can't switch the copy the renderer opened.
        var life = RendererLifecycle(policy: .reduced)
        _ = life.handle(.started(displayAsleep: false))
        XCTAssertEqual(life.handle(.pipelineBuilt(true)), [.setRate(1), .startFeeding(token: 1)])
        XCTAssertEqual(life.handle(.policy(.reduced, animated: false)), [])
        XCTAssertEqual(life.policy, .reduced)
    }

    func testRendererCreatedPausedShowsItsFirstFrameWithoutPlaying() {
        var life = RendererLifecycle(policy: .paused)
        _ = life.handle(.started(displayAsleep: false))
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
        // RendererCopy holds the switch; the wake reports the file it opened.
        XCTAssertEqual(life.handle(.displayWake(assetChanged: true)), [.disarmDeepPause, .beginReset(.restart, generation: 1)])
        XCTAssertEqual(life.handle(.resetFlushed(generation: 1)), [.buildPipeline(.restart)])
        XCTAssertEqual(life.handle(.pipelineBuilt(true)), [.setRate(1), .startFeeding(token: 2)])
    }

    func testDeferredSwitchIntoAPausedDesktopShowsTheFrameAndRearmsDeepPause() {
        var life = playing()
        _ = life.handle(.policy(.paused, animated: false))
        _ = life.handle(.displaySleep)
        XCTAssertEqual(life.handle(.deepPauseFired), [.freeReaders])
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
