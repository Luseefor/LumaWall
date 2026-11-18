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
/// during it is merged into it, and the clock and feed start only once the
/// renderer reports the rebuilt pipeline. Each feed registration has its own
/// token, so a callback or event from a cancelled one is dropped.
struct RendererLifecycle: Equatable {
    /// How a reset rebuilds the readers. A merged reset takes the larger kind.
    enum ResetKind: Int, Comparable {
        /// Continue from the current position, starting at the enclosing
        /// keyframe (deep-pause wake, decoder discontinuity).
        case resume
        /// Restart the current asset from 0 (a switch, a failed build).
        case restart
        /// Restart from 0 and clear the displayed frame (decoder failure).
        case recover

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    enum Readers: Equatable {
        case notStarted
        /// `buildPipeline` is running; `.pipelineBuilt` reports the result.
        case building
        case live
        /// Freed by deep pause.
        case freed
        /// A reset's flush completed while the displays slept; build on wake.
        case awaitingBuild(ResetKind)
        /// Rebuilding failed `maxFailures` times in a row; the fallback still
        /// shows until the asset changes.
        case failed
    }

    enum Clock: Equatable { case stopped, playing, rampingUp, rampingDown }

    enum Effect: Equatable {
        /// Set the timebase rate, cancelling any ramp.
        case setRate(Double)
        /// Ease the rate from its current value; report `.rampFinished`.
        case ramp(to: Double)
        /// Register a feed; its callbacks and events carry `token`.
        case startFeeding(token: Int)
        case stopFeeding
        case armDeepPause
        case disarmDeepPause
        /// Cancel and drop every reader.
        case freeReaders
        /// Stop feeding, freeze the clock, cancel the readers, and flush the
        /// decoder; report `.resetFlushed(generation)` when the flush completes.
        case beginReset(ResetKind, generation: Int)
        /// Build the readers for `kind` and show their first frame at once;
        /// report `.pipelineBuilt`.
        case buildPipeline(ResetKind)
        /// Show the creation still in place of video that won't build.
        case showFallback
        /// Move to the preloaded reader at a loop boundary.
        case swapToNextReader
    }

    enum Event: Equatable {
        /// `start()` is building the first pipeline; `.pipelineBuilt` follows.
        case started(displayAsleep: Bool)
        case pipelineBuilt(Bool)
        case policy(PlaybackPolicy, animated: Bool)
        /// The renderer loaded a different asset (switch or battery-tier copy).
        case assetChanged
        case switchDeferred(URL)
        case displaySleep
        /// `assetChanged`: the renderer loaded the deferred or preferred copy.
        case displayWake(assetChanged: Bool)
        case resetFlushed(generation: Int)
        /// The reader reached the end of the clip.
        case readerExhausted(token: Int)
        /// The renderer or the reader failed.
        case decoderFailed(token: Int)
        /// The renderer needs a flush to resume decoding.
        case decoderInterrupted(token: Int)
        case rampFinished
        case deepPauseFired
    }

    /// Consecutive failed builds or decodes before the fallback still shows.
    static let maxFailures = 3

    private(set) var policy: PlaybackPolicy = .full
    private(set) var displayAsleep = false
    private(set) var clock: Clock = .stopped
    private(set) var readers: Readers = .notStarted
    /// The reset whose flush is in flight, with any later request merged in.
    private(set) var resetInFlight: ResetKind?
    private(set) var feeding = false
    /// Identifies the current feed registration.
    private(set) var feedToken = 0
    private(set) var deepPauseArmed = false
    /// An animated resume arrived while the pipeline was being rebuilt; ramp
    /// once it is ready instead of jumping to full speed.
    private(set) var rampWhenReady = false
    /// Failed builds and decodes since the last completed loop or new asset.
    private(set) var failures = 0
    /// The latest switch requested while the displays slept.
    private(set) var deferredSwitch: URL?
    /// Bumped whenever a reset starts, so a stale flush completion is dropped.
    private(set) var generation = 0

