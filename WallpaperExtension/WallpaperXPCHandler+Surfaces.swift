import AppKit
import AVFoundation
import CoreMedia
import os
import QuartzCore

/// Fail the replies waiting on `key`'s context, which was just removed.
/// MUST be called on `Lifecycle.queue`.
func failHeldReplies(for key: DisplayKey) {
    Lifecycle.replies.close(key).forEach { $0() }
}

/// Arm (or re-arm) the teardown timer for a display whose live wallpaper was invalidated.
/// MUST be called on `Lifecycle.queue`.
private func scheduleTeardown(for key: DisplayKey) {
    Lifecycle.teardownTimers[key]?.cancel()
    let item = DispatchWorkItem {
        Lifecycle.teardownTimers[key] = nil
        let torn = WallpaperState.shared.tearDownContext(for: key)
        // A surface kept open still has its context; its waiters go out with
        // its create's reply. Fail them only once the context is gone.
        if WallpaperState.shared.context(for: key) == nil { failHeldReplies(for: key) }
        extensionLog("  [teardown] grace fired for display \(key.displayID) → \(torn ? "stopped renderer + invalidated CAContext" : "nothing to tear down, or still open after an ambiguous invalidate")")
        ShuffleController.shared.syncActiveWithContexts()
    }
    Lifecycle.teardownTimers[key] = item
    Lifecycle.queue.asyncAfter(deadline: .now() + Lifecycle.teardownGrace, execute: item)
}

/// A connection closed: close the surfaces it left with no host and arm
/// their teardown, as their last host's invalidate would have.
func closeSurfacesLeftUnhosted() {
    Lifecycle.queue.async {
        for key in WallpaperState.shared.closeUnhostedSurfaces() {
            scheduleTeardown(for: key)
            extensionLog("  [teardown] last host of display \(key.displayID)'s surface quit without an invalidate, closed it and armed its teardown")
        }
    }
}

/// Cancel a display's pending teardown because it was re-acquired (woke / switched).
/// MUST be called on `Lifecycle.queue`.
func cancelTeardown(for key: DisplayKey) {
    if let item = Lifecycle.teardownTimers.removeValue(forKey: key) {
        item.cancel()
        extensionLog("  [teardown] cancelled pending teardown for display \(key.displayID) (re-acquired)")
    }
}

extension WallpaperXPCHandler {
    // MARK: - Lifecycle

