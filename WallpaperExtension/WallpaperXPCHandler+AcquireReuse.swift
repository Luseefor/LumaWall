import AppKit
import AVFoundation
import CoreMedia
import os
import QuartzCore

extension WallpaperXPCHandler {
    /// `acquireBody` for a surface whose context already exists: reply with
    /// it, and resize or switch the renderer the request calls for.
    /// Runs on `Lifecycle.queue`.
    func acquireReuse(_ existing: ActiveWallpaper, _ acquired: AcquiredRequest, reply: @escaping @Sendable (Any?, (any Error)?) -> Void) {
        let key = acquired.key, displayID = acquired.displayID, destSize = acquired.destSize, scaleFactor = acquired.scaleFactor
        let isPreview = acquired.isPreview, choiceConfiguration = acquired.choiceConfiguration, renderChoice = acquired.renderChoice,
            videoURL = acquired.videoURL
        let pixelWidth = acquired.pixelWidth, pixelHeight = acquired.pixelHeight, loadStill = acquired.loadStill
        traceLog(
            "  [acquire] REUSE ctx=\(existing.contextId) display=\(key.displayID) storedVideoID=\(existing.videoID ?? "nil") newChoice=\(choiceConfiguration ?? "nil") renderer=\(existing.renderer.map { "#\($0.debugID)" } ?? "nil") videoURL=\(findVideoURL(forChoice: choiceConfiguration).map(LogRedaction.fileLabel) ?? "nil") dest=\(destSize) @\(scaleFactor)x isPreview=\(isPreview) (surface isPreview=\(existing.isPreview))"
        )

        // A same-key acquire from the OTHER role (a Settings preview of the
        // current wallpaper reusing the live surface id, or an id-less
        // thumbnail probe collapsing onto the fallback key) must never
        // mutate the live surface: its small viewport would shrink the
        // desktop renderer to a stuck quarter-size rect over the
        // full-bleed still (and a different choice would flip the desktop
        // video to the previewed one). Reply with the context and leave
        // the surface alone. The requester still gets a live picture.
        guard isPreview == existing.isPreview else {
            guard let replyObj = createRemoteContextXPC(contextId: existing.contextId) else {
                reply(nil, NSError(domain: "LumaWallExtension", code: 3, userInfo: nil)); return
            }
            if Lifecycle.replies.hold(
                heldReply(SendableBox(value: replyObj), contextId: existing.contextId, key: key, reply: reply), for: key)
            {
                extensionLog(
                    "  [acquire] REUSE role mismatch while display \(key.displayID)'s renderer is being created → reply waits for its seed")
            } else {
                reply(replyObj, nil)
            }
            extensionLog(
                "  [acquire] REUSE role mismatch (surface isPreview=\(existing.isPreview), request isPreview=\(isPreview), dest=\(destSize)) → reply only, no resize/switch"
            )
            return
        }

        // Geometry may have changed since this surface was created. A bigger/smaller
        // display reconnected, or the same display switched resolution. The REUSE path
        // otherwise keeps the original frame, so the wallpaper renders into a sub-region
        // of the now-larger panel (issue #21). Re-frame the root + renderer layers to the
        // new destination before re-hosting. Unchanged geometry (the common wake/revisit
        // re-acquire) returns nil and skips the relayout.
        if let resized = WallpaperState.shared.updateGeometryIfChanged(destSize: destSize, scaleFactor: scaleFactor, for: key) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            resized.rootLayer.frame = CGRect(origin: .zero, size: destSize)
            resized.rootLayer.contentsScale = scaleFactor
            reframeGradientFallback(on: resized.rootLayer)
            CATransaction.commit()
            CATransaction.flush()
            resized.renderer?.resize(to: destSize, scale: scaleFactor)
            extensionLog(
                "  [acquire] REUSE geometry changed (same role) → resized surface on display \(key.displayID) to \(destSize) @\(scaleFactor)x"
            )
        }

