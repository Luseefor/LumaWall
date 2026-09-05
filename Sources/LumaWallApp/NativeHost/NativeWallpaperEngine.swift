import Foundation
import LumaWallCore
import os

let nativeHostLog = Logger(subsystem: "app.lumawall.personal", category: "native-host")

@MainActor
final class NativeWallpaperEngine {
    private let displays: DisplayCoordinator
    private let assignments: AssignmentStore
    private var active: [DisplayID: (WallpaperID, DisplayComposition)] = [:]
    private var tiers: [DisplayID: PlaybackTier] = [:]
    private var libraryByID: [WallpaperID: WallpaperAsset] = [:]
    /// Last (cgDisplayID → entryID) map actually written to Index.plist.
    /// Restores that resolve to the identical map skip the plist rewrite +
    /// WallpaperAgent kill — those are what black-flash every display on a
    /// join/cut burst or redundant refresh.
    private var lastWrittenMap: [UInt32: String] = [:]

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
        let entry: NativeWallpaperDeployment.EntryInfo
        do {
            entry = try await NativeWallpaperDeployment.ensureDeployed(asset: asset)
            nativeHostLog.info("apply: deployment ready id=\(entry.id, privacy: .public)")
            try NativeWallpaperAssignmentService.apply(entry: entry, to: [connected.cgDisplayID])
        } catch {
            let cocoa = error as NSError
            nativeHostLog.error("apply: failed domain=\(cocoa.domain, privacy: .public) code=\(cocoa.code) description=\(cocoa.localizedDescription, privacy: .public)")
            throw error
        }
        nativeHostLog.info("apply: \(asset.name, privacy: .public) → display \(displayID.rawValue, privacy: .public)")
        libraryByID[asset.id] = asset
        active[displayID] = (asset.id, composition)
        lastWrittenMap[connected.cgDisplayID] = entry.id
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
        nativeHostLog.info("applyToAll: \(asset.name, privacy: .public) → \(connected.count) display(s)")
        libraryByID[asset.id] = asset
        for display in connected {
            active[display.displayID] = (asset.id, composition)
            lastWrittenMap[display.cgDisplayID] = entry.id
        }
        try await assignments.upsert(connected.map {
            DisplayAssignment(displayID: $0.displayID, wallpaperID: asset.id, composition: composition, isEnabled: true)
        })
    }

    func clear(_ displayID: DisplayID) async throws {
        active.removeValue(forKey: displayID)
        tiers.removeValue(forKey: displayID)
        if let cg = displays.display(id: displayID)?.cgDisplayID {
            lastWrittenMap.removeValue(forKey: cg)
        }
        try await assignments.clear(displayID: displayID)
    }

    func clearAll() async throws {
        active.removeAll()
        tiers.removeAll()
        lastWrittenMap.removeAll()
        try await assignments.clearAll()
    }

    func apply(tier: PlaybackTier, to displayID: DisplayID) {
        tiers[displayID] = tier
    }

    /// Restores persisted assignments through the system host. When the overlay
    /// owns non-default displays (`onlyDefaultCrop`), those assignments are
    /// left for the overlay engine — writing them here would fight it.
    func restore(using library: [WallpaperAsset], onlyDefaultCrop: Bool = false) async {
        let snapshot = await assignments.current()
        let byID = Dictionary(uniqueKeysWithValues: library.map { ($0.id, $0) })
        libraryByID = byID
        let connected = displays.refresh()
        let enabled = snapshot.assignments.filter(\.isEnabled)
        nativeHostLog.info("restore: \(enabled.count) enabled assignment(s), \(connected.count) display(s)")
        var map: [UInt32: NativeWallpaperDeployment.EntryInfo] = [:]
        for assignment in enabled {
            guard let wallpaperID = assignment.wallpaperID, let asset = byID[wallpaperID] else {
                nativeHostLog.error("restore: wallpaper \(assignment.wallpaperID?.rawValue.uuidString ?? "nil", privacy: .public) not in library")
                continue
            }
            if onlyDefaultCrop, (!assignment.composition.usesDefaultCrop
                || assignment.composition.spanningCanvas != nil) {
                continue
            }
            guard let display = connected.first(where: { $0.displayID == assignment.displayID }) else {
                nativeHostLog.error("restore: display \(assignment.displayID.rawValue, privacy: .public) not connected")
                continue
            }
            do {
                let entry = try await NativeWallpaperDeployment.ensureDeployed(asset: asset)
                map[display.cgDisplayID] = entry
                active[assignment.displayID] = (asset.id, assignment.composition)
            } catch {
                nativeHostLog.error("restore: deploy failed for \(asset.name, privacy: .public): \(error, privacy: .public)")
            }
        }
        guard !map.isEmpty else {
            nativeHostLog.info("restore: nothing to assign")
            return
        }
        let fingerprint = map.mapValues(\.id)
        if fingerprint == lastWrittenMap {
            nativeHostLog.info("restore: assignments unchanged — skipping Index.plist rewrite + agent restart")
            return
        }
        do {
            try NativeWallpaperAssignmentService.apply(assignments: map)
            lastWrittenMap = fingerprint
            nativeHostLog.info("restore: assigned \(map.count) display(s)")
        } catch {
            nativeHostLog.error("restore: assignment failed: \(error, privacy: .public)")
        }
    }

    func reapplyAssignments() {
        let library = Array(libraryByID.values)
        guard !library.isEmpty else { return }
        Task { await restore(using: library) }
    }
}
