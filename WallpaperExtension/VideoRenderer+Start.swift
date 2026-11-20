import AVFoundation
import CoreMedia
import os

extension VideoRenderer {
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
            requestedTier = tierSource()
            let tier = playedTier(requestedTier)
            if case let .opened(loaded) = copy.retierAtStart(
                current: asset.url, tier: tier, displayPixels: displayPixelSize, isPreview: isPreview, open: loadBlocking)
            {
                traceLog("  [start #\(debugID)] tier \(tier) opens a different file than create")
                adopt(loaded)
            }
            send(.policy(playedTier(requestedTier, playing: asset.url), animated: false))
            // A preview on the original holds its seeded still rather than
            // decode the original's first frame for a small tile (#35). The
            // lifecycle builds a pipeline once a copy or tier lets it play.
            let holding = isPreview && copy.previewHoldsSeed(playing: asset.url, seedOf: seededOriginal)
            // Starts the clock and the feed once the pipeline reports built,
            // unless the displays sleep or a pause was applied before this ran.
            // The global flag is read here, on the queue: sleep sets it before
            // sending `displayDidSleep` to the renderers it knows, so a renderer
            // it missed still sees it.
            send(.started(displayAsleep: WallpaperState.shared.isDisplayAsleep, holding: holding))
            if holding {
                traceLog("  [start #\(debugID)] preview holds its still, no pipeline for \(asset.url.lastPathComponent)")
                onFirstFrameReady?()
                return
            }
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
            switch copy.switchTo(
                url, selector: variantSelector, current: asset.url, tier: tier, displayPixels: displayPixelSize, hold: hold,
                open: loadBlocking)
            {
            case .held:
                traceLog("  [switchVideo #\(debugID)] DEFERRED until wake or reopen: \(url.lastPathComponent)")
                return
            case let .opened(loaded):
                adopt(loaded)
                send(.assetChanged)
            case .unchanged:
                traceLog("  [switchVideo #\(debugID)] DEDUP: already on \(asset.url.lastPathComponent)")
            case .failed:
                extensionLog(
                    "  [switchVideo #\(debugID)] no playable file for \(url.lastPathComponent), keeping \(asset.url.lastPathComponent)")
            }
            applyTier(tier, animated: false)
        }
    }

    /// Load `url`'s video track, or nil when it has none. Queue-only; blocks.
    func loadBlocking(_ url: URL) -> (AVURLAsset, AVAssetTrack)? {
        let newAsset = AVURLAsset(url: url)
        guard let track = Self.loadFirstVideoTrackBlocking(newAsset) else {
            traceLog("  [Renderer #\(debugID)] no video track in \(url.lastPathComponent)")
            return nil
        }
        return (newAsset, track)
    }

    /// Make a loaded file the current asset; the next build restarts on it.
    func adopt(_ loaded: (AVURLAsset, AVAssetTrack)) {
        (asset, videoTrack) = loaded
        traceLog("  [Renderer #\(debugID)] now reading \(asset.url.lastPathComponent)")
    }

    /// Tag a sample buffer so the renderer displays it immediately, replacing all
    /// previously enqueued/displayed images regardless of timestamps (per
    /// AVQueuedSampleBufferRendering docs). Used for the first frame of a switched
    /// video so the swap is instant and doesn't wait on the control timebase.
    static func setDisplayImmediately(_ sample: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) else { return }
        let count = CFArrayGetCount(attachments)
        for i in 0..<count {
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
    static func loadFirstVideoTrackBlocking(_ asset: AVURLAsset) -> AVAssetTrack? {
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
}
