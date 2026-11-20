import Foundation
import LumaWallCore
import Observation

/// Plays wallpapers through the overlay, or through the system wallpaper host
/// when the user opted in to native mode. With native mode off there is no
/// native host at all, so nothing writes the macOS wallpaper store, restarts
/// WallpaperAgent or copies into the extension's container.
@MainActor
@Observable
final class WallpaperEngine {
    /// Displays native mode just gave up on, and the error that caused it
    /// (nil when a restore failed without one).
    struct NativeFallback {
        var displayIDs: Set<DisplayID>
        var error: (any Error)?
    }

    private let displays: DisplayCoordinator
    private let overlay: OverlayWallpaperEngine
    @ObservationIgnored private var native: NativeWallpaperEngine?
    private let assignments: AssignmentStore
    private let nativeSetting: NativeModeSetting
    @ObservationIgnored private var libraryByID: [WallpaperID: WallpaperAsset] = [:]
    private(set) var mode: WallpaperHostMode
    private(set) var nativeModeEnabled: Bool
    private(set) var needsNativeModeDisclosure: Bool
    /// Displays where native mode failed this session. The overlay plays
    /// them, and native mode doesn't try them again until it is turned off
    /// and on or the app relaunches.
    private(set) var nativeFallbackDisplayIDs: Set<DisplayID> = []
    @ObservationIgnored var onNativeFallback: ((NativeFallback) -> Void)?
    /// Bumped on every host change. Work that started under an older host
    /// checks it after each suspension and stops instead of undoing the
    /// change.
    @ObservationIgnored private var hostGeneration = 0

    init(displays: DisplayCoordinator, assignments: AssignmentStore, nativeSetting: NativeModeSetting = .standard) {
        nativeSetting.migrateIfNeeded()
        self.displays = displays
        self.assignments = assignments
        self.nativeSetting = nativeSetting
        self.overlay = OverlayWallpaperEngine(displays: displays, assignments: assignments)
        self.nativeModeEnabled = nativeSetting.isEnabled
        self.needsNativeModeDisclosure = nativeSetting.needsDisclosure
        self.mode = WallpaperHostCapabilities.preferredMode(nativeModeEnabled: nativeSetting.isEnabled)
        if mode == .native {
            self.native = NativeWallpaperEngine(displays: displays, assignments: assignments)
        } else {
            self.native = nil
        }
    }

    var hasNativeHost: Bool { native != nil }

    /// Turns native mode on (after the user confirmed the warning) or off,
    /// and moves playback to the new host.
    func setNativeMode(enabled: Bool, library: [WallpaperAsset]) async {
        hostGeneration += 1
        if enabled { nativeSetting.enable() } else { nativeSetting.disable() }
        nativeModeEnabled = enabled
        needsNativeModeDisclosure = false
        nativeFallbackDisplayIDs = []
        libraryByID = Dictionary(uniqueKeysWithValues: library.map { ($0.id, $0) })
        if WallpaperHostCapabilities.preferredMode(nativeModeEnabled: enabled) == .native {
            if native == nil { native = NativeWallpaperEngine(displays: displays, assignments: assignments) }
            mode = .native
            await restore(using: library)
        } else {
            native?.detach()
            native = nil
            mode = .overlay
            await overlay.restore(using: library)
        }
    }

    func acknowledgeNativeModeDisclosure() {
        nativeSetting.acknowledgeDisclosure()
        needsNativeModeDisclosure = false
    }

    /// Overlay sessions also run in native mode, for cropped or spanning
    /// wallpapers and for displays native mode fell back on.
    var activeDisplayIDs: Set<DisplayID> {
        switch mode {
        case .native: (native?.activeDisplayIDs ?? []).union(overlay.activeDisplayIDs)
        case .overlay: overlay.activeDisplayIDs
        }
    }

    /// True when any wallpaper plays, native or overlay. Spanning wallpapers
    /// use overlay sessions even in native mode, so `activeDisplayIDs` alone
    /// would miss them.
    var hasActivePlayback: Bool {
        if !overlay.activeDisplayIDs.isEmpty { return true }
        return mode == .native && !(native?.activeDisplayIDs.isEmpty ?? true)
    }

    func wallpaperID(on displayID: DisplayID) -> WallpaperID? {
        switch mode {
        case .native: overlay.wallpaperID(on: displayID) ?? native?.wallpaperID(on: displayID)
        case .overlay: overlay.wallpaperID(on: displayID)
        }
    }

