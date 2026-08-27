import Foundation
import LumaWallCore

/// Chooses the WallpaperExtensionKit host on macOS 26 when the extension is packaged,
/// otherwise keeps the existing desktop overlay engine.
@MainActor
final class WallpaperEngine {
    private let overlay: OverlayWallpaperEngine
    private let native: NativeWallpaperEngine?
    private(set) var mode: WallpaperHostMode

    init(displays: DisplayCoordinator, assignments: AssignmentStore) {
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
        if mode == .native, let native {
            try? await overlay.clear(displayID)
            try await native.apply(asset, to: displayID, composition: composition)
            return
        }
        try await overlay.apply(asset, to: displayID, composition: composition)
    }

    func applyToAll(_ asset: WallpaperAsset, composition: DisplayComposition = .init()) async throws {
        if mode == .native, let native {
            try? await overlay.clearAll()
            try await native.applyToAll(asset, composition: composition)
            return
        }
        try await overlay.applyToAll(asset, composition: composition)
    }

    func applySpanning(_ asset: WallpaperAsset) async throws {
        if mode == .native, let native {
            try? await overlay.clearAll()
            try await native.applySpanning(asset)
            return
        }
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
            try? await overlay.clearAll()
            await native.restore(using: library)
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
}