    var wantsPlayback: Bool { wouldPlay(policy) }

    func wouldPlay(_ policy: PlaybackPolicy) -> Bool {
        policy != .paused && !displayAsleep
    }

    /// Whether a feed callback or event from registration `token` may act.
    /// Stopping the feed and starting a new one both retire the token.
    func acceptsFeed(token: Int) -> Bool {
        feeding && token == feedToken
    }

    mutating func handle(_ event: Event) -> [Effect] {
        var effects: [Effect] = []
        var animated = false
        switch event {
        case let .started(asleep):
            guard readers == .notStarted else { return [] }
            displayAsleep = asleep
            readers = .building
        case let .pipelineBuilt(ok):
            guard readers == .building else { return [] }
            if ok {
                readers = .live
                animated = rampWhenReady && !displayAsleep
                rampWhenReady = false
            } else {
                // Keep a pending ramp for the next attempt.
                failures += 1
                requestReset(.restart, &effects)
            }
        case let .policy(requested, isAnimated):
            guard requested != policy else { return [] }
            policy = requested
            animated = isAnimated && !displayAsleep
            let rebuilding = resetInFlight != nil || readers == .building
            rampWhenReady = animated && rebuilding && wantsPlayback
        case .assetChanged:
            failures = 0
            requestReset(.restart, &effects)
        case let .switchDeferred(url):
            deferredSwitch = url
            return []
        case .displaySleep:
            guard !displayAsleep else { return [] }
            displayAsleep = true
            rampWhenReady = false
        case let .displayWake(assetChanged):
            guard displayAsleep else { return [] }
            displayAsleep = false
            deferredSwitch = nil
            if assetChanged { failures = 0 }
            if case let .awaitingBuild(kind) = readers {
                let build = assetChanged ? max(kind, .restart) : kind
                if build == .resume, !wantsPlayback {
                    readers = .freed
                } else {
                    readers = .building
                    effects.append(.buildPipeline(build))
                }
            } else if assetChanged {
                requestReset(.restart, &effects)
            }
        case let .resetFlushed(flushed):
            guard flushed == generation, let kind = resetInFlight else { return [] }
            resetInFlight = nil
            if failures >= Self.maxFailures {
                readers = .failed
                effects.append(.showFallback)
            } else if displayAsleep {
                // Building decodes the first frame; nobody can see it now.
                readers = .awaitingBuild(kind)
            } else {
                readers = .building
                effects.append(.buildPipeline(kind))
            }
        case let .readerExhausted(token):
            guard acceptsFeed(token: token), readers == .live, resetInFlight == nil else { return [] }
            // A whole clip played: the pipeline works. The feed callback has
            // already stopped requesting; reconcile registers the next feed.
            failures = 0
            feeding = false
            effects.append(.swapToNextReader)
        case let .decoderFailed(token):
            guard acceptsFeed(token: token), readers == .live, resetInFlight == nil else { return [] }
            feeding = false
            failures += 1
            requestReset(.recover, &effects)
        case let .decoderInterrupted(token):
            guard acceptsFeed(token: token), readers == .live, resetInFlight == nil else { return [] }
            feeding = false
            failures += 1
            requestReset(.resume, &effects)
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
        case .building, .live, .freed, .failed:
            break
        }
        if deepPauseArmed {
            deepPauseArmed = false
            effects.append(.disarmDeepPause)
        }
        generation += 1
        resetInFlight = kind
        feeding = false
        clock = .stopped
        effects.append(.beginReset(kind, generation: generation))
    }

    /// Bring the clock, feed, and deep-pause timer in line with the state.
    private mutating func reconcile(animated: Bool, _ effects: inout [Effect]) {
        if !displayAsleep, resetInFlight == nil, readers == .freed, wantsPlayback {
            requestReset(.resume, &effects)
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
            feeding = true
            feedToken += 1
            effects.append(.startFeeding(token: feedToken))
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