    func composition(on displayID: DisplayID) -> DisplayComposition {
        switch mode {
        case .native:
            overlay.activeDisplayIDs.contains(displayID)
                ? overlay.composition(on: displayID) : native?.composition(on: displayID) ?? .init()
        case .overlay: overlay.composition(on: displayID)
        }
    }

    func tier(on displayID: DisplayID) -> PlaybackTier {
        switch mode {
        case .native:
            overlay.activeDisplayIDs.contains(displayID)
                ? overlay.tier(on: displayID) : native?.tier(on: displayID) ?? .full
        case .overlay: overlay.tier(on: displayID)
        }
    }

    func apply(_ asset: WallpaperAsset, to displayID: DisplayID, composition: DisplayComposition = .init()) async throws {
        libraryByID[asset.id] = asset
        let generation = hostGeneration
        if mode == .native, let native, composition.usesDefaultCrop, composition.spanningCanvas == nil,
            !nativeFallbackDisplayIDs.contains(displayID)
        {
            do {
                try await native.apply(asset, to: displayID, composition: composition)
                // Native mode went off meanwhile: the overlay plays it instead.
                guard generation == hostGeneration else {
                    try await overlay.apply(asset, to: displayID, composition: composition)
                    return
                }
                overlay.dismantleSession(displayID)
                return
            } catch {
                try await handleNativeFailure(error, on: [displayID], since: generation)
            }
        }
        try await overlay.apply(asset, to: displayID, composition: composition)
    }

    func applyToAll(_ asset: WallpaperAsset, composition: DisplayComposition = .init()) async throws {
        libraryByID[asset.id] = asset
        let generation = hostGeneration
        if mode == .native, let native, composition.usesDefaultCrop, composition.spanningCanvas == nil {
            let connected = Set(displays.refresh().map(\.displayID))
            let fellBack = connected.intersection(nativeFallbackDisplayIDs)
            if fellBack != connected {
                let missing: Set<DisplayID>
                do {
                    missing = try await native.applyToAll(asset, composition: composition, excluding: fellBack)
                } catch {
                    try await handleNativeFailure(error, on: connected, since: generation)
                    try await overlay.applyToAll(asset, composition: composition)
                    return
                }
                guard generation == hostGeneration else {
                    try await overlay.applyToAll(asset, composition: composition)
                    return
                }
                if !missing.isEmpty {
                    fallBack(missing, after: NativeWallpaperAssignmentService.AssignmentError.unknownDisplay)
                }
                // Overlay errors from here on leave the native displays alone.
                let overlayIDs = fellBack.union(missing)
                for id in connected.subtracting(overlayIDs) { overlay.dismantleSession(id) }
                for id in overlayIDs { try await overlay.apply(asset, to: id, composition: composition) }
                return
            }
        }
        try await overlay.applyToAll(asset, composition: composition)
    }

    func applySpanning(_ asset: WallpaperAsset) async throws {
        try await overlay.applySpanning(asset)
    }

    func clear(_ displayID: DisplayID) async throws {
        if mode == .native, let native {
            try await native.clear(displayID)
        }
        try await overlay.clear(displayID)
    }

    func clearAll() async throws {
        if mode == .native, let native {
            try await native.clearAll()
        }
        try await overlay.clearAll()
    }

    func apply(tier: PlaybackTier, to displayID: DisplayID) {
        if mode == .native {
            native?.apply(tier: tier, to: displayID)
        }
        overlay.apply(tier: tier, to: displayID)
    }

    /// Overlay half of a display-topology restore. Kill-free (window geometry
    /// and posters only), so it runs immediately on every screen-parameters
    /// burst. See `restoreNative(using:)` for why the native half waits.
    func restoreOverlay(using library: [WallpaperAsset]) async {
        libraryByID = Dictionary(uniqueKeysWithValues: library.map { ($0.id, $0) })
        if mode == .native {
            let generation = hostGeneration
            let split = await needsOverlaySplit()
            guard generation == hostGeneration else { return }
            if split {
                await overlay.restore(using: library, nativeHostActive: true, claiming: nativeFallbackDisplayIDs)
            } else {
                overlay.dismantleSessions()
            }
            return
        }
        await overlay.restore(using: library)
    }