    /// Stable per-display surface UUID for the rare acquire that carries no WallpaperID, so
    /// such acquires still collapse to one context per display (old behavior) instead of
    /// minting a fresh context each time. Encodes the displayID into a fixed UUID layout.
    static func fallbackSurfaceUUID(forDisplay displayID: UInt32) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", displayID))
            ?? UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    }

    /// Fraction of the live display area below which a non-preview surface
    /// counts as shrunken (stuck transitional/poisoned geometry) rather than a
    /// legitimate size. Desktop/lock/Idle surfaces always cover their display;
    /// legitimate desktop acquires match it exactly (verified in the field).
    private static let shrunkenSurfaceFraction: CGFloat = 0.75

    /// Live display geometry in points (rotation-aware via CGDisplayBounds)
    /// plus the backing scale derived from hardware pixels, or nil when the
    /// display can't be resolved (offline, mid-handshake mirroring).
    static func liveDisplayGeometry(displayID: UInt32) -> (size: CGSize, scale: CGFloat)? {
        let live = CGDisplayBounds(displayID)
        guard live.width > 0, live.height > 0 else { return nil }
        let pxW = CGFloat(CGDisplayPixelsWide(displayID)), pxH = CGFloat(CGDisplayPixelsHigh(displayID))
        var scale: CGFloat = 1
        if pxW > 0, pxH > 0 {
            let landscapeLive = live.width >= live.height
            let pw = landscapeLive ? max(pxW, pxH) : min(pxW, pxH)
            let ph = landscapeLive ? min(pxW, pxH) : max(pxW, pxH)
            let derived = ((pw / live.width) + (ph / live.height)) / 2
            if derived > 0, derived.isFinite { scale = derived }
        }
        return (CGSize(width: live.width, height: live.height), scale)
    }

    /// Clamp a non-preview acquire viewport to the live display geometry when it
    /// is far smaller than the display. Desktop/lock/Idle surfaces always cover
    /// their display, so a much smaller request is a stale probe or a
    /// thumbnail-size acquire on a reused key, serving it as-is would mint a
    /// stuck half-scale surface the agent hosts small over the full-bleed
    /// still. Returns the input unchanged for previews, unknown/offline
    /// displays, and sizes within tolerance (covers rounding and transient
    /// mode-change differences).
    static func validatedGeometry(
        destSize: CGSize, scaleFactor: CGFloat,
        displayID: UInt32?, isPreview: Bool
    ) -> (CGSize, CGFloat) {
        guard !isPreview,
              let did = displayID,
              destSize.width > 0, destSize.height > 0,
              let live = liveDisplayGeometry(displayID: did)
        else { return (destSize, scaleFactor) }
        let liveArea = live.size.width * live.size.height
        let reqArea = destSize.width * destSize.height
        guard reqArea < liveArea * shrunkenSurfaceFraction else { return (destSize, scaleFactor) }
        extensionLog("  [acquire] viewport \(destSize) @\(scaleFactor)x far below live display \(live.size) → clamping to live geometry @\(live.scale)x")
        return (live.size, live.scale)
    }

    /// Start the periodic geometry audit (once per process). See `auditSurfaceGeometry`.
    static func startGeometryAudit() {
        Lifecycle.queue.async {
            guard Lifecycle.geometryAuditTimer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: Lifecycle.queue)
            timer.schedule(deadline: .now() + 60, repeating: 60, leeway: .seconds(15))
            timer.setEventHandler { WallpaperXPCHandler.auditSurfaceGeometry() }
            Lifecycle.geometryAuditTimer = timer
            timer.resume()
        }
    }

    /// Re-frame any non-preview surface whose stored geometry is far smaller
    /// than its live display (a transitional acquire minted it small and no
    /// later re-acquire healed it, the stuck half-scale wallpaper). Reuses
    /// the REUSE path's own re-frame, so a healed surface is indistinguishable
    /// from a display mode change. Must run on `Lifecycle.queue`. Quiet unless
    /// it heals something. Renderer-less and preview surfaces are skipped:
    /// the former heal through the normal REUSE path on next acquire, the
    /// latter are intentionally small.
    static func auditSurfaceGeometry() {
        for surface in WallpaperState.shared.surfaceGeometries() {
            guard !surface.isPreview, surface.hasRenderer else { continue }
            guard let live = liveDisplayGeometry(displayID: surface.displayID) else { continue }
            let liveArea = live.size.width * live.size.height
            let curArea = surface.destSize.width * surface.destSize.height
            guard curArea > 0, curArea < liveArea * shrunkenSurfaceFraction else { continue }
            guard let resized = WallpaperState.shared.updateGeometryIfChanged(
                destSize: live.size, scaleFactor: live.scale, for: surface.key
            ) else { continue }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            resized.rootLayer.frame = CGRect(origin: .zero, size: live.size)
            resized.rootLayer.contentsScale = live.scale
            reframeGradientFallback(on: resized.rootLayer)
            CATransaction.commit()
            CATransaction.flush()
            resized.renderer?.resize(to: live.size, scale: live.scale)
            extensionLog("  [audit] healed shrunken surface on display \(surface.displayID): \(surface.destSize) → \(live.size)")
        }
    }


    func invalidate(withId id: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        markServed()
        nonisolated(unsafe) let unsafeID = id
        nonisolated(unsafe) let handler = self
        Lifecycle.queue.async { handler.invalidateBody(id: unsafeID, reply: reply) }
    }

    private func invalidateBody(id: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        // Per-SURFACE teardown, resolved via the WallpaperID UUID learned at acquire. Each
        // surface (Space / lock screen / Settings preview) owns its own context, so we simply
        // tear down THIS surface after a short grace. A re-acquire of the same UUID (display
        // sleep/wake, a quick space revisit, a switch that reuses the id) cancels it. Because
        // teardown is scoped to one surface, it can never black out another Space (the old
        // shared-context cross-kill) and a superseded UUID just cleans up its own orphaned
        // context instead of leaking it.
        guard let uuid = extractWallpaperUUID(fromID: id) else {
            extensionLog("=== INVALIDATE === no UUID in id → ignore (kept \(WallpaperState.shared.activeContextCount) context(s))")
            reply(nil); return
        }
        guard let key = WallpaperState.shared.resolveWallpaperKey(uuid) else {
            if WallpaperState.shared.wasRecentlyForgotten(uuid) {
                extensionLog("=== INVALIDATE === UUID \(uuid) already torn down here → ignore")
            } else {
                extensionLog("=== INVALIDATE === UUID \(uuid) never registered in this process → ignore (possible cross-process orphan still decoding elsewhere)")
            }
            reply(nil); return
        }
        // Nobody hosts the surface now: stop decoding at once, but keep the
        // context and its frame so a re-acquire within the grace is seamless.
        // An invalidate that leaves a host (another open connection
        // reacquired since, or another role shares the surface) keeps
        // playing, keeps the id so the last host's invalidate still lands,
        // and survives the grace.
        let action = WallpaperState.shared.invalidate(key, by: connectionSerial)
        if action?.retiresWallpaperID ?? true {
            WallpaperState.shared.forgetWallpaperID(uuid)
        }
        scheduleTeardown(for: key)
        let stopped = action == .graceOnly ? "another host may still show it (reacquired elsewhere or shared by the other role), keeps playing and survives the grace" : "stopped playback"
        extensionLog("=== INVALIDATE === UUID \(uuid) → \(stopped), tear down surface on display \(key.displayID) in \(Lifecycle.teardownGrace)s unless re-acquired")
        reply(nil)
    }
}
