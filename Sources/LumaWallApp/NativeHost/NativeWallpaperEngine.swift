import Foundation
import LumaWallCore

/// Applies wallpapers through WallpaperExtensionKit / WallpaperAgent on macOS 26+.
@MainActor
final class NativeWallpaperEngine {
    private let displays: DisplayCoordinator
    private let assignments: AssignmentStore
    private var active: [DisplayID: (WallpaperID, DisplayComposition)] = [:]
    private var tiers: [DisplayID: PlaybackTier] = [:]

    init(displays: DisplayCoordinator, assignments: AssignmentStore) {
        self.displays = displays
        self.assignments = assignments
    }

    var activeDisplayIDs: Set<DisplayID> { Set(active.keys) }

    func wallpaperID(on displayID: DisplayID) -> WallpaperID? {
        active[displayID]?.0
    }

    func composition(on displayID: DisplayID) -> DisplayComposition {
        active[displayID]?.1 ?? .init()
    }

    func tier(on displayID: DisplayID) -> PlaybackTier {
        tiers[displayID] ?? .full
    }

    func apply(_ asset: WallpaperAsset, to displayID: DisplayID, composition: DisplayComposition = .init()) async throws {
        guard let connected = displays.display(id: displayID) ?? displays.refresh().first(where: { $0.displayID == displayID }) else {
            throw OverlayWallpaperEngine.EngineError.missingDisplay
        }
        let entry = try await NativeWallpaperDeployment.ensureDeployed(asset: asset)
        try NativeWallpaperAssignmentService.apply(entry: entry, to: [connected.cgDisplayID])
        active[displayID] = (asset.id, composition)
        try await assignments.upsert(
            DisplayAssignment(displayID: displayID, wallpaperID: asset.id, composition: composition, isEnabled: true)
        )
        apply(tier: tiers[displayID] ?? .full, to: displayID)
    }

    func applyToAll(_ asset: WallpaperAsset, composition: DisplayComposition = .init()) async throws {
        let connected = displays.refresh()
        guard !connected.isEmpty else { throw OverlayWallpaperEngine.EngineError.missingDisplay }
        let entry = try await NativeWallpaperDeployment.ensureDeployed(asset: asset)
        try NativeWallpaperAssignmentService.apply(
            entry: entry,
            to: Set(connected.map(\.cgDisplayID))
        )
        for display in connected {
            active[display.displayID] = (asset.id, composition)
        }
        try await assignments.upsert(connected.map {
            DisplayAssignment(displayID: $0.displayID, wallpaperID: asset.id, composition: composition, isEnabled: true)
        })
    }

    func applySpanning(_ asset: WallpaperAsset) async throws {
        // System wallpaper host is per-display; deploy the same video across the arrangement.
        try await applyToAll(asset)
        let connected = displays.refresh()
        guard let canvas = SpanningGeometry.canvas(for: connected.map(\.frame)) else { return }
        let composition = DisplayComposition(contentMode: .fill, spanningCanvas: canvas)
        for display in connected {
            active[display.displayID] = (asset.id, composition)
        }
        try await assignments.upsert(connected.map {
            DisplayAssignment(displayID: $0.displayID, wallpaperID: asset.id, composition: composition, isEnabled: true)
        })
    }

    func clear(_ displayID: DisplayID) async throws {
        active.removeValue(forKey: displayID)
        tiers.removeValue(forKey: displayID)
        try await assignments.clear(displayID: displayID)
        // Leaving the system choice in place avoids blank desktops; overlay teardown is handled by the façade.
    }

    func clearAll() async throws {
        active.removeAll()
        tiers.removeAll()
        try await assignments.clearAll()
    }

    func apply(tier: PlaybackTier, to displayID: DisplayID) {
        tiers[displayID] = tier
        pushPrefs()
    }

    func restore(using library: [WallpaperAsset]) async {
        let snapshot = await assignments.current()
        let byID = Dictionary(uniqueKeysWithValues: library.map { ($0.id, $0) })
        let connected = displays.refresh()
        var map: [UInt32: NativeWallpaperDeployment.EntryInfo] = [:]
        for assignment in snapshot.assignments where assignment.isEnabled {
            guard let wallpaperID = assignment.wallpaperID,
                  let asset = byID[wallpaperID],
                  let display = connected.first(where: { $0.displayID == assignment.displayID })
            else { continue }
            guard let entry = try? await NativeWallpaperDeployment.ensureDeployed(asset: asset) else { continue }
            map[display.cgDisplayID] = entry
            active[assignment.displayID] = (asset.id, assignment.composition)
        }
        guard !map.isEmpty else { return }
        try? NativeWallpaperAssignmentService.apply(assignments: map)
    }

    func reapplyAssignments() {
        // WallpaperAgent owns surfaces; nothing to reassert from the app process.
    }

    private func pushPrefs() {
        let paused = Set(tiers.compactMap { id, tier -> UInt32? in
            guard tier == .paused, let display = displays.display(id: id) else { return nil }
            return display.cgDisplayID
        })
        let userPaused = !tiers.isEmpty && tiers.values.allSatisfy { $0 == .paused }
        NativeWallpaperPrefsBridge.write(
            userPaused: userPaused,
            pauseWhenOccluded: UserDefaults.standard.object(forKey: "lumawall.pauseWhenObscured") as? Bool ?? true,
            alwaysPauseDesktop: UserDefaults.standard.bool(forKey: "lumawall.hideDesktopVideo"),
            pausedDisplays: paused,
            powerProfile: UserDefaults.standard.string(forKey: "lumawall.powerProfile")
        )
    }
}