    /// Native half of a display-topology restore. Rewriting Index.plist
    /// restarts WallpaperAgent, so callers must let the topology settle first
    /// (see `AppModel.scheduleSettledNativeRestore`): killing the agent once
    /// per mode-flip of a monitor handshake orphans in-flight surfaces and
    /// leaves the new agent hosting a mix of stale and fresh contexts.
    /// Split ownership with the overlay (which takes non-default displays and
    /// leaves default-crop ones alone): either side touching the other's
    /// displays clobbers assignments (overlay posters) or leaks windows.
    func restoreNative(using library: [WallpaperAsset]) async {
        guard mode == .native, let native else { return }
        libraryByID = Dictionary(uniqueKeysWithValues: library.map { ($0.id, $0) })
        let generation = hostGeneration
        do {
            let split = await needsOverlaySplit()
            guard generation == hostGeneration else { return }
            let failed = try await native.restore(
                using: library, onlyDefaultCrop: split, skipping: nativeFallbackDisplayIDs)
            guard generation == hostGeneration, !failed.isEmpty else { return }
            fallBack(failed, after: nil)
            await overlay.restore(using: library, nativeHostActive: true, claiming: nativeFallbackDisplayIDs)
        } catch {
            guard generation == hostGeneration else { return }
            await fallBackToOverlay()
        }
    }

    /// A missing display or a removed wallpaper isn't native mode's fault,
    /// and permission errors switch every display over; anything else moves
    /// `displayIDs` to the overlay so the caller can retry there. A failure from a host that has
    /// since been replaced (native mode turned off meanwhile) changes nothing.
    private func handleNativeFailure(
        _ error: any Error, on displayIDs: Set<DisplayID>, since generation: Int
    ) async throws {
        if case OverlayWallpaperEngine.EngineError.missingDisplay = error { throw error }
        // A wallpaper removed while it deployed isn't native mode's failure,
        // and the overlay mustn't play it instead.
        if case NativeWallpaperDeployment.DeploymentError.removed = error { throw error }
        guard generation == hostGeneration else { return }
        if WallpaperHostCapabilities.isPermissionError(error) {
            await fallBackToOverlay()
        } else {
            fallBack(displayIDs, after: error)
        }
    }

    private func fallBack(_ displayIDs: Set<DisplayID>, after error: (any Error)?) {
        let added = displayIDs.subtracting(nativeFallbackDisplayIDs)
        guard !added.isEmpty else { return }
        nativeFallbackDisplayIDs.formUnion(added)
        let ids = added.map(\.rawValue).sorted().joined(separator: ", ")
        nativeHostLog.error("native mode failed on [\(ids, privacy: .public)]; using the overlay there")
        onNativeFallback?(NativeFallback(displayIDs: added, error: error))
    }

    private func fallBackToOverlay() async {
        hostGeneration += 1
        mode = .overlay
        native?.detach()
        nativeHostLog.notice("Native wallpaper storage access denied; using overlay playback")
        await overlay.restore(using: Array(libraryByID.values))
    }

    private func needsOverlaySplit() async -> Bool {
        // Only CONNECTED displays count. Assignments for disconnected
        // displays are kept for reconnect resume, but letting them hold split
        // mode on leaves the overlay owning nothing while the native host
        // skips displays it should claim.
        let connectedIDs = Set(displays.refresh().map(\.displayID))
        let snapshot = await assignments.current()
        return snapshot.assignments.contains {
            $0.isEnabled && connectedIDs.contains($0.displayID)
                && (!$0.composition.usesDefaultCrop || $0.composition.spanningCanvas != nil
                    || nativeFallbackDisplayIDs.contains($0.displayID))
        }
    }

    func restore(using library: [WallpaperAsset]) async {
        await restoreOverlay(using: library)
        await restoreNative(using: library)
    }

    func reapplyAssignments() {
        if mode == .native {
            Task { await restoreNative(using: Array(libraryByID.values)) }
            return
        }
        overlay.reapplyAssignments()
    }

    func releaseWorkingMemory() {
        overlay.releaseWorkingMemory()
        if mode == .native {
            NativeWallpaperDeployment.notifyLibraryChanged()
            NativeWallpaperDeployment.requestSnapshotCacheClear()
        }
    }

    var activeDecoderCount: Int {
        switch mode {
        case .native: (native?.activeDisplayIDs.count ?? 0) + overlay.activeDecoderCount
        case .overlay: overlay.activeDecoderCount
        }
    }
}