        guard let replyObj = createRemoteContextXPC(contextId: existing.contextId) else {
            reply(nil, NSError(domain: "LumaWallExtension", code: 3, userInfo: nil)); return
        }
        if Lifecycle.replies.hold(heldReply(SendableBox(value: replyObj), contextId: existing.contextId, key: key, reply: reply), for: key)
        {
            extensionLog("  [acquire] REUSE while display \(key.displayID)'s renderer is being created → reply waits for its seed")
        } else {
            reply(replyObj, nil)
        }

        if ColorDiag.enabled { colorDiagInstall(rootLayer: existing.rootLayer, for: key); return }

        if existing.videoID == choiceConfiguration, existing.renderer != nil {
            traceLog("  [acquire] SAME choice (\(choiceConfiguration ?? "nil")) + renderer present → no swap")
            return
        }
        guard let videoURL else {
            traceLog("  [acquire] no video for new choice, keeping current")
            return
        }
        extensionLog(
            "  [acquire] switching to \(LogRedaction.fileLabel(videoURL)) (renderer \(existing.renderer != nil ? "present → switchVideo" : "nil → create"))"
        )
        let selector = makeVariantSelector(choice: renderChoice, fallback: videoURL)
        if let renderer = existing.renderer {
            // Switch the video IN PLACE on the already-hosted display layer.
            // Building a fresh renderer here (new AVSampleBufferDisplayLayer) is
            // what broke switching. A layer added to an already-hosted context
            // doesn't composite. Reuse the existing layer instead.
            renderer.switchVideo(to: videoURL, variantSelector: selector)
            WallpaperState.shared.updateVideoID(choiceConfiguration, for: key)
            WallpaperPrefs.shared.setActive(true)
        } else if let token = WallpaperState.shared.claimRendererCreate(for: key) {
            // Context exists but no renderer yet AND no create already in flight,
            // attach one to the existing root layer. The claim prevents a racing
            // (preview) acquire from creating a duplicate renderer on the same layer.
            let boxedRoot = SendableBox(value: existing.rootLayer)
            Task { [boxedRoot, videoURL, loadStill, selector, key, token, choiceConfiguration, displayID, isPreview] in
                // create() replaces the no-video gradient this surface
                // shows, and the agent already hosts it: seed it even on a
                // cache miss so the layer never goes empty.
                // A preview holding the original decodes nothing.
                let renderer: VideoRenderer
                do {
                    renderer = try await VideoRenderer.create(
                        rootLayer: boxedRoot.value, videoURL: videoURL,
                        seed: { holds in await seedStill(cached: loadStill(videoURL), videoURL: videoURL, decode: !holds) },
                        fallbackStill: { loadCachedStill(ofVideo: $0, pixelWidth: pixelWidth, pixelHeight: pixelHeight) },
                        variantSelector: selector,
                        tierSource: { LumaWallExtension.policyForRenderer(displayID: displayID, isPreview: isPreview) },
                        isPreview: isPreview,
                    )
                } catch {
                    extensionLog("  [Renderer] swap create failed: \(LogRedaction.describe(error))")
                    WallpaperState.shared.clearRendererPending(for: key, token: token)
                    return
                }
                if !renderer.seededStill { installGradientFallback(on: boxedRoot.value) }
                guard
                    case let .installed(old) = WallpaperState.shared.installRenderer(
                        renderer, token: token, videoID: choiceConfiguration, for: key)
                else {
                    renderer.stop()
                    return
                }
                old?.stop()
                WallpaperPrefs.shared.setActive(true)
                renderer.start()
                // A fresh renderer starts playing; the pause conditions written
                // before this process launched (fullscreen app, occlusion,
                // per-display pause) arrive by prefs reload, not notification,
                // so apply them now rather than waiting for the next change.
                LumaWallExtension.recomputeAndApplyPolicy()
            }
        } else {
            traceLog("  [acquire] renderer create already in flight for display \(key.displayID), skipping duplicate")
        }
        Task { [videoURL, choiceConfiguration, pixelWidth, pixelHeight] in
            await writeBMPSnapshot(
                videoURL: videoURL, videoID: choiceConfiguration, displayPixelWidth: pixelWidth, displayPixelHeight: pixelHeight)
        }
        return
    }
}
