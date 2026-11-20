import AVFoundation
import CoreMedia
import os

extension VideoRenderer {
    // MARK: - Playback control

    /// `hardPause`: the pause must stop decoding at once
    /// (`RampMath.cutsRampDown`), so it skips the ramp and ends one in flight.
    /// `onBattery` is the reading the policy came from; ramps take their
    /// length from it rather than reading power again.
    func applyPolicy(_ policy: PlaybackPolicy, animated: Bool = false, hardPause: Bool = false, onBattery: Bool) {
        queue.async { [weak self] in
            guard let self, isRunning else { return }
            rampOnBattery = onBattery
            applyTier(policy, animated: animated && !hardPause)
            if hardPause { send(.hardPause) }
        }
    }

    /// Queue-only body of `applyPolicy`, also run by a switch for the tier it
    /// opened.
    func applyTier(_ requested: PlaybackPolicy, animated: Bool) {
        requestedTier = requested
        let policy = playedTier(requested)
        // The second check catches a preview whose copy didn't open (a held
        // switch fell back to the original) at an unchanged tier.
        guard policy != lifecycle.policy || playedTier(requested, playing: asset.url) != lifecycle.policy else { return }
        extensionLog(
            "  [applyPolicy #\(debugID)] \(lifecycle.policy) → \(policy) animated=\(animated) asleep=\(lifecycle.displayAsleep) asset=\(LogRedaction.fileLabel(asset.url))"
        )
        // Battery tiers resolve to downscaled siblings via the selector,
        // but the selector is otherwise consulted only at loop boundaries,
        // without this, flipping to Battery Saver (or unplugging on
        // Automatic) kept playing the full file until the clip looped, up
        // to a minute later. Switch now when the URL differs. The asset
        // change goes first so the tier's resume waits for its reset.
        if lifecycle.wouldPlay(policy),
            case let .opened(loaded) = copy.retier(current: asset.url, tier: policy, displayPixels: displayPixelSize, open: loadBlocking)
        {
            adopt(loaded)
            send(.assetChanged)
        }
        send(.policy(playedTier(requested, playing: asset.url), animated: animated))
    }

    /// The tier to play for `requested`: a preview with no copy for it holds
    /// a frame instead of decoding the original. Queue-only.
    func playedTier(_ requested: PlaybackPolicy, playing: URL? = nil) -> PlaybackPolicy {
        isPreview ? copy.previewTier(requested, displayPixels: displayPixelSize, playing: playing) : requested
    }

    /// The library rescanned, maybe publishing a copy: a preview holding a
    /// frame for want of one plays it now (`applyTier` asks the selector).
    func libraryDidChange() {
        queue.async { [weak self] in
            guard let self, isRunning, isPreview else { return }
            applyTier(requestedTier, animated: false)
        }
    }

    /// A live request was handed this preview's surface: stop holding frames
    /// for good, so the desktop never freezes on a preview rule.
    func playAsLive() {
        queue.async { [weak self] in
            guard let self, isRunning, isPreview else { return }
            isPreview = false
            extensionLog("  [Renderer #\(debugID)] a live request shares this preview surface, preview hold off")
            // A held gradient seed gives way to the video's frame, as on a
            // live surface created paused. Before the tier, whose resume a
            // pause could drop behind a shut gate; this restart survives it.
            send(.liveTakeover(keepsSeed: copy.liveKeepsSeed(seedOf: seededOriginal, seedIsStill: seedIsOfVideo)))
            applyTier(requestedTier, animated: false)
        }
    }

    /// The displays went to sleep: stop the clock, the feed, and any ramp, and
    /// hold rebuilds and switches until `displayDidWake`.
    func displayDidSleep() {
        queue.async { [weak self] in
            guard let self, isRunning else { return }
            send(.displaySleep)
        }
    }

    /// The agent invalidated this surface (false) or acquired it again
    /// (true). Closed stops the clock and feed but keeps the frame and the
    /// readers, so a reopen within the teardown grace resumes in place.
    /// Reopening on awake displays opens a switch held while closed.
    func setSurfaceOpen(_ open: Bool) {
        queue.async { [weak self] in
            guard let self, isRunning, open != lifecycle.surfaceOpen else { return }
            guard open else { send(.surfaceClosed); return }
            var changed = false
            if !lifecycle.displayAsleep,
                case let .opened(loaded) = copy.reopen(
                    current: asset.url, tier: requestedTier, displayPixels: displayPixelSize, open: loadBlocking)
            {
                adopt(loaded)
                changed = true
            }
            send(.surfaceReopened(assetChanged: changed))
            // The file or a tier change recorded while closed (a copy that
            // now serves it) sets what a preview plays.
            if isPreview { applyTier(requestedTier, animated: false) }
        }
    }

    /// The displays woke: open the latest held switch, or the copy for a tier
    /// that changed during sleep, for the tier current now, and resume
    /// whatever the latest policy asks for.
    func displayDidWake() {
        queue.async { [weak self] in
            guard let self, isRunning, lifecycle.displayAsleep else { return }
            var changed = false
            // A closed surface keeps its held switch and copy for the reopen.
            if lifecycle.surfaceOpen,
                case let .opened(loaded) = copy.wake(
                    current: asset.url, tier: requestedTier, displayPixels: displayPixelSize, open: loadBlocking)
            {
                adopt(loaded)
                changed = true
            }
            send(.displayWake(assetChanged: changed))
            if isPreview { applyTier(requestedTier, animated: false) }
        }
    }

