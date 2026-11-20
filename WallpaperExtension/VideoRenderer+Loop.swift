import AVFoundation
import CoreMedia
import os

extension VideoRenderer {
    // MARK: - Preloaded Loop Reader

    func prepareNextReader() {
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
                    traceLog("  [Renderer] No video track in variant: \(LogRedaction.fileLabel(nextURL))")
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
        guard let (reader, output) = makeReader(asset: asset, track: track) else {
            traceLog("  [Renderer] Failed to create next reader")
            return
        }
        nextReader = reader
        nextOutput = output
    }

    private func makeReader(asset: AVURLAsset, track: AVAssetTrack) -> (AVAssetReader, AVAssetReaderTrackOutput)? {
        guard let reader = try? AVAssetReader(asset: asset) else { return nil }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        return (reader, output)
    }

    /// A reader for one loop that has started reading.
    private struct LoopReader {
        let reader: AVAssetReader
        let output: AVAssetReaderTrackOutput
        let asset: AVURLAsset
    }

    private func startedLoopReader(_ built: (AVAssetReader, AVAssetReaderTrackOutput)?, asset: AVURLAsset, label: String) -> LoopReader? {
        guard let (reader, output) = built else {
            traceLog("  [Renderer] Failed to create \(label) reader for \(LogRedaction.fileLabel(asset.url))")
            return nil
        }
        guard reader.startReading() else {
            traceLog(
                "  [Renderer] \(label) reader for \(LogRedaction.fileLabel(asset.url)) won't start: \(reader.error.map(LogRedaction.describe) ?? "unknown")"
            )
            return nil
        }
        return LoopReader(reader: reader, output: output, asset: asset)
    }

    /// Swap to the preloaded next reader at a loop boundary.
    /// Uses timing offset for gapless continuation, no flush, no timebase reset.
    /// The lifecycle runs it only while feeding is allowed and starts the feed
    /// after it.
    func swapToNextReader() {
        // Advance offset so the next loop's DTS/PTS continue the timeline.
        previousPtsOffset = ptsOffset
        ptsOffset = lastEnqueuedEnd

        let preload = nextReader.flatMap { reader in nextOutput.map { (reader, $0) } }
        nextReader = nil
        nextOutput = nil
        let preloadAsset = preload?.0.asset as? AVURLAsset
        // The preload may predate a tier change; read the tier's copy from
        // this loop on, but keep the preload until that copy starts.
        let picked = copy.loopReader(
            preloaded: preloadAsset?.url, current: asset.url, tier: lifecycle.policy, displayPixels: displayPixelSize
        ) { source -> LoopReader? in
            switch source {
            case let .replacement(url):
                guard let (newAsset, track) = loadBlocking(url) else { return nil }
                return startedLoopReader(makeReader(asset: newAsset, track: track), asset: newAsset, label: "replacement")
            case .preload:
                guard let preload, let preloadAsset else { return nil }
                return startedLoopReader(preload, asset: preloadAsset, label: "preloaded")
            case .current:
                traceLog("  [Renderer] No usable next reader, creating one synchronously")
                return startedLoopReader(makeReader(asset: asset, track: videoTrack), asset: asset, label: "fallback")
            }
        }
        if picked?.source != .preload { preload?.0.cancelReading() }
        if case let .replacement(url) = picked?.source {
            traceLog(
                "  [Renderer] preload \(preloadAsset.map { LogRedaction.fileLabel($0.url) } ?? "none") is for an older tier, looping into \(LogRedaction.fileLabel(url))"
            )
        }
        if let next = picked?.reader {
            if next.asset.url != asset.url {
                asset = next.asset
                videoTrack = next.output.track
                traceLog("  [Renderer] Switched variant: \(LogRedaction.fileLabel(next.asset.url))")
            }
            currentReader = next.reader
            currentOutput = next.output
            // A preview whose copy went away may loop into the original:
            // hold its frame instead.
            if isPreview { applyTier(requestedTier, animated: false) }
        } else {
            // The feed reports the missing reader as a failure.
            currentReader = nil
            currentOutput = nil
        }

        prepareNextReader()
    }

    // MARK: - Playback Loop

    /// Feed the renderer from the current reader under registration `token`.
    /// Stopping the feed retires the token, so a readiness callback already
    /// queued when the feed stopped (display sleep, a reset) returns without
    /// touching AVFoundation, and the events it would raise are dropped.
    func feedFromCurrentReader(token: Int) {
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
                extensionLog(
                    "  [feed #\(debugID)] \(fault) status=\(renderer.status.rawValue) err=\(renderer.error.map(LogRedaction.describe) ?? "-")"
                )
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
                        traceLog(
                            "  [feed #\(debugID)] reader out of samples after \(enqueuedThisTick) this tick; readerStatus=\(currentReader.status.rawValue) err=\(currentReader.error.map(LogRedaction.describe) ?? "-")"
                        )
                    }
                    report(event)
                    return
                }
            }
            if feedLogBudget > 0 {
                feedLogBudget -= 1
                traceLog(
                    "  [feed #\(debugID)] tick enqueued=\(enqueuedThisTick) status=\(renderer.status.rawValue) requiresFlush=\(renderer.requiresFlushToResumeDecoding) ready=\(renderer.isReadyForMoreMediaData) timebase=\(CMTimebaseGetTime(timebase).seconds)"
                )
            }
        }
    }

    func estimatedSampleEnd(pts: CMTime, duration: CMTime) -> CMTime {
        if duration.isValid, duration > .zero {
            return CMTimeAdd(pts, duration)
        }
        return CMTimeAdd(pts, fallbackFrameDuration())
    }

    private func fallbackFrameDuration() -> CMTime {
        // The rate comes from the file; a NaN or infinite one would trap Int(_:).
        let fps = nominalFrameRate.isFinite ? min(max(nominalFrameRate, 1), 1_200) : 60
        let timescale = CMTimeScale(Int((fps * 100).rounded()))
        return CMTime(value: 100, timescale: timescale)
    }

    /// Offset both DTS and PTS of a sample for gapless looping.
    /// Returns the original sample unchanged for the first loop (no copy needed).
    /// For subsequent loops, creates a lightweight copy with adjusted timing
    /// (shares the underlying data buffer, and only the timing metadata differs).
    func offsetTimingForLoop(_ sample: CMSampleBuffer) -> CMSampleBuffer {
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
