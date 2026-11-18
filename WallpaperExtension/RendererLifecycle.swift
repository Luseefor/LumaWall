import Foundation

/// Playback lifecycle of one `VideoRenderer`, owned by the renderer's serial
/// queue. It makes every decision and returns `Effect`s; the renderer does
/// the AVFoundation work for each. Keeping it free of AVFoundation lets the
/// orderings that kept a surface decoding with the displays off (#10) run as
/// unit tests.
///
/// Display sleep is held apart from the policy. Sleep stops the clock, the
/// feed, and any rebuild without overwriting the requested tier, so wake
/// resumes whatever the latest policy asks for, including on previews that no
/// policy recompute reaches. Because sleep and wake arrive as events on the
/// same queue as policy updates, an update decided before sleep is undone by
/// the sleep event and one decided after it sees the gate.
///
/// Every pipeline rebuild (a switch, a deep-pause wake, decoder recovery)
/// goes through one reset: at most one flush is in flight, a reset requested
/// during it is merged into it, and callbacks from a replaced pipeline carry a
/// stale `generation` and are dropped.
struct RendererLifecycle: Equatable {
    /// How a reset rebuilds the readers. A merged reset takes the larger kind.
    enum ResetKind: Int, Comparable {
        /// Continue from the paused position (deep-pause wake).
        case resume
        /// Restart the current asset from 0 (a switch).
        case restart
        /// Restart from 0 and clear the displayed frame (decoder failure).
        case recover

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    enum Readers: Equatable {
        case notStarted
        case live
        /// Freed by deep pause.
        case freed
        /// The decoder failed while the displays slept; recover on wake.
        case broken
        /// A reset's flush completed while the displays slept; build on wake.
        case awaitingBuild(ResetKind)
    }

    enum Clock: Equatable { case stopped, playing, rampingUp, rampingDown }

    enum Effect: Equatable {
        /// Set the timebase rate, cancelling any ramp.
        case setRate(Double)
        /// Ease the rate from its current value; report `.rampFinished`.
        case ramp(to: Double)
        case startFeeding(generation: Int)
        case stopFeeding
        case armDeepPause
        case disarmDeepPause
        /// Cancel and drop every reader.
        case freeReaders
        /// Stop feeding, freeze the clock, cancel the readers, and flush the
        /// decoder; report `.resetFlushed(generation)` when the flush completes.
        case beginReset(ResetKind, generation: Int)
        /// Build the readers for `kind` and show their first frame at once.
        case buildPipeline(ResetKind)
        /// Move to the preloaded reader at a loop boundary.
        case swapToNextReader
    }

    enum Event: Equatable {
        /// `start()` built the first pipeline and enqueued its first frame.
        case started(displayAsleep: Bool)
        case policy(PlaybackPolicy, animated: Bool)
        /// The renderer loaded a different asset (switch or battery-tier copy).
        case assetChanged
        case switchDeferred(URL)
        case displaySleep
        /// `assetChanged`: the renderer loaded the deferred or preferred copy.
        case displayWake(assetChanged: Bool)
        case resetFlushed(generation: Int)
        case readerExhausted(generation: Int)
        case decoderFailed(generation: Int)
        case rampFinished
        case deepPauseFired
    }

    private(set) var policy: PlaybackPolicy = .full
    private(set) var displayAsleep = false
    private(set) var clock: Clock = .stopped
    private(set) var readers: Readers = .notStarted
    /// The reset whose flush is in flight, with any later request merged in.
    private(set) var resetInFlight: ResetKind?
    private(set) var feeding = false
    private(set) var deepPauseArmed = false
    /// A loop boundary arrived while feeding was off; swap when it resumes.
    private(set) var loopPending = false
    /// The latest switch requested while the displays slept.
    private(set) var deferredSwitch: URL?
    /// Bumped whenever the pipeline is torn down or replaced.
    private(set) var generation = 0

    var wantsPlayback: Bool { wouldPlay(policy) }

    func wouldPlay(_ policy: PlaybackPolicy) -> Bool {
        policy != .paused && !displayAsleep
    }