    /// Run one event through the lifecycle and perform its effects. Queue-only.
    func send(_ event: RendererLifecycle.Event) {
        pendingEvents.append(event)
        guard !isDispatching else { return }
        isDispatching = true
        while !pendingEvents.isEmpty {
            let next = pendingEvents.removeFirst()
            let effects = lifecycle.handle(next)
            if !effects.isEmpty {
                traceLog("  [lifecycle #\(debugID)] \(next) → \(effects)")
            }
            effects.forEach(perform)
        }
        isDispatching = false
        reportPlayback()
    }

    /// Tell `PowerMonitor` when this renderer becomes active or idle
    /// (`RendererLifecycle.isActive`), so it polls power only while something
    /// decodes. Queue-only.
    func reportPlayback() {
        let active = isRunning && lifecycle.isActive
        guard active != reportedPlayback else { return }
        reportedPlayback = active
        PowerMonitor.shared.notePlayback(renderer: debugID, playing: active)
    }

    private func perform(_ effect: RendererLifecycle.Effect) {
        switch effect {
        case let .setRate(rate):
            cancelRamp()
            CMTimebaseSetRate(timebase, rate: rate)
        case let .ramp(target):
            ramp(to: target, over: RampMath.fullDuration(toward: target, onBattery: rampOnBattery)) { [weak self] in
                self?.send(.rampFinished)
            }
        case let .startFeeding(token):
            feedFromCurrentReader(token: token)
        case .stopFeeding:
            renderer.stopRequestingMediaData()
        case .armDeepPause:
            scheduleDeepPause()
        case .disarmDeepPause:
            cancelDeepPauseTimer()
        case .freeReaders:
            renderer.stopRequestingMediaData()
            dropReaders()
            extensionLog("  [Renderer #\(debugID)] Freed asset readers")
        case let .beginReset(kind, generation):
            beginReset(kind, generation: generation)
        case let .buildPipeline(kind):
            let built = buildPipeline(kind)
            send(.pipelineBuilt(built))
        case .showFallback:
            showFallbackStill()
        case let .armRetry(delay):
            armRetry(after: delay)
        case .disarmRetry:
            cancelRetryTimer()
        case .swapToNextReader:
            swapToNextReader()
        }
    }

    // MARK: - Ramp (Apple-like lock screen transition)

    // Durations and step rate live in `RampMath`.

    /// Ease the timebase rate from its CURRENT value to `target`.
    ///
    /// Starting from the live rate is what makes ramps reversible: a reversal
    /// mid-flight travels the remaining distance in proportionally less time,
    /// keeping the rate curve continuous instead of replaying a full schedule
    /// from 1.0 or 0 (which made a paused wallpaper leap to speed and decelerate).
    ///
    /// Queue-confined: `rampTimer` is created, cancelled, and cleared here and
    /// in `cancelRamp`, so both must run on `queue` (all callers hop first).
    private func ramp(to target: Double, over fullDuration: TimeInterval, then completion: (@Sendable () -> Void)? = nil) {
        cancelRamp()
        let start = Double(CMTimebaseGetRate(timebase))
        let distance = abs(target - start)
        guard distance > 0.001 else {
            CMTimebaseSetRate(timebase, rate: target)
            completion?()
            return
        }
        let totalSteps = RampMath.steps(distance: distance, fullDuration: fullDuration, stepInterval: RampMath.stepInterval)
        var step = 0

        // First step lands immediately so a resume never sits on a dead frame.
        if target > start {
            CMTimebaseSetRate(timebase, rate: max(start, 0.01))
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + RampMath.stepInterval,
            repeating: RampMath.stepInterval,
            leeway: .microseconds(Int(RampMath.stepLeeway * 1_000_000)),
        )
        timer.setEventHandler { [weak self] in
            guard let self, isRunning else {
                timer.cancel()
                return
            }
            step += 1
            let progress = Double(step) / Double(totalSteps)
            let rate = RampMath.rate(from: start, to: target, progress: progress)
            CMTimebaseSetRate(timebase, rate: rate)

            if step >= totalSteps {
                timer.cancel()
                rampTimer = nil
                completion?()
            }
        }
        rampTimer = timer
        timer.resume()
    }

    func cancelRamp() {
        rampTimer?.cancel()
        rampTimer = nil
    }

    // MARK: - Deep Pause

    //
    // After a sustained pause (lock screen overnight, brightness at zero, etc.)
    // the asset reader still holds decoded buffers and the underlying video
    // decoder. Tearing them down frees memory and lets the system fully idle.
    // On resume the lifecycle rebuilds the pipeline through a `.resume` reset.

    private static let deepPauseDelay: TimeInterval = 30

    /// Queue-confined with `cancelDeepPauseTimer` (see `rampTimer` above).
    private func scheduleDeepPause() {
        cancelDeepPauseTimer()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.deepPauseDelay)
        timer.setEventHandler { [weak self] in
            guard let self, isRunning else { return }
            deepPauseTimer = nil
            send(.deepPauseFired)
        }
        deepPauseTimer = timer
        timer.resume()
    }

    func cancelDeepPauseTimer() {
        deepPauseTimer?.cancel()
        deepPauseTimer = nil
    }

    /// Queue-confined like the deep-pause timer.
    private func armRetry(after delay: TimeInterval) {
        cancelRetryTimer()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            guard let self, isRunning else { return }
            retryTimer = nil
            send(.retryFired)
        }
        retryTimer = timer
        timer.resume()
    }

    func cancelRetryTimer() {
        retryTimer?.cancel()
        retryTimer = nil
    }
}
