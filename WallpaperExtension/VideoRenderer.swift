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
        let imp = class_getMethodImplementation(type(of: layer), sel)
    else { return }
    typealias SetBoolFn = @convention(c) (AnyObject, Selector, ObjCBool) -> Void
    unsafeBitCast(imp, to: SetBoolFn.self)(layer, sel, ObjCBool(flag))
}

final class VideoRenderer: @unchecked Sendable {
    /// Process-wide instance counter so log lines can be attributed to a specific
    /// renderer object (to catch stale/duplicate renderers from acquire races).
    private static let idCounter = OSAllocatedUnfairLock(initialState: 0)
    let debugID: Int = VideoRenderer.idCounter.withLock {
        $0 += 1; return $0
    }

    let displayLayer: AVSampleBufferDisplayLayer
    /// The display's size in pixels, so Full Quality can pick a copy that
    /// fills it without decoding more than it can show. Updated by `resize`
    /// (Lifecycle queue) and read on the renderer queue, so lock-backed.
    var displayPixelSize: CGSize { pixelSize.withLock { $0 } }
    let pixelSize: OSAllocatedUnfairLock<CGSize>
    let timebase: CMTimebase
    let renderer: AVSampleBufferVideoRenderer
    let stillFrameLayer: CALayer
    var asset: AVURLAsset
    var videoTrack: AVAssetTrack
    let queue = DispatchQueue(label: "video-renderer", qos: .userInitiated)
    var isRunning = true
    /// Every playback decision for this renderer: clock, feed, deep pause,
    /// resets, and the display-sleep gate. Touched only on `queue`; see
    /// `RendererLifecycle`. Public entry points hop to `queue` and send events.
    var lifecycle: RendererLifecycle
    /// Events raised while effects run (an instant ramp completion) wait here
    /// so each event's effects run against the state that produced them.
    var pendingEvents: [RendererLifecycle.Event] = []
    var isDispatching = false
    /// What the status file needs from this renderer: written on the queue
    /// by `send`, read from any thread.
    struct StatusInfo: Equatable {
        var displayAsleep: Bool
        var surfaceOpen: Bool
        var filename: String
    }
    let statusInfo = OSAllocatedUnfairLock<StatusInfo?>(initialState: nil)
    /// What `PowerMonitor` last heard about this renderer being active.
    var reportedPlayback = false
    var rampTimer: (any DispatchSourceTimer)?
    /// The battery flag of the latest policy, for ramp lengths. Queue-only.
    var rampOnBattery = false
    var deepPauseTimer: (any DispatchSourceTimer)?
    var retryTimer: (any DispatchSourceTimer)?

    var currentReader: AVAssetReader?
    var currentOutput: AVAssetReaderTrackOutput?
    var nextReader: AVAssetReader?
    var nextOutput: AVAssetReaderTrackOutput?

    /// Diagnostic: number of remaining feed-loop ticks to log after a restart.
    var feedLogBudget = 0

    // Gapless looping state.
    // ptsOffset accumulates across loops so both DTS and PTS are monotonically increasing.
    // lastEnqueuedEnd tracks the highest sample end time (max, not last, handles B-frames).
    var ptsOffset: CMTime = .zero
    /// The loop before `ptsOffset`'s, whose tail may still be on screen.
    var previousPtsOffset: CMTime = .zero
    var lastEnqueuedEnd: CMTime = .zero
    var nominalFrameRate: Double = 60

    /// Which file to open on a switch, tier change, wake, and loop: the
    /// variant selector and a switch held through sleep. Queue-only, like
    /// `lifecycle`.
    var copy: RendererCopy
    /// The tier `applyPolicies` would give this renderer now. Read on the
    /// queue when a switch or the first frame picks a copy, so a recompute
    /// still on its way can't make it open the wrong one.
    let tierSource: @Sendable () -> PlaybackPolicy
    /// A Settings preview: it holds one frame at a tier no copy serves,
    /// rather than decode the original for a small tile. Cleared for good
    /// when a live request is handed this surface. Queue-only.
    var isPreview: Bool
    /// The tier last asked of this renderer; `lifecycle.policy` is what it
    /// plays, which differs on a preview holding a frame. Queue-only.
    var requestedTier: PlaybackPolicy
    /// Loads the still of the given original shown when the video can't be
    /// rebuilt. Called only then, with the original being played (switches,
    /// including ones held until wake or reopen, move it), so a playing
    /// renderer doesn't hold a decoded frame; nil shows the gradient.
    let fallbackStill: @Sendable (URL) -> CGImage?
    /// Whether init enqueued a still into the display layer. Set once there.
    private(set) var seededStill = false
    /// What init was given to seed, for the acquire's log. Set once there.
    let seedSource: String
    /// The original whose still init seeded, or nil. Set once there.
    var seededOriginal: URL?
    /// The seed is a frame of that original, not the gradient. Set once in init.
    var seedIsOfVideo = false
    /// Whether `start()` enqueued the first video frame. Set on the queue
    /// before `onFirstFrameReady` runs.
    var showedFirstFrame = false

