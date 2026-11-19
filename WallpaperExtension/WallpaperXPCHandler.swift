import AppKit
import AVFoundation
import CoreMedia
import os
import QuartzCore

/// Builds the adaptive variant selector for a renderer. Captures only Sendable
/// values (the choice ID + a fallback URL), so it can cross into the render Task.
/// Reading the per-context `choice` (not the process-wide `currentVideoID`) keeps
/// each display on its own selection. Otherwise every renderer would converge on
/// whichever choice was set most recently (multi-monitor bug).
///
/// The renderer passes its own resolved tier. Recomputing one here from the raw
/// presentation mode disagreed with it whenever the screen-lock override applied
/// (the lock screen before the Agent reports it), so the renderer played the
/// paused tier's original file on Battery Saver.
func makeVariantSelector(choice: String?, fallback: URL) -> @Sendable (CGSize, PlaybackPolicy) -> URL {
    { displayPixels, tier in
        guard let videoID = choice else { return fallback }
        return VideoLibrary.shared.bestVariantURL(for: videoID, policy: tier, displayPixels: displayPixels) ?? fallback
    }
}

/// Process-wide serialization for wallpaper lifecycle XPC. Every connection gets its
/// own `WallpaperXPCHandler`, but the Agent multiplexes desktop + Settings-preview +
/// thumbnail connections, so lifecycle callbacks (acquire/update/invalidate/choice
/// change) can otherwise interleave across connections. We funnel them all through ONE
/// serial queue, mirroring Apple's single `Controller`-actor `AsyncQueue`, so an
/// invalidate can't slip between the halves of an acquire.
/// Carries a non-Sendable value (e.g. a `CALayer`) into a `Task` without tainting the
/// closure's isolation region. `nonisolated(unsafe)` on a local isn't enough under Swift 6.2
/// region-based isolation, capturing the raw layer merges other (Sendable) captures like
/// `videoURL` into a non-Sendable region, which then trips the `sending` checker across the
/// sibling BMP-snapshot Task. Boxing makes the capture genuinely Sendable.
struct SendableBox<T>: @unchecked Sendable { let value: T }

enum Lifecycle {
    static let queue = DispatchQueue(label: "app.lumawall.personal.lifecycle")

    /// Pending per-display teardown timers. Touched ONLY on `queue`.
    nonisolated(unsafe) static var teardownTimers: [DisplayKey: DispatchWorkItem] = [:]

    /// Periodic geometry-audit timer (see `auditSurfaceGeometry`). Created once
    /// on `queue` and never touched elsewhere.
    nonisolated(unsafe) static var geometryAuditTimer: (any DispatchSourceTimer)?

    /// Grace between an invalidate of a display's LIVE wallpaper and actually tearing it
    /// down. A re-acquire (display woke / switched) cancels it; only a display that stays
    /// gone (asleep/removed) lets it fire. Short enough to save power promptly, long enough
    /// to ride out a brief sleep/wake flicker.
    static let teardownGrace: TimeInterval = 15.0

    /// Acquire replies waiting for a create's layer to show something. Touched
    /// ONLY on `queue`, where acquire and teardown run, so a reuse can't
    /// check it between a create's seed and its reply.
    nonisolated(unsafe) static var replies = ReplyGate<DisplayKey, @Sendable () -> Void>()
}

final class WallpaperXPCHandler: NSObject, WallpaperExtensionXPCProtocol {
    /// Proxy to call methods on WallpaperAgent (ping, invalidateSnapshots, etc.).
    /// Lock-backed: it's assigned in `accept(connection:)` and nilled from the
    /// invalidation queue, while XPC callbacks read it from the message queue.
    /// The proxy existential isn't Sendable, so this uses a plain `NSLock` around
    /// `nonisolated(unsafe)` storage rather than `OSAllocatedUnfairLock` (whose
    /// `withLock` body is `@Sendable` and would reject the non-Sendable value).
    private let agentProxyLock = NSLock()
    private nonisolated(unsafe) var _agentProxy: (any WallpaperExtensionProxyXPCProtocol)?
    var agentProxy: (any WallpaperExtensionProxyXPCProtocol)? {
        get { agentProxyLock.lock(); defer { agentProxyLock.unlock() }; return _agentProxy }
        set { agentProxyLock.lock(); defer { agentProxyLock.unlock() }; _agentProxy = newValue }
    }

    /// PID of the peer on this connection (WallpaperAgent vs. Settings preview vs.
    /// the thumbnail service), set in `accept(connection:)`. Logged so acquire and
    /// invalidation can be attributed to a specific connection.
    var connectionPID: Int32 = -1

    /// Unique per connection (the agent reuses its PID across reconnects), so
    /// an invalidate can be matched to the connection that acquired.
    let connectionSerial = WallpaperXPCHandler.serials.withLock { $0 += 1; return $0 }
    private static let serials = OSAllocatedUnfairLock(initialState: 0)

