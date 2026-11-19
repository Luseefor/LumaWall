import AVFoundation
import CoreMedia
import ObjectiveC
import os

/// Call AVSampleBufferDisplayLayer's private `_setDisallowsVideoLayerDisplayCompositing:`
/// (a BOOL setter Apple's WallpaperExtensionKit uses on every AVSBDL). Resolved via the
/// ObjC runtime so the private selector never appears in a header; a no-op if the API
/// ever disappears. Prevents the layer painting opaque black before its first frame.
private func setDisallowsVideoLayerDisplayCompositing(_ layer: CALayer, _ flag: Bool) {
    let sel = NSSelectorFromString("_setDisallowsVideoLayerDisplayCompositing:")
    guard layer.responds(to: sel),
          let imp = class_getMethodImplementation(type(of: layer), sel) else { return }
    typealias SetBoolFn = @convention(c) (AnyObject, Selector, ObjCBool) -> Void
    unsafeBitCast(imp, to: SetBoolFn.self)(layer, sel, ObjCBool(flag))
}

final class VideoRenderer: @unchecked Sendable {
    /// Process-wide instance counter so log lines can be attributed to a specific
    /// renderer object (to catch stale/duplicate renderers from acquire races).
    private static let idCounter = OSAllocatedUnfairLock(initialState: 0)
    let debugID: Int = VideoRenderer.idCounter.withLock { $0 += 1; return $0 }

    let displayLayer: AVSampleBufferDisplayLayer
    /// The display's size in pixels, so Full Quality can pick a copy that
    /// fills it without decoding more than it can show. Updated by `resize`
    /// (Lifecycle queue) and read on the renderer queue, so lock-backed.
    var displayPixelSize: CGSize { pixelSize.withLock { $0 } }
    private let pixelSize: OSAllocatedUnfairLock<CGSize>
    let timebase: CMTimebase
    private let renderer: AVSampleBufferVideoRenderer
    private let stillFrameLayer: CALayer
    private var asset: AVURLAsset
    private var videoTrack: AVAssetTrack
    private let queue = DispatchQueue(label: "video-renderer", qos: .userInitiated)
    private var isRunning = true
    /// Every playback decision for this renderer: clock, feed, deep pause,
    /// resets, and the display-sleep gate. Touched only on `queue`; see
    /// `RendererLifecycle`. Public entry points hop to `queue` and send events.
    private var lifecycle: RendererLifecycle
    /// Events raised while effects run (an instant ramp completion) wait here
    /// so each event's effects run against the state that produced them.
    private var pendingEvents: [RendererLifecycle.Event] = []
    private var isDispatching = false
    /// What `PowerMonitor` last heard about this renderer being active.
    private var reportedPlayback = false
    private var rampTimer: (any DispatchSourceTimer)?
    private var deepPauseTimer: (any DispatchSourceTimer)?
    private var retryTimer: (any DispatchSourceTimer)?

    private var currentReader: AVAssetReader?
    private var currentOutput: AVAssetReaderTrackOutput?
    private var nextReader: AVAssetReader?
    private var nextOutput: AVAssetReaderTrackOutput?

    /// Diagnostic: number of remaining feed-loop ticks to log after a restart.
    private var feedLogBudget = 0

    // Gapless looping state.
    // ptsOffset accumulates across loops so both DTS and PTS are monotonically increasing.
    // lastEnqueuedEnd tracks the highest sample end time (max, not last, handles B-frames).
    private var ptsOffset: CMTime = .zero
    /// The loop before `ptsOffset`'s, whose tail may still be on screen.
    private var previousPtsOffset: CMTime = .zero
    private var lastEnqueuedEnd: CMTime = .zero
    private var nominalFrameRate: Double = 60

    /// Which file to open on a switch, tier change, wake, and loop: the
    /// variant selector and a switch held through sleep. Queue-only, like
    /// `lifecycle`.
    private var copy: RendererCopy
    /// The tier `applyPolicies` would give this renderer now. Read on the
    /// queue when a switch or the first frame picks a copy, so a recompute
    /// still on its way can't make it open the wrong one.
    private let tierSource: @Sendable () -> PlaybackPolicy
    /// Loads the still of the given original shown when the video can't be
    /// rebuilt. Called only then, with the original being played (switches,
    /// including ones held until wake or reopen, move it), so a playing
    /// renderer doesn't hold a decoded frame; nil shows the gradient.
    private let fallbackStill: @Sendable (URL) -> CGImage?
    /// Whether init enqueued a still into the display layer. Set once there.
    private(set) var seededStill = false
    /// Whether `start()` enqueued the first video frame. Set on the queue
    /// before `onFirstFrameReady` runs.
    private(set) var showedFirstFrame = false

