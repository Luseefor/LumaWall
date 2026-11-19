import Foundation
import os

/// Extension-side reader for shared preferences written by the main app,
/// and writer for extension state (isActive) read by the app.
///
/// Thread-safe via `OSAllocatedUnfairLock`. Observes `app.lumawall.personal.prefsChanged`
/// Darwin notification to reload when the app writes new values.
final class WallpaperPrefs: @unchecked Sendable {
    static let shared = WallpaperPrefs()

    private struct ContextState: Codable {
        var displayID: UInt32
        var videoID: String?
        var videoName: String?
    }

    private struct StateFile: Codable {
        var isActive: Bool
        var currentVideoID: String?
        var currentVideoName: String?
        var contexts: [ContextState]?
    }

    private let lock = OSAllocatedUnfairLock(initialState: WallpaperPrefsFile())

    private static var docsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    private static var prefsURL: URL {
        docsURL.appendingPathComponent("lumawall-prefs.json")
    }

    private static var stateURL: URL {
        docsURL.appendingPathComponent("lumawall-state.json")
    }

    private init() {
        reload()
    }

    // MARK: - Public (Prefs, app → extension)

    var userPaused: Bool {
        lock.withLock { $0.userPaused }
    }

    var alwaysPauseDesktop: Bool {
        lock.withLock { $0.alwaysPauseDesktop }
    }

    var pauseWhenOccluded: Bool {
        lock.withLock { $0.pauseWhenOccluded }
    }

    var desktopOccluded: Bool {
        lock.withLock { $0.desktopOccluded }
    }

    /// Displays fully covered by windows, as computed by the app's OcclusionMonitor.
    var occludedDisplays: Set<UInt32> {
        lock.withLock { $0.occludedDisplays ?? [] }
    }

    /// Whether this display's wallpaper is invisible behind windows, either its
    /// own display is covered or every display is (global signal from an app
    /// version that predates per-display occlusion).
    func isOccluded(displayID: UInt32) -> Bool {
        desktopOccluded || occludedDisplays.contains(displayID)
    }

    /// Displays owned by a single fullscreen app (native fullscreen Space or
    /// borderless-fullscreen game). Paused unconditionally, unlike occlusion,
    /// which is gated by the "Pause When Hidden" setting.
    var fullscreenDisplays: Set<UInt32> {
        lock.withLock { $0.fullscreenDisplays ?? [] }
    }

    var pausedDisplays: Set<UInt32> {
        lock.withLock { $0.pausedDisplays ?? [] }
    }

    var powerProfile: String {
        lock.withLock { $0.powerProfile ?? "automatic" }
    }

    /// Whether a LumaWall choice is the active screensaver (relayed by the app from
    /// the wallpaper store's Idle sections).
    var screenSaverIsOurs: Bool {
        lock.withLock { $0.screenSaverIsOurs ?? false }
    }

    // MARK: - Public (State, extension → app)