    mutating func handle(_ event: Event) -> [Effect] {
        var effects: [Effect] = []
        var animated = false
        switch event {
        case let .started(asleep):
            guard readers == .notStarted else { return [] }
            displayAsleep = asleep
            readers = .live
        case let .policy(requested, isAnimated):
            guard requested != policy else { return [] }
            policy = requested
            animated = isAnimated && !displayAsleep
        case .assetChanged:
            requestReset(.restart, &effects)
        case let .switchDeferred(url):
            deferredSwitch = url
            return []
        case .displaySleep:
            guard !displayAsleep else { return [] }
            displayAsleep = true
        case let .displayWake(assetChanged):
            guard displayAsleep else { return [] }
            displayAsleep = false
            deferredSwitch = nil
            if case let .awaitingBuild(kind) = readers {
                let build = assetChanged ? max(kind, .restart) : kind
                if build == .resume, !wantsPlayback {
                    readers = .freed
                } else {
                    readers = .live
                    effects.append(.buildPipeline(build))
                }
            } else if assetChanged {
                requestReset(.restart, &effects)
            }
        case let .resetFlushed(flushed):
            guard flushed == generation, let kind = resetInFlight else { return [] }
            resetInFlight = nil
            if !displayAsleep {
                readers = .live
                effects.append(.buildPipeline(kind))
            } else {
                // Building decodes the first frame; nobody can see it now.
                readers = .awaitingBuild(kind)
            }
        case let .readerExhausted(exhausted):
            guard exhausted == generation, readers == .live, resetInFlight == nil else { return [] }
            // The feed callback already stopped requesting.
            feeding = false
            loopPending = true
        case let .decoderFailed(failed):
            guard failed == generation, readers == .live, resetInFlight == nil else { return [] }
            feeding = false
            if displayAsleep {
                generation += 1
                loopPending = false
                readers = .broken
                effects.append(.freeReaders)
            } else {
                requestReset(.recover, &effects)
            }
        case .rampFinished:
            switch clock {
            case .rampingUp: clock = .playing
            case .rampingDown: clock = .stopped
            case .playing, .stopped: return []
            }
        case .deepPauseFired:
            guard deepPauseArmed else { return [] }
            deepPauseArmed = false
            guard readers == .live, resetInFlight == nil, clock == .stopped else { break }
            generation += 1
            loopPending = false
            readers = .freed
            effects.append(.freeReaders)
        }
        reconcile(animated: animated, &effects)
        return effects
    }

    private mutating func requestReset(_ kind: ResetKind, _ effects: inout [Effect]) {
        if let inFlight = resetInFlight {
            resetInFlight = max(inFlight, kind)
            return
        }
        switch readers {
        case .notStarted:
            // start() builds from whatever asset is current by then.
            return
        case let .awaitingBuild(pending):
            readers = .awaitingBuild(max(pending, kind))
            return
        case .live, .freed, .broken:
            break
        }
        if deepPauseArmed {
            deepPauseArmed = false
            effects.append(.disarmDeepPause)
        }
        generation += 1
        resetInFlight = kind
        loopPending = false
        feeding = false
        clock = .stopped
        effects.append(.beginReset(kind, generation: generation))
    }

    /// Bring the clock, feed, and deep-pause timer in line with the state.
    private mutating func reconcile(animated: Bool, _ effects: inout [Effect]) {
        if !displayAsleep, resetInFlight == nil {
            if readers == .broken {
                requestReset(.recover, &effects)
            } else if readers == .freed, wantsPlayback {
                requestReset(.resume, &effects)
            }
        }
        let ready = readers == .live && resetInFlight == nil
        let wantClock = wantsPlayback && ready

        switch clock {
        case .stopped, .rampingDown:
            if wantClock {
                clock = animated ? .rampingUp : .playing
                effects.append(animated ? .ramp(to: 1) : .setRate(1))
            } else if clock == .rampingDown, displayAsleep || !ready {
                // Sleep cuts a ramp-down short instead of decoding for seconds.
                clock = .stopped
                effects.append(.setRate(0))
            }
        case .playing, .rampingUp:
            if !wantClock {
                let rampDown = animated && ready
                clock = rampDown ? .rampingDown : .stopped
                effects.append(rampDown ? .ramp(to: 0) : .setRate(0))
            }
        }

        let wantFeed = ready && clock != .stopped
        if wantFeed, !feeding {
            if loopPending {
                loopPending = false
                effects.append(.swapToNextReader)
            }
            feeding = true
            effects.append(.startFeeding(generation: generation))
        } else if !wantFeed, feeding {
            feeding = false
            effects.append(.stopFeeding)
        }

        let wantDeepPause = ready && clock == .stopped && !wantsPlayback
        if wantDeepPause != deepPauseArmed {
            deepPauseArmed = wantDeepPause
            effects.append(wantDeepPause ? .armDeepPause : .disarmDeepPause)
        }
    }
}