    /// What init enqueues into the display layer before the first frame.
    /// `source` names it for the log; `isStill`: a frame of the video, not
    /// the gradient.
    typealias Seed = (image: CGImage?, source: String, isStill: Bool)

    /// Opens the copy `variantSelector` picks for the root layer's pixel size
    /// and the tier from `tierSource`, falling back to `videoURL` when that
    /// copy has no video track, so the first frame is decoded from the file
    /// the renderer plays. `seed` runs once that file is open, told whether
    /// the preview holds it (see `RendererCopy.openingSeeded`), so the hold
    /// and the file come from one tier read.
    static func create(
        rootLayer: CALayer,
        videoURL: URL,
        seed: (_ holdsOriginal: Bool) async -> Seed,
        fallbackStill: @escaping @Sendable (URL) -> CGImage? = { _ in nil },
        variantSelector: @escaping RendererCopy.Selector,
        tierSource: @escaping @Sendable () -> PlaybackPolicy,
        isPreview: Bool = false,
    ) async throws -> VideoRenderer {
        let pixels = CGSize(
            width: rootLayer.bounds.width * rootLayer.contentsScale,
            height: rootLayer.bounds.height * rootLayer.contentsScale
        )
        let policy = tierSource()
        let opened = await RendererCopy.openingSeeded(
            videoURL, selector: variantSelector, tier: policy, displayPixels: pixels, isPreview: isPreview
        ) { (url: URL) async -> (AVURLAsset, AVAssetTrack)? in
            let asset = AVURLAsset(url: url)
            guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
                traceLog("  [Renderer] no video track in \(LogRedaction.fileLabel(url))")
                return nil
            }
            return (asset, track)
        } seed: {
            await seed($0)
        }
        guard let ((asset, track), seeded) = opened else {
            throw CocoaError(
                .fileReadCorruptFile,
                userInfo: [
                    NSLocalizedDescriptionKey: "No video track found in \(videoURL.lastPathComponent)"
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
            seed: seeded,
            fallbackStill: fallbackStill,
            nominalFrameRate: nominalFrameRate,
            originalURL: videoURL,
            variantSelector: variantSelector,
            tierSource: tierSource,
            isPreview: isPreview,
            policy: policy,
        )
    }

    private init(
        rootLayer: CALayer,
        displayLayer: AVSampleBufferDisplayLayer,
        asset: AVURLAsset,
        videoTrack: AVAssetTrack,
        seed: Seed,
        fallbackStill: @escaping @Sendable (URL) -> CGImage?,
        nominalFrameRate: Double,
        originalURL: URL,
        variantSelector: @escaping RendererCopy.Selector,
        tierSource: @escaping @Sendable () -> PlaybackPolicy,
        isPreview: Bool,
        policy: PlaybackPolicy,
    ) {
        self.displayLayer = displayLayer
        self.copy = RendererCopy(original: originalURL, selector: variantSelector)
        self.tierSource = tierSource
        self.isPreview = isPreview
        self.requestedTier = policy
        self.lifecycle = RendererLifecycle(policy: policy)
        self.pixelSize = OSAllocatedUnfairLock(
            initialState: CGSize(
                width: rootLayer.bounds.width * rootLayer.contentsScale,
                height: rootLayer.bounds.height * rootLayer.contentsScale
            ))
        self.renderer = LWSampleBufferRenderer(displayLayer)
        self.asset = asset
        self.videoTrack = videoTrack
        self.fallbackStill = fallbackStill
        self.seedSource = seed.source
        let stillImage = seed.image
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
        traceLog(
            "  [Renderer #\(debugID)] CREATED for \(LogRedaction.fileLabel(asset.url)) tier=\(policy), displayLayer=\(ObjectIdentifier(displayLayer)), rootLayer sublayers=\((rootLayer.sublayers?.count ?? 0)), pixels=\(Int(displayPixelSize.width))x\(Int(displayPixelSize.height))"
        )
        if let stillImage, let stillBuffer = makeStillSampleBuffer(from: stillImage) {
            // Tag DisplayImmediately so the still is shown the instant it's enqueued,
            // rather than waiting on the control timebase (which is frozen at rate 0 here).
            // Without this the frame can sit undisplayed → the layer reads empty → black.
            Self.setDisplayImmediately(stillBuffer)
            renderer.enqueue(stillBuffer)
            seededStill = true
            seededOriginal = originalURL
            seedIsOfVideo = seed.isStill
            traceLog("  [Renderer #\(debugID)] Seeded still into display layer (\(stillImage.width)x\(stillImage.height))")
        } else {
            traceLog(
                "  [Renderer #\(debugID)] Seeded nothing (stillImage present: \(stillImage != nil)); the display layer is empty until the first frame"
            )
        }
        CATransaction.commit()
        // flush() (not just commit()) is what pushes the layer tree to the render
        // server for a REMOTE context, without it the still never reaches the
        // WindowServer and the desktop stays black until a later flush.
        CATransaction.flush()
    }
}