    /// Call when the extension gains or loses active wallpaper contexts.
    func setActive(_ active: Bool) {
        let videoID = active ? WallpaperState.shared.currentVideoID : nil
        let videoName = videoID.flatMap { VideoLibrary.shared.entry(for: $0)?.name }
        let contexts = active ? buildContextStates() : nil
        let state = StateFile(isActive: active, currentVideoID: videoID, currentVideoName: videoName, contexts: contexts)
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: Self.stateURL, options: .atomic)
        postStateNotification()
        extensionLog("[WallpaperPrefs] setActive(\(active), video: \(videoName ?? "nil"))")
    }

    /// Call when the active video changes while the extension is already active.
    func updateCurrentVideo() {
        let videoID = WallpaperState.shared.currentVideoID
        let videoName = videoID.flatMap { VideoLibrary.shared.entry(for: $0)?.name }
        let contexts = buildContextStates()
        let state = StateFile(isActive: true, currentVideoID: videoID, currentVideoName: videoName, contexts: contexts)
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: Self.stateURL, options: .atomic)
        postStateNotification()
        traceLog("[WallpaperPrefs] updateCurrentVideo(\(videoName ?? "nil"))")
    }

    private func buildContextStates() -> [ContextState] {
        WallpaperState.shared.activeDisplayContexts().map { ctx in
            let name = ctx.videoID.flatMap { VideoLibrary.shared.entry(for: $0)?.name }
            return ContextState(displayID: ctx.displayID, videoID: ctx.videoID, videoName: name)
        }
    }

    // MARK: - Reload

    /// Re-read the prefs file and report what the change calls for.
    @discardableResult
    func reload() -> PrefsReload {
        let data: Data
        do {
            data = try Data(contentsOf: Self.prefsURL)
        } catch {
            return .none // File doesn't exist yet, normal on first launch
        }
        do {
            let prefs = try JSONDecoder().decode(WallpaperPrefsFile.self, from: data)
            let old = lock.withLock { state in
                defer { state = prefs }
                return state
            }
            traceLog("[WallpaperPrefs] Loaded: userPaused=\(prefs.userPaused), alwaysPauseDesktop=\(prefs.alwaysPauseDesktop), pauseWhenOccluded=\(prefs.pauseWhenOccluded), desktopOccluded=\(prefs.desktopOccluded)")
            return PrefsReload.between(old, prefs)
        } catch {
            extensionLog("[WallpaperPrefs] Failed to decode prefs: \(error)")
            return .none
        }
    }

    /// Serializes reloads; `coalescer` is touched only here.
    private let reloadQueue = DispatchQueue(label: "app.lumawall.prefs-reload", qos: .userInitiated)
    private var coalescer = ReloadCoalescer()
    /// How long a reload waits for the rest of a burst (the app posts once per
    /// occlusion update).
    private static let reloadDelay: TimeInterval = 0.1

    /// The app wrote the prefs file: reload once for the whole burst, and
    /// recompute policies only when something changed.
    func prefsDidChange() {
        reloadQueue.async { [self] in
            guard coalescer.request() else { return }
            reloadQueue.asyncAfter(deadline: .now() + Self.reloadDelay) { [self] in
                coalescer.begin()
                guard case let .applyPolicies(refreshPower) = reload() else { return }
                applyPauseState(refreshPower: refreshPower)
            }
        }
    }

    // MARK: - Darwin Observer

    private var isObservingChanges = false

    func observeChanges() {
        guard !isObservingChanges else { return }
        isObservingChanges = true

        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, _, _, _, _ in WallpaperPrefs.shared.prefsDidChange() },
            "app.lumawall.personal.prefsChanged" as CFString,
            nil,
            .deliverImmediately,
        )
    }

    func stopObserving() {
        guard isObservingChanges else { return }
        isObservingChanges = false

        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterRemoveObserver(
            center,
            observer,
            CFNotificationName("app.lumawall.personal.prefsChanged" as CFString),
            nil,
        )
    }

    /// Recompute playback policy and apply to all active renderers.
    /// Occlusion/fullscreen transitions apply INSTANTLY (no ramp): the 6s
    /// ramp-down made covering/uncovering a window feel like broken slow-motion
    /// pause/resume. Ramps are reserved for desktop↔lock transitions, which pass
    /// animated explicitly from updateBody().
    private func applyPauseState(refreshPower: Bool) {
        let state = WallpaperState.shared
        // A new power profile: re-read power now instead of trusting the poll
        // (stopped while nothing plays), or the profile evaluates against
        // stale battery state and appears to do nothing.
        if refreshPower { PowerMonitor.shared.refreshNow() }
        applyPolicies(
            presentationMode: state.presentationMode,
            activityState: state.activityState,
            powerState: PowerMonitor.shared.currentState,
            animated: false,
        )
    }

    /// Compute and apply the playback policy to every renderer, per display
    /// when per-display info exists, so per-display pause and occlusion survive
    /// global recomputes (thermal, battery, lock, presentation changes).
    func applyPolicies(
        presentationMode: String,
        activityState: String,
        powerState: PowerMonitor.PowerState,
        animated: Bool = false,
    ) {
        let state = WallpaperState.shared
        let displayIDs = state.liveDisplayIDs()

        func policy(for displayID: UInt32?) -> PlaybackPolicy {
            self.policy(for: displayID, presentationMode: presentationMode, activityState: activityState, powerState: powerState)
        }

        // Surfaces without a display ID take the global policy, also beside
        // displays that have one: skipping them left one seeded Paused (a
        // fullscreen app on another display) stuck there. Live surfaces only;
        // previews take their own tier below (see forLiveRenderers).
        let hardPause = RampMath.cutsRampDown(thermalState: powerState.thermalState, activityState: activityState)
        for displayID in displayIDs.map(Optional.some) + [nil] {
            let displayPolicy = policy(for: displayID)
            state.forLiveRenderers(displayID: displayID) { renderer in
                renderer.applyPolicy(displayPolicy, animated: animated, hardPause: hardPause && displayPolicy == .paused, onBattery: powerState.isOnBattery)
            }
        }
        let previewTier = previewPolicy(powerState: powerState)
        state.forPreviewRenderers { renderer in
            renderer.applyPolicy(previewTier, animated: false, hardPause: hardPause && previewTier == .paused, onBattery: powerState.isOnBattery)
        }
    }

    /// The tier `applyPolicies` gives preview renderers: the hard pauses and
    /// power tiers, none of the desktop rules.
    func previewPolicy(powerState: PowerMonitor.PowerState) -> PlaybackPolicy {
        PlaybackPolicy.preview(
            userPaused: userPaused,
            thermalState: powerState.thermalState,
            isOnBattery: powerState.isOnBattery,
            batteryLevel: powerState.batteryLevel,
            isGameModeActive: powerState.isGameModeActive,
            isLowPowerModeEnabled: powerState.isLowPowerModeEnabled,
            displayBrightness: powerState.displayBrightness,
            powerProfile: powerProfile,
        )
    }

    /// The tier `applyPolicies` gives live renderers on `displayID`, or every
    /// live renderer when `displayID` is nil.
    func policy(
        for displayID: UInt32?,
        presentationMode: String,
        activityState: String,
        powerState: PowerMonitor.PowerState,
    ) -> PlaybackPolicy {
        PlaybackPolicy.compute(
            presentationMode: presentationMode,
            activityState: activityState,
            userPaused: userPaused || displayID.map { pausedDisplays.contains($0) } ?? false,
            alwaysPauseDesktop: alwaysPauseDesktop,
            pauseWhenOccluded: pauseWhenOccluded,
            desktopOccluded: displayID.map(isOccluded(displayID:)) ?? desktopOccluded,
            displayHasFullscreenApp: displayID.map { fullscreenDisplays.contains($0) }
                ?? !fullscreenDisplays.isEmpty,
            screenSaverIsOurs: screenSaverIsOurs,
            powerState: powerState,
            powerProfile: powerProfile,
        )
    }

    private func postStateNotification() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(
            center,
            CFNotificationName("app.lumawall.personal.stateChanged" as CFString),
            nil,
            nil,
            true,
        )
    }
}
