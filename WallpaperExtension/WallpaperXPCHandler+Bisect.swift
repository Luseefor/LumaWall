import AppKit
import AVFoundation
import CoreMedia
import os
import QuartzCore

extension WallpaperXPCHandler {
    /// Bisection acquire: identical CAContext reuse/create/reply as `acquireBody`, but
    /// hosts a still (via `bisectShowStill`) instead of a VideoRenderer. Runs on
    /// `Lifecycle.queue`. See StillBisect.swift.
    func acquireStillOnlyBisect(
        key: DisplayKey, displayID: UInt32?, destSize: CGSize, scaleFactor: CGFloat, videoURL: URL?, cachedStill: CGImage?, choice: String?,
        reply: @escaping @Sendable (Any?, (any Error)?) -> Void
    ) {
        if let existing = WallpaperState.shared.context(for: key) {
            traceLog(
                "  [bisect] REUSE ctx=\(existing.contextId) display=\(key.displayID) stored=\(existing.videoID ?? "nil") new=\(choice ?? "nil")"
            )
            guard let replyObj = createRemoteContextXPC(contextId: existing.contextId) else {
                reply(nil, NSError(domain: "LumaWallExtension", code: 3, userInfo: nil)); return
            }
            if existing.videoID == choice {
                traceLog("  [bisect] SAME choice → no re-seed")
                reply(replyObj, nil)
                return
            }
            // Reply once the still is in the layer: the agent shows a new
            // context's content the moment it hosts it.
            bisectShowStill(videoURL: videoURL, cachedStill: cachedStill, rootLayer: existing.rootLayer, for: key)
            WallpaperState.shared.updateVideoID(choice, for: key)
            reply(replyObj, nil)
            return
        }

        var contextOptions: [String: Any] = [:]
        if let did = displayID { contextOptions["displayId"] = did }
        let caContextRaw: Any? =
            contextOptions.isEmpty
            ? CAContext.remoteContext()
            : CAContext.perform(NSSelectorFromString("remoteContextWithOptions:"), with: contextOptions)?.takeUnretainedValue()
        guard let caContext = caContextRaw as? CAContext, caContext.contextId != 0 else {
            reply(
                nil,
                NSError(domain: "LumaWallExtension", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to create remote CAContext"]))
            return
        }
        let rootLayer = CALayer()
        rootLayer.frame = CGRect(origin: .zero, size: destSize)
        rootLayer.contentsScale = scaleFactor
        rootLayer.contentsGravity = .resizeAspectFill
        caContext.layer = rootLayer
        CATransaction.flush()
        guard let replyObj = createRemoteContextXPC(contextId: caContext.contextId) else {
            reply(nil, NSError(domain: "LumaWallExtension", code: 3, userInfo: nil)); return
        }
        WallpaperState.shared.installContext(
            ActiveWallpaper(
                caContext: caContext, contextId: caContext.contextId, rootLayer: rootLayer, renderer: nil, displayID: displayID,
                videoID: choice, isPreview: acquiredAsPreview, destSize: destSize, scaleFactor: scaleFactor),
            for: key,
        )
        // `bisectShowStill` decodes synchronously on `Lifecycle.queue`, where
        // teardown and every other acquire also run, so nothing can reuse or
        // remove this context before the reply below. That is why this path
        // needs no `ReplyGate`: replying after the call is the same guarantee.
        bisectShowStill(videoURL: videoURL, cachedStill: cachedStill, rootLayer: rootLayer, for: key)
        reply(replyObj, nil)
        traceLog("  [bisect] CREATED ctx=\(caContext.contextId) display=\(key.displayID) choice=\(choice ?? "nil")")
    }
}