    /// Opens the copy `variantSelector` picks for the root layer's pixel size
    /// and the tier from `tierSource`, falling back to `videoURL` when that
    /// copy has no video track, so the first frame is decoded from the file
    /// the renderer plays.
    static func create(
        rootLayer: CALayer,
        videoURL: URL,
        stillImage: CGImage? = nil,
        fallbackStill: @escaping @Sendable (URL) -> CGImage? = { _ in nil },
        variantSelector: @escaping RendererCopy.Selector,
        tierSource: @escaping @Sendable () -> PlaybackPolicy,
    ) async throws -> VideoRenderer {
        let pixels = CGSize(
            width: rootLayer.bounds.width * rootLayer.contentsScale,
            height: rootLayer.bounds.height * rootLayer.contentsScale
        )
        let policy = tierSource()
        let opened = await RendererCopy.opening(videoURL, selector: variantSelector, tier: policy, displayPixels: pixels) { (url: URL) async -> (AVURLAsset, AVAssetTrack)? in
            let asset = AVURLAsset(url: url)
            guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
                traceLog("  [Renderer] no video track in \(url.lastPathComponent)")
                return nil
            }
            return (asset, track)
        }
        guard let (asset, track) = opened else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [
                NSLocalizedDescriptionKey: "No video track found in \(videoURL.lastPathComponent)",
            ])
        }
        let nominalFrameRate = Double(try await track.load(.nominalFrameRate))

        let displayLayer = AVSampleBufferDisplayLayer()
        LWSetVideoGravity(displayLayer, .resizeAspectFill)
        displayLayer.frame = rootLayer.bounds
        displayLayer.contentsScale = rootLayer.contentsScale
        // Opaque: the per-surface context fix (each Space/lock surface owns its own
        // CAContext) is what stops the black, not this layer's opacity. Leaving the
        // layer non-opaque only adds a per-frame blend against what's behind it, which
        // makes the layer visibly blink while the compositor rebuilds it during a
        // switch. Opaque keeps the switch seamless.
        displayLayer.isOpaque = true
        // Match Apple's WallpaperExtensionKit: stop the AVSampleBufferDisplayLayer from
        // painting opaque BLACK before its first frame is composited. On a cold start the
        // Agent hosts our context the instant we reply, and without this an as-yet-empty
        // layer flashes black (the residual "black still"). Apple sets this on every AVSBDL.
        setDisallowsVideoLayerDisplayCompositing(displayLayer, true)
        // Added to the tree in init() inside an action-free transaction (below).

        return VideoRenderer(
            rootLayer: rootLayer,
            displayLayer: displayLayer,
            asset: asset,
            videoTrack: track,
            stillImage: stillImage,
            fallbackStill: fallbackStill,
            nominalFrameRate: nominalFrameRate,
            originalURL: videoURL,
            variantSelector: variantSelector,
            tierSource: tierSource,
            policy: policy,
        )
    }

    private init(
        rootLayer: CALayer,
        displayLayer: AVSampleBufferDisplayLayer,
        asset: AVURLAsset,
        videoTrack: AVAssetTrack,
        stillImage: CGImage?,
        fallbackStill: @escaping @Sendable (URL) -> CGImage?,
        nominalFrameRate: Double,
        originalURL: URL,
        variantSelector: @escaping RendererCopy.Selector,
        tierSource: @escaping @Sendable () -> PlaybackPolicy,
        policy: PlaybackPolicy,
    ) {
        self.displayLayer = displayLayer
        self.copy = RendererCopy(original: originalURL, selector: variantSelector)
        self.tierSource = tierSource
        self.lifecycle = RendererLifecycle(policy: policy)
        self.pixelSize = OSAllocatedUnfairLock(initialState: CGSize(
            width: rootLayer.bounds.width * rootLayer.contentsScale,
            height: rootLayer.bounds.height * rootLayer.contentsScale
        ))
        self.renderer = LWSampleBufferRenderer(displayLayer)
        self.asset = asset
        self.videoTrack = videoTrack
        self.fallbackStill = fallbackStill
        if nominalFrameRate.isFinite, nominalFrameRate > 0 {
            self.nominalFrameRate = nominalFrameRate
        }

        self.stillFrameLayer = CALayer()
        stillFrameLayer.frame = rootLayer.bounds
        stillFrameLayer.contentsGravity = .resizeAspectFill
        stillFrameLayer.contentsScale = rootLayer.contentsScale
        stillFrameLayer.opacity = 0
        stillFrameLayer.name = "lumawall.stillFrame"

        var tb: CMTimebase?
        CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(),
            timebaseOut: &tb,
        )
        self.timebase = tb!
        CMTimebaseSetTime(timebase, time: .zero)
        // Rate stays 0 until start() to prevent the timebase from advancing
        // during the async gap between init and start, which would cause
        // the first batch of frames to be considered "late" and dropped.
        CMTimebaseSetRate(timebase, rate: 0.0)
        LWSetControlTimebase(displayLayer, timebase)

        // Install the layers and seed the still in ONE action-free transaction, so
        // Core Animation doesn't play an implicit "onOrderIn" animation (the video
        // appearing to zoom/fade in). The still is an IOSurface-backed sample buffer
        // at PTS 0, unlike CALayer.contents (black when hosted cross-process) it
        // composites into WallpaperAgent's CALayerHost, so the desktop shows the
        // still immediately; the video's first real frame (also PTS 0) plays over it
        // once rate=1.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rootLayer.sublayers?.filter { $0.name == "lumawall.stillFrame" }.forEach { $0.removeFromSuperlayer() }
        // A no-video acquire installs a CAGradientLayer fallback on this same
        // rootLayer; a later video create must remove it, or the gradient
        // stacks behind every subsequent renderer on this surface.
        rootLayer.sublayers?.filter { $0 is CAGradientLayer }.forEach { $0.removeFromSuperlayer() }
        rootLayer.addSublayer(displayLayer)
        rootLayer.addSublayer(stillFrameLayer)
        traceLog("  [Renderer #\(debugID)] CREATED for \(asset.url.lastPathComponent) tier=\(policy), displayLayer=\(ObjectIdentifier(displayLayer)), rootLayer sublayers=\((rootLayer.sublayers?.count ?? 0)), pixels=\(Int(displayPixelSize.width))x\(Int(displayPixelSize.height))")
        if let stillImage, let stillBuffer = makeStillSampleBuffer(from: stillImage) {
            // Tag DisplayImmediately so the still is shown the instant it's enqueued,
            // rather than waiting on the control timebase (which is frozen at rate 0 here).
            // Without this the frame can sit undisplayed → the layer reads empty → black.
            Self.setDisplayImmediately(stillBuffer)
            renderer.enqueue(stillBuffer)
            seededStill = true
            traceLog("  [Renderer #\(debugID)] Seeded still into display layer (\(stillImage.width)x\(stillImage.height))")
        } else {
            traceLog("  [Renderer #\(debugID)] Seeded nothing (stillImage present: \(stillImage != nil)); the display layer is empty until the first frame")
        }
        CATransaction.commit()
        // flush() (not just commit()) is what pushes the layer tree to the render
        // server for a REMOTE context, without it the still never reaches the
        // WindowServer and the desktop stays black until a later flush.
        CATransaction.flush()
    }

    /// Start playback: decode and enqueue the first frame, then begin the feed loop.
    /// Runs on the renderer's serial queue rather than the caller's thread. The
    /// first-frame `copyNextSampleBuffer` is a blocking decode, and the caller is a
    /// Swift-concurrency (cooperative) task; blocking a cooperative thread violates
    /// forward progress and starves the extension's tiny executor.
    ///
    /// `onFirstFrameReady`, if provided, is invoked AFTER the first frame is enqueued and
    /// flushed to the render server, i.e. once this renderer's CAContext is actually
    /// displaying video. The acquire path uses it to defer its XPC reply until the new
    /// context is live, so WallpaperAgent keeps compositing the OLD wallpaper until then
    /// and the host swap lands directly on playing video (no blink / still-flash / zoom),
    /// mirroring Apple's own extensions. It is called exactly once on every path,
    /// including early exits, so a gated reply can never hang.
    func start(onFirstFrameReady: (@Sendable () -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { onFirstFrameReady?(); return }
            traceLog("  [start #\(debugID)] asset=\(asset.url.lastPathComponent)")
            guard isRunning else { traceLog("  [start #\(debugID)] aborted, already stopped"); onFirstFrameReady?(); return }
            // The tier can change while `create` loads the track, and a
            // policy recorded before this job doesn't pick a copy when it
            // pauses. Pick the first frame's copy for the tier now.
            let tier = tierSource()
            if case let .opened(loaded) = copy.retier(current: asset.url, tier: tier, displayPixels: displayPixelSize, open: loadBlocking) {
                traceLog("  [start #\(debugID)] tier \(tier) opens a different file than create")
                adopt(loaded)
            }
            send(.policy(tier, animated: false))
            // Starts the clock and the feed once the pipeline reports built,
            // unless the displays sleep or a pause was applied before this ran.
            // The global flag is read here, on the queue: sleep sets it before
            // sending `displayDidSleep` to the renderers it knows, so a renderer
            // it missed still sees it.
            send(.started(displayAsleep: WallpaperState.shared.isDisplayAsleep))
            let built = buildFirstPipeline()
            if !built {
                extensionLog("  [start #\(debugID)] FAILED to start reading \(asset.url.lastPathComponent)")
            }
            send(.pipelineBuilt(built))

            // The context now holds a live, composited video frame (or, on failure,
            // the seeded still). Release the gate so the acquire can reply and the
            // agent can swap to us.
            onFirstFrameReady?()
        }
    }

    /// `start()`'s first pipeline: like `buildPipeline(.restart)`, but the
    /// first frame is flushed to the render server so the context really shows
    /// video before the acquire reply. Queue-only.
    private func buildFirstPipeline() -> Bool {
        guard let reader = try? AVAssetReader(asset: asset) else { return false }
        let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { return false }

        // Reset timebase BEFORE first enqueue so the frame isn't seen as late.
        CMTimebaseSetTime(timebase, time: .zero)

        // Enqueue the first frame and flush it to the render server inside an
        // action-free transaction, so the context is genuinely displaying video
        // before onFirstFrameReady fires (the deferred acquire reply gates on this).
        // Tagged to show at once: on a sleeping display the clock stays at 0.
        if let firstSample = output.copyNextSampleBuffer() {
            Self.setDisplayImmediately(firstSample)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            renderer.enqueue(firstSample)
            CATransaction.commit()
            CATransaction.flush()
            showedFirstFrame = true
        }

        currentReader = reader
        currentOutput = output
        ptsOffset = .zero
        lastEnqueuedEnd = .zero
        prepareNextReader()
        return true
    }

    /// Re-frame the video + still layers to a new destination geometry (points) and
    /// backing scale, used when a display reconnects at, or switches to, a different
    /// resolution. Both layers fill the root and are `resizeAspectFill`, so re-framing
    /// them to the full bounds is all that's needed; the AVSampleBufferDisplayLayer
    /// re-fits the decoded frames to the new size on the next composite. Synchronous,
    /// inside an action-free flushed transaction, to match the acquire path's own layer
    /// mutations (which run on the same Lifecycle queue, off the main thread).
    func resize(to destSize: CGSize, scale: CGFloat) {
        let bounds = CGRect(origin: .zero, size: destSize)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        displayLayer.contentsScale = scale
        stillFrameLayer.frame = bounds
        stillFrameLayer.contentsScale = scale
        CATransaction.commit()
        CATransaction.flush()
        // The next loop boundary picks the copy for the new size.
        pixelSize.withLock { $0 = CGSize(width: destSize.width * scale, height: destSize.height * scale) }
        traceLog("  [resize #\(debugID)] → \(destSize) @\(scale)x")
    }

    /// Switch to a different video IN PLACE, reusing this renderer's existing
    /// `displayLayer`. The layer is already attached to the display's CAContext and
    /// hosted by WallpaperAgent, so feeding it frames from a new asset updates the
    /// desktop, whereas building a fresh renderer (new `AVSampleBufferDisplayLayer`)
    /// added to an already-hosted context does NOT composite (the switch-between-
    /// videos bug). So we keep the one hosted layer and restart it on the new asset.
    ///
    /// Fully serialized on `queue`, no `Task`: the track load blocks the queue thread
    /// (a real thread we own, which already blocks for decodes). Because every switch
    /// runs to completion in FIFO order on one thread, rapid switching is naturally
    /// last-*requested*-wins with no cancellation bookkeeping. The only async hop is
    /// the renderer's `flush`, which is serialized and coalesces rapid switches.
    /// While the displays sleep the request is held (latest wins) and wake
    /// resolves it; a restart would decode the new clip's first frames with
    /// nothing on screen.
    ///
    /// `url` is the new choice's original and `variantSelector` picks its
    /// copies. The switch opens the copy for this display and the tier read
    /// now (falling back to the original), and applies that tier in the same
    /// job. A switch that opens nothing keeps the old choice and its selector.
    func switchVideo(to url: URL, variantSelector: @escaping RendererCopy.Selector) {
        traceLog("  [switchVideo #\(debugID)] REQUEST target=\(url.lastPathComponent)")
        queue.async { [weak self] in
            guard let self, isRunning else { return }
            let tier = tierSource()
            let hold = lifecycle.displayAsleep || !lifecycle.surfaceOpen
            switch copy.switchTo(url, selector: variantSelector, current: asset.url, tier: tier, displayPixels: displayPixelSize, hold: hold, open: loadBlocking) {
            case .held:
                traceLog("  [switchVideo #\(debugID)] DEFERRED until wake or reopen: \(url.lastPathComponent)")
                return
            case let .opened(loaded):
                adopt(loaded)
                send(.assetChanged)
            case .unchanged:
                traceLog("  [switchVideo #\(debugID)] DEDUP: already on \(asset.url.lastPathComponent)")
            case .failed:
                extensionLog("  [switchVideo #\(debugID)] no playable file for \(url.lastPathComponent), keeping \(asset.url.lastPathComponent)")
            }
            applyTier(tier, animated: false)
        }
    }

    /// Load `url`'s video track, or nil when it has none. Queue-only; blocks.
    private func loadBlocking(_ url: URL) -> (AVURLAsset, AVAssetTrack)? {
        let newAsset = AVURLAsset(url: url)
        guard let track = Self.loadFirstVideoTrackBlocking(newAsset) else {
            traceLog("  [Renderer #\(debugID)] no video track in \(url.lastPathComponent)")
            return nil
        }
        return (newAsset, track)
    }

    /// Make a loaded file the current asset; the next build restarts on it.
    private func adopt(_ loaded: (AVURLAsset, AVAssetTrack)) {
        (asset, videoTrack) = loaded
        traceLog("  [Renderer #\(debugID)] now reading \(asset.url.lastPathComponent)")
    }

    /// Tag a sample buffer so the renderer displays it immediately, replacing all
    /// previously enqueued/displayed images regardless of timestamps (per
    /// AVQueuedSampleBufferRendering docs). Used for the first frame of a switched
    /// video so the swap is instant and doesn't wait on the control timebase.
    private static func setDisplayImmediately(_ sample: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) else { return }
        let count = CFArrayGetCount(attachments)
        for i in 0 ..< count {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, i), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque(),
            )
        }
    }

    /// Load the first video track synchronously. Call ONLY from the renderer's serial
    /// `queue`. It blocks that (real, owned) thread on a semaphore while AVFoundation
    /// loads the track on its own internal queue, so there's no cooperative-executor
    /// starvation and no out-of-order Task completion. Local files load in a few ms.
    /// Must never run on the main thread (or any Swift cooperative thread).
    private static func loadFirstVideoTrackBlocking(_ asset: AVURLAsset) -> AVAssetTrack? {
        assert(!Thread.isMainThread, "blocking track load must not run on the main thread")
        traceLog("  [load] blocking-load START \(asset.url.lastPathComponent) (queue will block until AVF replies)")
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: AVAssetTrack?
        asset.loadTracks(withMediaType: .video) { tracks, _ in
            result = tracks?.first
            sem.signal()
        }
        sem.wait()
        traceLog("  [load] blocking-load DONE \(asset.url.lastPathComponent) track=\(result != nil ? "ok" : "nil")")
        return result
    }

    /// Stop playback. Dispatches synchronously to the renderer queue to ensure
    /// no callback is mid-flight before canceling the reader. Timer teardown
    /// joins the same hop so a pending event can't arm a timer after us.
    func stop() {
        queue.sync { [weak self] in
            guard let self else { return }
            extensionLog("  [stop #\(debugID)] stopping renderer for \(asset.url.lastPathComponent)")
            cancelRamp()
            cancelDeepPauseTimer()
            cancelRetryTimer()
            isRunning = false
            reportPlayback()
            renderer.stopRequestingMediaData()
            dropReaders()
            CMTimebaseSetRate(timebase, rate: 0.0)
        }
        // Clean up layers from the layer tree
        displayLayer.removeFromSuperlayer()
        stillFrameLayer.removeFromSuperlayer()
    }

    // MARK: - Playback control

    /// `hardPause`: the pause must stop decoding at once
    /// (`RampMath.cutsRampDown`), so it skips the ramp and ends one in flight.
    func applyPolicy(_ policy: PlaybackPolicy, animated: Bool = false, hardPause: Bool = false) {
        queue.async { [weak self] in
            guard let self, isRunning else { return }
            applyTier(policy, animated: animated && !hardPause)
            if hardPause { send(.hardPause) }
        }
    }

    /// Queue-only body of `applyPolicy`, also run by a switch for the tier it
    /// opened.
    private func applyTier(_ policy: PlaybackPolicy, animated: Bool) {
        guard policy != lifecycle.policy else { return }
        extensionLog("  [applyPolicy #\(debugID)] \(lifecycle.policy) → \(policy) animated=\(animated) asleep=\(lifecycle.displayAsleep) asset=\(asset.url.lastPathComponent)")
        // Battery tiers resolve to downscaled siblings via the selector,
        // but the selector is otherwise consulted only at loop boundaries,
        // without this, flipping to Battery Saver (or unplugging on
        // Automatic) kept playing the full file until the clip looped, up
        // to a minute later. Switch now when the URL differs. The asset
        // change goes first so the tier's resume waits for its reset.
        if lifecycle.wouldPlay(policy),
           case let .opened(loaded) = copy.retier(current: asset.url, tier: policy, displayPixels: displayPixelSize, open: loadBlocking) {
            adopt(loaded)
            send(.assetChanged)
        }
        send(.policy(policy, animated: animated))
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
               case let .opened(loaded) = copy.reopen(current: asset.url, tier: lifecycle.policy, displayPixels: displayPixelSize, open: loadBlocking) {
                adopt(loaded)
                changed = true
            }
            send(.surfaceReopened(assetChanged: changed))
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
               case let .opened(loaded) = copy.wake(current: asset.url, tier: lifecycle.policy, displayPixels: displayPixelSize, open: loadBlocking) {
                adopt(loaded)
                changed = true
            }
            send(.displayWake(assetChanged: changed))
        }
    }

    /// Run one event through the lifecycle and perform its effects. Queue-only.
    private func send(_ event: RendererLifecycle.Event) {
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
    private func reportPlayback() {
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
            let onBattery = PowerMonitor.shared.currentState.isOnBattery
            ramp(to: target, over: RampMath.fullDuration(toward: target, onBattery: onBattery)) { [weak self] in
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

    /// Rebuilding kept failing: show the creation still, or the no-video
    /// gradient when there is none, rather than a frozen or cleared frame. The
    /// reset before this flushed the renderer, so it accepts the buffer.
    private func showFallbackStill() {
        let still = fallbackStill(copy.activeOriginal)
        extensionLog("  [Renderer #\(debugID)] gave up rebuilding \(asset.url.lastPathComponent) after \(RendererLifecycle.maxFailures) failures, showing \(still == nil ? "the gradient" : "the still")")
        guard let image = still ?? Self.makeGradientStill(),
              let buffer = makeStillSampleBuffer(from: image) else { return }
        Self.setDisplayImmediately(buffer)
        renderer.enqueue(buffer)
    }

    /// The acquire path's no-video gradient as an image; the display layer
    /// scales it to fill.
    static func makeGradientStill() -> CGImage? {
        let side = 64
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue,
        ), let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                CGColor(red: 0.2, green: 0.0, blue: 0.5, alpha: 1.0),
                CGColor(red: 0.0, green: 0.3, blue: 0.7, alpha: 1.0),
                CGColor(red: 0.0, green: 0.6, blue: 0.4, alpha: 1.0),
            ] as CFArray,
            locations: nil,
        ) else { return nil }
        // Same start and end points as the CAGradientLayer, in the same
        // bottom-left-origin space.
        context.drawLinearGradient(
            gradient, start: .zero, end: CGPoint(x: side, y: side), options: [],
        )
        return context.makeImage()
    }

    private func dropReaders() {
        currentReader?.cancelReading()
        nextReader?.cancelReading()
        currentReader = nil
        currentOutput = nil
        nextReader = nil
        nextOutput = nil
    }

    // MARK: - Reset

    /// The one decoder reset, for switches, deep-pause wakes, and recovery.
    /// A `flush` is a decoder RESET that discards anything enqueued before it
    /// completes, and two overlapping flushes corrupt the renderer
    /// (rapid-switch breakage), so the lifecycle keeps one in flight and builds
    /// the new pipeline only when this flush reports back. The clock freezes
    /// first so fresh PTS-0 frames aren't judged late.
    private func beginReset(_ kind: RendererLifecycle.ResetKind, generation: Int) {
        traceLog("  [reset #\(debugID)] BEGIN \(kind) gen=\(generation) asset=\(asset.url.lastPathComponent)")
        cancelRamp()
        CMTimebaseSetRate(timebase, rate: 0.0)
        renderer.stopRequestingMediaData()
        dropReaders()
        // Hold the displayed frame (no blank) unless the decoder failed. The first
        // new frame is tagged DisplayImmediately and replaces it.
        renderer.flush(removingDisplayedImage: kind == .recover) { [weak self] in
            guard let self else { return }
            queue.async { [weak self] in
                guard let self, isRunning else { return }
                send(.resetFlushed(generation: generation))
            }
        }
    }

    /// Build readers on the current asset after a reset's flush and show their
    /// first frame at once. `.resume` continues from the paused position (a
    /// display-sleep or screen-lock wake resumes the same video instead of
    /// restarting it); the other kinds start from 0.
    private func buildPipeline(_ kind: RendererLifecycle.ResetKind) -> Bool {
        let resumeTime = CMTimebaseGetTime(timebase)
        let continuing = kind == .resume && resumeTime.isNumeric && resumeTime > .zero
        // The timeline counts every loop; seek within the loop on screen and
        // keep its offset so the timeline stays continuous.
        let resumePoint = LoopTiming.resumePoint(timeline: resumeTime, loopStart: ptsOffset, previousLoopStart: previousPtsOffset)
        guard let reader = try? AVAssetReader(asset: asset) else {
            extensionLog("  [reset #\(debugID)] FAILED to create AVAssetReader for \(asset.url.lastPathComponent)")
            return false
        }
        if continuing {
            // AVAssetReader seeks to the enclosing keyframe and emits from here.
            reader.timeRange = CMTimeRange(start: resumePoint.assetTime, duration: .positiveInfinity)
        }
        let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            extensionLog("  [reset #\(debugID)] FAILED to start reading \(asset.url.lastPathComponent): \(reader.error?.localizedDescription ?? "unknown")")
            return false
        }
        currentReader = reader
        currentOutput = output

        ptsOffset = continuing ? resumePoint.loopStart : .zero
        previousPtsOffset = ptsOffset
        lastEnqueuedEnd = continuing ? resumeTime : .zero
        if !continuing {
            CMTimebaseSetTime(timebase, time: .zero)
        }

        // Enqueue the first frame while the clock is still frozen, tagged
        // DisplayImmediately so it replaces the held frame the moment it decodes.
        if let sample = output.copyNextSampleBuffer() {
            let first = offsetTimingForLoop(sample)
            Self.setDisplayImmediately(first)
            renderer.enqueue(first)
            let pts = CMSampleBufferGetPresentationTimeStamp(first)
            let dur = CMSampleBufferGetDuration(first)
            if pts.isValid {
                lastEnqueuedEnd = estimatedSampleEnd(pts: pts, duration: dur)
            }
        }
        traceLog("  [reset #\(debugID)] BUILT \(kind) continuing=\(continuing) asset=\(asset.url.lastPathComponent) rendererStatus=\(renderer.status.rawValue)")
        feedLogBudget = 4
        prepareNextReader()
        return true
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

    private func cancelRamp() {
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

    private func cancelDeepPauseTimer() {
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

    private func cancelRetryTimer() {
        retryTimer?.cancel()
        retryTimer = nil
    }

    // MARK: - Preloaded Loop Reader

    private func prepareNextReader() {
        // Deferred to a separate queue job so the (brief, blocking) variant track load
        // doesn't stall whatever called us, but it stays strictly ordered on `queue`.
        // No Task involved.
        let generation = lifecycle.generation
        queue.async { [weak self] in
            guard let self, isRunning else { return }
            // Skip for a replaced pipeline or sleeping displays: a loop
            // boundary waits for wake, and the swap builds a reader itself
            // when none is ready.
            guard lifecycle.generation == generation, !lifecycle.displayAsleep else { return }
            let nextURL = copy.preloadURL(current: asset.url, tier: lifecycle.policy, displayPixels: displayPixelSize)
            if nextURL != asset.url {
                let newAsset = AVURLAsset(url: nextURL)
                guard let track = Self.loadFirstVideoTrackBlocking(newAsset) else {
                    traceLog("  [Renderer] No video track in variant: \(nextURL.lastPathComponent)")
                    return
                }
                installNextReader(asset: newAsset, track: track)
            } else {
                installNextReader(asset: asset, track: videoTrack)
            }
        }
    }

    /// Build an asset reader on the renderer queue and store it as the
    /// preloaded next reader. Must run on `queue`.
    private func installNextReader(asset: AVURLAsset, track: AVAssetTrack) {
        guard let reader = try? AVAssetReader(asset: asset) else {
            traceLog("  [Renderer] Failed to create next reader")
            return
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        nextReader = reader
        nextOutput = output
    }

    /// Swap to the preloaded next reader at a loop boundary.
    /// Uses timing offset for gapless continuation, no flush, no timebase reset.
    /// The lifecycle runs it only while feeding is allowed and starts the feed
    /// after it.
    private func swapToNextReader() {
        // Advance offset so the next loop's DTS/PTS continue the timeline.
        previousPtsOffset = ptsOffset
        ptsOffset = lastEnqueuedEnd

        // The preload (or, with none, the current file) may predate a tier
        // change; read the tier's copy from this loop on.
        let preloaded = (nextReader?.asset as? AVURLAsset)?.url ?? asset.url
        if let replacement = copy.loopReplacement(preloaded: preloaded, current: asset.url, tier: lifecycle.policy, displayPixels: displayPixelSize),
           let (newAsset, track) = loadBlocking(replacement) {
            traceLog("  [Renderer] preload \(preloaded.lastPathComponent) is for an older tier, looping into \(replacement.lastPathComponent)")
            nextReader = nil
            nextOutput = nil
            installNextReader(asset: newAsset, track: track)
        }

        if let nr = nextReader, let no = nextOutput {
            if let nrAsset = nr.asset as? AVURLAsset, nrAsset.url != asset.url {
                asset = nrAsset
                videoTrack = no.track
                traceLog("  [Renderer] Switched variant: \(nrAsset.url.lastPathComponent)")
            }
            currentReader = nr
            currentOutput = no
            nextReader = nil
            nextOutput = nil
        } else {
            traceLog("  [Renderer] Next reader not ready, creating synchronously")
            guard let reader = try? AVAssetReader(asset: asset) else {
                traceLog("  [Renderer] Failed to create fallback reader")
                // The feed reports the missing reader as a failure.
                currentReader = nil
                currentOutput = nil
                return
            }
            let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            reader.add(output)
            currentReader = reader
            currentOutput = output
        }

        currentReader?.startReading()

        prepareNextReader()
    }

    // MARK: - Playback Loop

    /// Feed the renderer from the current reader under registration `token`.
    /// Stopping the feed retires the token, so a readiness callback already
    /// queued when the feed stopped (display sleep, a reset) returns without
    /// touching AVFoundation, and the events it would raise are dropped.
    private func feedFromCurrentReader(token: Int) {
        renderer.requestMediaDataWhenReady(on: queue) { [weak self] in
            guard let self, isRunning, lifecycle.acceptsFeed(token: token) else { return }
            // Every way out below stops this registration before reporting.
            // Dispatch async: requestMediaDataWhenReady is not reentrant.
            func report(_ event: RendererLifecycle.Event) {
                renderer.stopRequestingMediaData()
                queue.async { [weak self] in self?.send(event) }
            }

            // A discontinuity, a failed renderer, or no reader (a loop swap
            // couldn't build one) all go through the lifecycle's reset.
            if let fault = RendererLifecycle.feedFault(
                requiresFlush: renderer.requiresFlushToResumeDecoding,
                rendererFailed: renderer.status == .failed,
                hasReader: currentReader != nil && currentOutput != nil,
                token: token,
            ) {
                extensionLog("  [feed #\(debugID)] \(fault) status=\(renderer.status.rawValue) err=\(renderer.error?.localizedDescription ?? "-")")
                report(fault)
                return
            }
            guard let currentReader, let currentOutput else { return }

            var enqueuedThisTick = 0
            while renderer.isReadyForMoreMediaData {
                if let sample = currentOutput.copyNextSampleBuffer() {
                    let adjusted = offsetTimingForLoop(sample)
                    enqueuedThisTick += 1

                    // Track the highest end time (max handles B-frame reordering).
                    // Some containers emit padding samples with invalid PTS, skip those
                    // to prevent NaN from poisoning the timeline offset.
                    let pts = CMSampleBufferGetPresentationTimeStamp(adjusted)
                    let dur = CMSampleBufferGetDuration(adjusted)
                    if pts.isValid {
                        let sampleEnd = estimatedSampleEnd(pts: pts, duration: dur)
                        if sampleEnd > lastEnqueuedEnd {
                            lastEnqueuedEnd = sampleEnd
                        }
                    }

                    renderer.enqueue(adjusted)
                } else {
                    let event = RendererLifecycle.outOfSamples(readerCompleted: currentReader.status == .completed, token: token)
                    if event != .readerExhausted(token: token) || feedLogBudget > 0 {
                        traceLog("  [feed #\(debugID)] reader out of samples after \(enqueuedThisTick) this tick; readerStatus=\(currentReader.status.rawValue) err=\(currentReader.error?.localizedDescription ?? "-")")
                    }
                    report(event)
                    return
                }
            }
            if feedLogBudget > 0 {
                feedLogBudget -= 1
                traceLog("  [feed #\(debugID)] tick enqueued=\(enqueuedThisTick) status=\(renderer.status.rawValue) requiresFlush=\(renderer.requiresFlushToResumeDecoding) ready=\(renderer.isReadyForMoreMediaData) timebase=\(CMTimebaseGetTime(timebase).seconds)")
            }
        }
    }

    private func estimatedSampleEnd(pts: CMTime, duration: CMTime) -> CMTime {
        if duration.isValid, duration > .zero {
            return CMTimeAdd(pts, duration)
        }
        return CMTimeAdd(pts, fallbackFrameDuration())
    }

    private func fallbackFrameDuration() -> CMTime {
        let fps = max(nominalFrameRate, 1)
        let timescale = CMTimeScale(min(120_000, max(1, Int((fps * 100).rounded()))))
        return CMTime(value: 100, timescale: timescale)
    }

    /// Offset both DTS and PTS of a sample for gapless looping.
    /// Returns the original sample unchanged for the first loop (no copy needed).
    /// For subsequent loops, creates a lightweight copy with adjusted timing
    /// (shares the underlying data buffer, and only the timing metadata differs).
    private func offsetTimingForLoop(_ sample: CMSampleBuffer) -> CMSampleBuffer {
        guard ptsOffset > .zero else { return sample }

        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let dts = CMSampleBufferGetDecodeTimeStamp(sample)
        let dur = CMSampleBufferGetDuration(sample)

        var timingInfo = CMSampleTimingInfo(
            duration: dur,
            presentationTimeStamp: pts.isValid ? CMTimeAdd(pts, ptsOffset) : pts,
            decodeTimeStamp: dts.isValid ? CMTimeAdd(dts, ptsOffset) : .invalid,
        )

        var adjusted: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: nil,
            sampleBuffer: sample,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleBufferOut: &adjusted,
        )

        return adjusted ?? sample
    }
}
