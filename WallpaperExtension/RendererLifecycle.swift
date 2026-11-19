import Foundation

/// Playback lifecycle of one `VideoRenderer`, owned by the renderer's serial
/// queue. It makes every decision and returns `Effect`s; the renderer does
/// the AVFoundation work for each. Keeping it free of AVFoundation lets the
/// orderings that kept a surface decoding with the displays off (#10) run as
/// unit tests.
///
/// Display sleep is held apart from the policy. Sleep stops the clock, the
/// feed, and any rebuild without overwriting the requested tier, so wake
/// resumes whatever the latest policy asks for. Because sleep and wake
/// arrive as events on the same queue as policy updates, an update decided
/// before sleep is undone by the sleep event and one decided after it sees
/// the gate.
///
/// A closed surface (invalidated by the agent, or a preview past its lease)
/// is a second gate beside sleep. It stops the clock and feed but keeps the
/// readers and the displayed frame, so a re-acquire resumes in place with no
/// flush and no blank frame. While either gate is shut a flushed reset waits
/// to build, and the renderer holds switches, so nothing decodes into the
/// held frame; the latest of them applies once both gates open.
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
        /// shows. A retry runs after a growing delay while playback is
        /// wanted, and at once when the asset changes.
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
        /// Report `.retryFired` after `after` seconds.
        case armRetry(after: TimeInterval)
        case disarmRetry
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
        case displaySleep
        /// The agent invalidated the surface, or a preview's lease ran out.
        case surfaceClosed
        /// The surface was acquired again. `assetChanged`: the renderer
        /// opened a switch it held while the surface was closed.
        case surfaceReopened(assetChanged: Bool)
        /// `assetChanged`: the renderer loaded the held switch or the tier's copy.
        case displayWake(assetChanged: Bool)
        case resetFlushed(generation: Int)
        /// The reader reached the end of the clip.
        case readerExhausted(token: Int)
        /// The renderer failed.
        case decoderFailed(token: Int)
        /// The reader failed, or a loop swap couldn't build one.
        case readerFailed(token: Int)
        /// The renderer needs a flush to resume decoding.
        case decoderInterrupted(token: Int)
        case rampFinished
        case deepPauseFired
        case retryFired
    }

    /// Consecutive failed builds or decodes before the fallback still shows.
    static let maxFailures = 3

    private(set) var policy: PlaybackPolicy = .full
    private(set) var displayAsleep = false
    private(set) var surfaceOpen = true
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
    /// Failed builds and decodes since the last completed loop, new asset, or
    /// retry.
    private(set) var failures = 0
    /// Times this video fell back to the still; sets the retry delay.
    private(set) var failedRounds = 0
    private(set) var retryArmed = false
    /// Bumped whenever a reset starts, so a stale flush completion is dropped.
    private(set) var generation = 0
    /// Readers were freed while the surface was closed (a preview past its
    /// lease). Its clock counts every loop, so resuming from it can seek past
    /// the clip (#27); the next rebuild restarts instead, whenever it runs.
    private(set) var restartFreedReaders = false

    /// `policy` is the tier the renderer was created for, so the recompute
    /// after its first frame doesn't move it off the copy it opened.
    init(policy: PlaybackPolicy = .full) {
        self.policy = policy
    }

    var wantsPlayback: Bool { wouldPlay(policy) }

    func wouldPlay(_ policy: PlaybackPolicy) -> Bool {
        policy != .paused && !displayAsleep && surfaceOpen
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
            failedRounds = 0
            requestReset(.restart, &effects)
        case .displaySleep:
            guard !displayAsleep else { return [] }
            displayAsleep = true
            rampWhenReady = false
        case .surfaceClosed:
            guard surfaceOpen else { return [] }
            surfaceOpen = false
            rampWhenReady = false
        case let .surfaceReopened(assetChanged):
            guard !surfaceOpen else { return [] }
            surfaceOpen = true
            releaseGates(assetChanged: assetChanged, &effects)
        case let .displayWake(assetChanged):
            guard displayAsleep else { return [] }
            displayAsleep = false
            releaseGates(assetChanged: assetChanged, &effects)
        case let .resetFlushed(flushed):
            guard flushed == generation, let kind = resetInFlight else { return [] }
            resetInFlight = nil
            if failures >= Self.maxFailures {
                readers = .failed
                failedRounds += 1
                rampWhenReady = false
                effects.append(.showFallback)
            } else if !gatesOpen {
                // Building decodes a first frame nobody can see, and on a
                // closed surface it would replace the held frame.
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
            failedRounds = 0
            feeding = false
            effects.append(.swapToNextReader)
        case let .decoderFailed(token):
            guard acceptsFeed(token: token), readers == .live, resetInFlight == nil else { return [] }
            feeding = false
            failures += 1
            requestReset(.recover, &effects)
        case let .readerFailed(token):
            // The renderer is fine, so the frame it shows stays up.
            guard acceptsFeed(token: token), readers == .live, resetInFlight == nil else { return [] }
            feeding = false
            failures += 1
            requestReset(.restart, &effects)
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
        case .retryFired:
            guard retryArmed else { return [] }
            retryArmed = false
            guard readers == .failed, resetInFlight == nil, wantsPlayback else { break }
            failures = 0
            requestReset(.restart, &effects)
        case .deepPauseFired:
            guard deepPauseArmed else { return [] }
            deepPauseArmed = false
            guard readers == .live, resetInFlight == nil, clock == .stopped else { break }
            readers = .freed
            if !surfaceOpen { restartFreedReaders = true }
            effects.append(.freeReaders)
        }
        reconcile(animated: animated, &effects)
        return effects
    }

    /// Seconds before retrying a video that fell back to the still for the
    /// `round`th time: soon after a transient failure, then rarely.
    static func retryDelay(round: Int) -> TimeInterval {
        let delays: [TimeInterval] = [2, 10, 60]
        return delays[min(max(round, 1), delays.count) - 1]
    }

    /// What a readiness callback reports before reading samples, or nil to
    /// feed. The flush flag comes first: Apple sets it alongside `.failed`, and
    /// that case only needs a flush and a keyframe, not a cleared frame.
    static func feedFault(requiresFlush: Bool, rendererFailed: Bool, hasReader: Bool, token: Int) -> Event? {
        if requiresFlush { return .decoderInterrupted(token: token) }
        if rendererFailed { return .decoderFailed(token: token) }
        if !hasReader { return .readerFailed(token: token) }
        return nil
    }

    /// What a callback reports when the reader returns no sample: the end of
    /// the clip only if the reader completed.
    static func outOfSamples(readerCompleted: Bool, token: Int) -> Event {
        readerCompleted ? .readerExhausted(token: token) : .readerFailed(token: token)
    }

    /// Neither the sleep gate nor the closed gate is shut.
    private var gatesOpen: Bool { !displayAsleep && surfaceOpen }

    /// A gate opened: run the build a shut gate held back, or the restart for
    /// an asset the renderer opened as it opened. Waits while the other gate
    /// is still shut.
    private mutating func releaseGates(assetChanged: Bool, _ effects: inout [Effect]) {
        if assetChanged { failures = 0 }
        guard gatesOpen else { return }
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
        if retryArmed {
            retryArmed = false
            effects.append(.disarmRetry)
        }
        generation += 1
        restartFreedReaders = false
        resetInFlight = kind
        feeding = false
        clock = .stopped
        effects.append(.beginReset(kind, generation: generation))
    }

    /// Bring the clock, feed, and deep-pause timer in line with the state.
    private mutating func reconcile(animated: Bool, _ effects: inout [Effect]) {
        if !displayAsleep, resetInFlight == nil, readers == .freed, wantsPlayback {
            // A restart's flush keeps the frame up, like a resume's.
            requestReset(restartFreedReaders ? .restart : .resume, &effects)
        }
        let ready = readers == .live && resetInFlight == nil
        let wantClock = wantsPlayback && ready

        switch clock {
        case .stopped, .rampingDown:
            if wantClock {
                clock = animated ? .rampingUp : .playing
                effects.append(animated ? .ramp(to: 1) : .setRate(1))
            } else if clock == .rampingDown, displayAsleep || !surfaceOpen || !ready {
                // Sleep or a closed surface cuts a ramp-down short instead of
                // decoding for seconds nobody sees.
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

        let wantRetry = readers == .failed && resetInFlight == nil && wantsPlayback
        if wantRetry != retryArmed {
            retryArmed = wantRetry
            effects.append(wantRetry ? .armRetry(after: Self.retryDelay(round: failedRounds)) : .disarmRetry)
        }
    }
}