    /// Whether this connection's most recent acquire was a Settings *preview*
    /// (`isPreview: true`). A preview connection reports its own presentation state
    /// (which idles/toggles as the picker is interacted with), and since every
    /// connection shares the one desktop renderer, letting a preview's `update()`
    /// apply pause policy would freeze the visible desktop wallpaper. Preview
    /// connections therefore don't drive playback; only the live desktop connection
    /// (`isPreview: false`) does.
    var acquiredAsPreview = false

    var previousPresentationMode = "default"

    /// Whether any exported method has been invoked on this connection. Read by the
    /// invalidationHandler: a connection that is accepted and invalidated without ever
    /// serving a method is "empty", the WallpaperAgent spiral-of-death signal
    /// (see SpiralRecovery). Set synchronously at each method's entry, before any queue hop.
    private let servedMethod = OSAllocatedUnfairLock(initialState: false)
    var didServeMethod: Bool {
        servedMethod.withLock { $0 }
    }

    /// Mark this connection as healthy (a real method arrived) and clear any spiral run.
    /// Call first thing in every exported entry point.
    func markServed() {
        servedMethod.withLock { $0 = true }
        SpiralRecovery.noteHealthyConnection()
    }

    func snapshot(withId _: Any?, reply: @escaping @Sendable (Any?, (any Error)?) -> Void) {
        markServed()
        traceLog("=== SNAPSHOT ===")

        // Get current time from any active renderer for a more representative snapshot
        var currentTime: CMTime?
        WallpaperState.shared.forEachRenderer { renderer in
            currentTime = CMTimebaseGetTime(renderer.timebase)
        }

        Task {
            if let snapshotXPC = await createSnapshotViaRuntime(currentTime: currentTime) {
                reply(snapshotXPC, nil)
                traceLog("  Snapshot replied (IOSurface)")
            } else {
                reply(nil, nil)
                traceLog("  Snapshot replied (nil)")
            }
        }
    }

    // MARK: - Settings

    func provideSettingsViewModels(withContentTypes _: Any?, reply: @escaping @Sendable (Any?, (any Error)?) -> Void) {
        markServed()
        traceLog("=== PROVIDE SETTINGS VIEW MODELS ===")

        Task {
            if let result = await buildSettingsViewModelsXPC() {
                traceLog("  [Settings] Remapped to \(NSStringFromClass(type(of: result as AnyObject)))")
                reply(result, nil)
            } else {
                traceLog("  [Settings] Build failed, using empty fallback")
                reply(makeEmptyGroupsResponse(), nil)
            }
        }
    }

    // MARK: - Choices

    func addChoiceRequest(withChoiceRequest _: Any?, onBehalfOfProcess _: Any?, reply: @escaping @Sendable (Any?, (any Error)?) -> Void) {
        markServed()
        traceLog("=== ADD CHOICE REQUEST ===")
        reply(nil, nil)
    }

    // MARK: - Downloads

    func isChoiceDownloaded(with _: Any?, reply: @escaping @Sendable (Bool, (any Error)?) -> Void) {
        traceLog("isChoiceDownloaded")
        reply(true, nil)
    }

    func download(withChoiceID _: Any?, reply: ((any Error)?) -> Void) -> Any? {
        traceLog("download")
        reply(nil)
        return nil
    }

    func pauseDownload(for _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        reply(nil)
    }

    func cancelDownload(for _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        reply(nil)
    }

    func resumeDownload(for _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        reply(nil)
    }

    func removeDownload(for _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        reply(nil)
    }

    // MARK: - Migration

    func migrateSelectedChoice(for _: Any?, reply: @escaping @Sendable (Any?, (any Error)?) -> Void) {
        traceLog("migrateSelectedChoice")
        reply(nil, nil)
    }

    func migrate(from _: Any?, to _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        traceLog("migrate")
        reply(nil)
    }

    // MARK: - Shuffle

    func skipShuffledContent(withId _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        markServed()
        let handled = ShuffleController.shared.skip()
        extensionLog("=== SKIP SHUFFLED CONTENT === handled=\(handled)")
        reply(nil)
    }

    func canSkipShuffledContent(withId _: Any?, reply: @escaping @Sendable (Bool, (any Error)?) -> Void) {
        traceLog("canSkipShuffledContent")
        reply(ShuffleController.shared.isActive, nil)
    }

    // MARK: - Debug & Notifications

    func handleDebugRequest(for _: Any?, reply: @escaping @Sendable (Any?, (any Error)?) -> Void) {
        traceLog("handleDebugRequest")
        reply(nil, nil)
    }

    func handleNotification(withNamed name: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        traceLog("handleNotification(\(name ?? "nil"))")
        reply(nil)
    }
}
