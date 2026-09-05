import Foundation
import LumaWallCore

@MainActor
final class WallpaperEngine {
    private let overlay: OverlayWallpaperEngine
    private let native: NativeWallpaperEngine?
    private let assignments: AssignmentStore
    private(set) var mode: WallpaperHostMode

    init(displays: DisplayCoordinator, assignments: AssignmentStore) {
        self.assignments = assignments
        self.overlay = OverlayWallpaperEngine(displays: displays, assignments: assignments)
        self.mode = WallpaperHostCapabilities.preferredMode
        if mode == .native {
            self.native = NativeWallpaperEngine(displays: displays, assignments: assignments)
        } else {
            self.native = nil
        }
    }

    var activeDisplayIDs: Set<DisplayID> {
        switch mode {
        case .native: native?.activeDisplayIDs ?? []
        case .overlay: overlay.activeDisplayIDs
        }
    }

    func wallpaperID(on displayID: DisplayID) -> WallpaperID? {
        switch mode {
        case .native: native?.wallpaperID(on: displayID)
        case .overlay: overlay.wallpaperID(on: displayID)
        }
    }

    func composition(on displayID: DisplayID) -> DisplayComposition {
        switch mode {
        case .native: native?.composition(on: displayID) ?? .init()
        case .overlay: overlay.composition(on: displayID)
        }
    }

    func tier(on displayID: DisplayID) -> PlaybackTier {
        switch mode {
        case .native: native?.tier(on: displayID) ?? .full
        case .overlay: overlay.tier(on: displayID)
        }
    }

    func apply(_ asset: WallpaperAsset, to displayID: DisplayID, composition: DisplayComposition = .init()) async throws {
        if mode == .native, let native, composition.usesDefaultCrop, composition.spanningCanvas == nil {
            overlay.dismantleSession(displayID)
            try await native.apply(asset, to: displayID, composition: composition)
            return
        }
        try await overlay.apply(asset, to: displayID, composition: composition)
    }

    func applyToAll(_ asset: WallpaperAsset, composition: DisplayComposition = .init()) async throws {
        if mode == .native, let native, composition.usesDefaultCrop, composition.spanningCanvas == nil {
            overlay.dismantleSessions()
            try await native.applyToAll(asset, composition: composition)
            return
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

    func restore(using library: [WallpaperAsset]) async {
        if mode == .native, let native {
            let snapshot = await assignments.current()
            let needsOverlay = snapshot.assignments.contains {
                $0.isEnabled && (!$0.composition.usesDefaultCrop || $0.composition.spanningCanvas != nil)
            }
            if needsOverlay {
                // Split ownership: the overlay takes non-default displays
                // (and leaves default-crop ones alone), the native host takes
                // the default-crop ones. Either side touching the other's
                // displays clobbers assignments (overlay posters) or leaks
                // windows.
                await overlay.restore(using: library, nativeHostActive: true)
                await native.restore(using: library, onlyDefaultCrop: true)
            } else {
                overlay.dismantleSessions()
                await native.restore(using: library)
            }
            return
        }
        await overlay.restore(using: library)
    }

    func reapplyAssignments() {
        if mode == .native {
            native?.reapplyAssignments()
            return
        }
        overlay.reapplyAssignments()
    }

    func releaseWorkingMemory() {
        overlay.releaseWorkingMemory()
        if mode == .native {
            NativeWallpaperDeployment.notifyLibraryChanged()
            let center = CFNotificationCenterGetDarwinNotifyCenter()
            CFNotificationCenterPostNotification(
                center,
                CFNotificationName("app.lumawall.personal.clearCaches" as CFString),
                nil,
                nil,
                true
            )
        }
    }

    var activeDecoderCount: Int {
        switch mode {
        case .native: native?.activeDisplayIDs.count ?? 0
        case .overlay: overlay.activeDecoderCount
        }
    }
}
