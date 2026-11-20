import AVFoundation
import CoreMedia
import os

extension VideoRenderer {
    /// Rebuilding kept failing: show the creation still, or the no-video
    /// gradient when there is none, rather than a frozen or cleared frame. The
    /// reset before this flushed the renderer, so it accepts the buffer.
    func showFallbackStill() {
        let still = fallbackStill(copy.activeOriginal)
        extensionLog(
            "  [Renderer #\(debugID)] gave up rebuilding \(LogRedaction.fileLabel(asset.url)) after \(RendererLifecycle.maxFailures) failures, showing \(still == nil ? "the gradient" : "the still")"
        )
        guard let image = still ?? Self.makeGradientStill(),
            let buffer = makeStillSampleBuffer(from: image)
        else { return }
        Self.setDisplayImmediately(buffer)
        renderer.enqueue(buffer)
    }

    /// The acquire path's no-video gradient as an image; the display layer
    /// scales it to fill.
    static func makeGradientStill() -> CGImage? {
        let side = 64
        guard
            let context = CGContext(
                data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue,
            ),
            let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [
                    CGColor(red: 0.2, green: 0.0, blue: 0.5, alpha: 1.0),
                    CGColor(red: 0.0, green: 0.3, blue: 0.7, alpha: 1.0),
                    CGColor(red: 0.0, green: 0.6, blue: 0.4, alpha: 1.0),
                ] as CFArray,
                locations: nil,
            )
        else { return nil }
        // Same start and end points as the CAGradientLayer, in the same
        // bottom-left-origin space.
        context.drawLinearGradient(
            gradient, start: .zero, end: CGPoint(x: side, y: side), options: [],
        )
        return context.makeImage()
    }

    func dropReaders() {
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
    func beginReset(_ kind: RendererLifecycle.ResetKind, generation: Int) {
        traceLog("  [reset #\(debugID)] BEGIN \(kind) gen=\(generation) asset=\(LogRedaction.fileLabel(asset.url))")
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
    func buildPipeline(_ kind: RendererLifecycle.ResetKind) -> Bool {
        let resumeTime = CMTimebaseGetTime(timebase)
        let continuing = kind == .resume && resumeTime.isNumeric && resumeTime > .zero
        // The timeline counts every loop; seek within the loop on screen and
        // keep its offset so the timeline stays continuous.
        let resumePoint = LoopTiming.resumePoint(timeline: resumeTime, loopStart: ptsOffset, previousLoopStart: previousPtsOffset)
        guard let reader = try? AVAssetReader(asset: asset) else {
            extensionLog("  [reset #\(debugID)] FAILED to create AVAssetReader for \(LogRedaction.fileLabel(asset.url))")
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
            extensionLog(
                "  [reset #\(debugID)] FAILED to start reading \(LogRedaction.fileLabel(asset.url)): \(reader.error.map(LogRedaction.describe) ?? "unknown")"
            )
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
        traceLog(
            "  [reset #\(debugID)] BUILT \(kind) continuing=\(continuing) asset=\(LogRedaction.fileLabel(asset.url)) rendererStatus=\(renderer.status.rawValue)"
        )
        feedLogBudget = 4
        prepareNextReader()
        return true
    }
}
