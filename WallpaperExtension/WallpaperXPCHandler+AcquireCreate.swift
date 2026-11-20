import AppKit
import AVFoundation
import CoreMedia
import os
import QuartzCore

/// What a new renderer's display layer is seeded with: the cached still,
/// else the video's decoded first frame (unless `decode` is false), else the
/// gradient, so the layer shows something before the first video frame.
/// `isStill`: the image is a frame of the video, not the gradient.
func seedStill(cached: CGImage?, videoURL: URL, decode: Bool = true) async -> (image: CGImage?, source: String, isStill: Bool) {
    if let cached { return (cached, "the cached still", true) }
    if decode, let frame = await firstFrameImage(of: videoURL) { return (frame, "the decoded first frame", true) }
    if let gradient = VideoRenderer.makeGradientStill() { return (gradient, "the gradient", false) }
    return (nil, "nothing", false)
}

extension WallpaperXPCHandler {
    /// `acquireBody` for a surface with no context yet: make one and its
    /// renderer, replying once the layer shows something. Runs on
    /// `Lifecycle.queue`.
    func acquireCreate(_ acquired: AcquiredRequest, reply: @escaping @Sendable (Any?, (any Error)?) -> Void) {
        let key = acquired.key, displayID = acquired.displayID, displayID0 = acquired.displayID0, destSize = acquired.destSize
        let scaleFactor = acquired.scaleFactor, isPreview = acquired.isPreview, choiceConfiguration = acquired.choiceConfiguration,
            renderChoice = acquired.renderChoice
        let videoURL = acquired.videoURL, pixelWidth = acquired.pixelWidth, pixelHeight = acquired.pixelHeight,
            loadStill = acquired.loadStill
        var contextOptions: [String: Any] = [:]
        if let did = displayID { contextOptions["displayId"] = did }
        let caContextRaw: Any? =
            contextOptions.isEmpty
            ? CAContext.remoteContext()
            : CAContext.perform(NSSelectorFromString("remoteContextWithOptions:"), with: contextOptions)?.takeUnretainedValue()
        guard let caContext = caContextRaw as? CAContext, caContext.contextId != 0 else {
            extensionLog("  ERROR: remote CAContext creation failed, failing acquire")
            reply(
                nil,
                NSError(domain: "LumaWallExtension", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to create remote CAContext"]))
            return
        }
        let contextId = caContext.contextId

        // Only a surface that gets a renderer needs the still; the renderer
        // takes it as its IOSurface seed, and the root layer holds it until then.
        let cachedStill = ColorDiag.enabled ? nil : videoURL.flatMap(loadStill)
        let layerFrame = CGRect(origin: .zero, size: destSize)
        let rootLayer = CALayer()
        rootLayer.frame = layerFrame
        rootLayer.contentsScale = scaleFactor
        rootLayer.contentsGravity = .resizeAspectFill
        if let cachedStill { rootLayer.contents = cachedStill }
        caContext.layer = rootLayer
        CATransaction.flush()

        guard let replyObj = createRemoteContextXPC(contextId: contextId) else {
            reply(nil, NSError(domain: "LumaWallExtension", code: 3, userInfo: nil)); return
        }

        // Install the persistent slot now (renderer added async) so a concurrent
        // acquire for the same display reuses this context instead of creating another.
        WallpaperState.shared.installContext(
            ActiveWallpaper(
                caContext: caContext, contextId: contextId, rootLayer: rootLayer, renderer: nil, displayID: displayID,
                videoID: choiceConfiguration, isPreview: isPreview, destSize: destSize, scaleFactor: scaleFactor,
                slot: SurfaceSlot(acquiredBy: connectionSerial, ownerIsPreview: isPreview)),
            for: key,
        )
        extensionLog("  Created context \(contextId) for display \(key.displayID)")

        // NB: the XPC reply is DEFERRED until the new context is actually displaying
        // video (in the render Task below). WallpaperAgent hosts a context only after it
        // receives this reply, and keeps compositing the OLD wallpaper's context until
        // then. Replying immediately (as before) made the agent swap to a not-yet-
        // rendering context, the blink / still-flash / zoom on every switch. Gating the
        // reply on the first composited frame makes the host swap land directly on live
        // video, matching Apple's own extensions (which likewise don't reply until ready).
        // Every branch below still replies exactly once so the acquire can never hang.

        if ColorDiag.enabled { colorDiagInstall(rootLayer: rootLayer, for: key); reply(replyObj, nil); return }

        guard let videoURL else {
            // No video file, so solid gradient fallback. Static content, so it's ready as
            // soon as it's installed; reply immediately.
            installGradientFallback(on: rootLayer)
            reply(replyObj, nil)
            extensionLog("  No video file found, solid color fallback")
            return
        }

        // Cold start = no existing LumaWall surface on this display for the SAME surface
        // role (preview vs. live desktop) that the agent could keep compositing during the
        // swap. Unlike a switch (where the outgoing context is OURS and stays hosted, via
        // the teardown grace, until we reply), here the agent has nothing of ours to hold
        // in THIS role's CALayerHost, the instant it hosts our context it shows whatever
        // the context contains. `rootLayer.contents` is BLACK cross-process (only IOSurface-
        // backed AVSampleBufferDisplayLayer content composites remotely, see
        // Research/wallpaper-extension-issue13-and-rendering-findings.md), so replying
        // before the renderer exists paints black. Instead, on a cold start we reply the
        // instant VideoRenderer.create() has seeded + flushed the IOSurface still into the
        // display layer: the agent then hosts a context already showing the still, and the
        // video plays over it in place. A switch keeps deferring until the first video frame.
        //
        // Filtering by `isPreview` is what fixes the WallpaperAgent-restart ordering bug:
        // a preview-first / desktop-second boot must NOT let the preview renderer trip this
        // check for the incoming desktop acquire, because the desktop CALayerHost has never
        // hosted anything of ours, deferring there paints black.
        let coldStart = !WallpaperState.shared.hasLiveRenderer(onDisplay: displayID0, isPreview: isPreview)

        // Claim the single create slot for this display. If a racing (preview)
        // acquire beat us to it, skip, exactly one renderer per display.
        if let token = WallpaperState.shared.claimRendererCreate(for: key) {
            traceLog("  Setting up VideoRenderer with: \(videoURL.lastPathComponent) (coldStart=\(coldStart))")
            let boxedRoot = SendableBox(value: rootLayer)
            let selector = makeVariantSelector(choice: renderChoice, fallback: videoURL)
            // The reply waits in the gate, with those of acquires that reuse
            // this surface meanwhile, until surfaceReady for this token.
            let displaced = Lifecycle.replies.open(
                key, token: token, reply: heldReply(SendableBox(value: replyObj), contextId: contextId, key: key, reply: reply))
            displaced.forEach { $0() }
            Task {
                [
                    coldStart, boxedRoot, videoURL, cachedStill, selector, key, token, choiceConfiguration, displayID, isPreview,
                    pixelWidth, pixelHeight
                ] in
                // A cold start replies once create() has seeded the display
                // layer, so a cache miss seeds the decoded first frame, or the
                // gradient, rather than leaving the layer empty. A preview that
                // will hold the original shows its seed and decodes nothing.
                let renderer: VideoRenderer
                do {
                    renderer = try await VideoRenderer.create(
                        rootLayer: boxedRoot.value, videoURL: videoURL,
                        seed: { holds in
                            coldStart || holds
                                ? await seedStill(cached: cachedStill, videoURL: videoURL, decode: !holds)
                                : (cachedStill, cachedStill == nil ? "nothing" : "the cached still", cachedStill != nil)
                        },
                        fallbackStill: { loadCachedStill(ofVideo: $0, pixelWidth: pixelWidth, pixelHeight: pixelHeight) },
                        variantSelector: selector,
                        tierSource: { LumaWallExtension.policyForRenderer(displayID: displayID, isPreview: isPreview) },
                        isPreview: isPreview,
                    )
                } catch {
                    extensionLog("  [Renderer] Failed to create: \(error); seeded the gradient layer")
                    WallpaperState.shared.clearRendererPending(for: key, token: token)
                    // Unblock the acquire regardless, with something displayable.
                    installGradientFallback(on: boxedRoot.value)
                    surfaceReady(key, token: token)
                    return
                }
                guard
                    case let .installed(old) = WallpaperState.shared.installRenderer(
                        renderer, token: token, videoID: choiceConfiguration, for: key)
                else {
                    // The context was torn down while the renderer loaded, and
                    // teardown failed its replies. A create under the same key
                    // since then holds its own; this token releases none of them.
                    renderer.stop()
                    surfaceReady(key, token: token)
                    return
                }
                // Cold start: the IOSurface still is now seeded + flushed into the display
                // layer, so reply. The agent hosts our context already showing the still
                // (no black gap), and video plays over it.
                if coldStart {
                    var seeded = renderer.seedSource
                    if !renderer.seededStill {
                        installGradientFallback(on: boxedRoot.value)
                        seeded = "the gradient layer (\(seeded) didn't reach the display layer)"
                    }
                    surfaceReady(key, token: token)
                    traceLog("  [acquire] cold start → replied after seeding \(seeded) for \(videoURL.lastPathComponent)")
                }
                WallpaperPrefs.shared.setActive(true)
                // Switch: reply only once the first video frame is composited (cold start
                // already replied with the still). Either way, stop the old renderer once
                // we've told the agent to swap off it.
                let heldStill = cachedStill != nil
                renderer.start(onFirstFrameReady: {
                    if !coldStart {
                        // A cache miss seeds nothing here, and start() calls
                        // back without a frame when the reader fails: show the
                        // gradient rather than reply with an empty layer.
                        if !renderer.seededStill, !renderer.showedFirstFrame { installGradientFallback(on: boxedRoot.value) }
                        surfaceReady(key, token: token)
                    }
                    old?.stop()
                    // Video (or, on failure, the seeded still) is in the display
                    // layer now; the root layer's copy is only memory (a 4K frame
                    // is 33 MB decoded).
                    if heldStill {
                        CATransaction.begin()
                        CATransaction.setDisableActions(true)
                        boxedRoot.value.contents = nil
                        CATransaction.commit()
                    }
                    // After the reply so a pre-first-frame pause can't stall the
                    // acquire: apply pause conditions that predate this process
                    // (fullscreen app, occlusion, per-display pause), which arrive
                    // by prefs reload rather than a change notification.
                    LumaWallExtension.recomputeAndApplyPolicy()
                })
            }
        } else {
            traceLog("  [acquire] renderer create already in flight for display \(key.displayID), skipping duplicate (create path)")
            reply(replyObj, nil)
        }
        Task { [pixelWidth, pixelHeight] in
            await writeBMPSnapshot(
                videoURL: videoURL, videoID: choiceConfiguration, displayPixelWidth: pixelWidth, displayPixelHeight: pixelHeight)
        }
    }
}
