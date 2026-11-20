import CoreGraphics
import Foundation
import LumaWallCore
import os

let nativeHostLog = Logger(subsystem: "app.lumawall.personal", category: "native-host")

/// What a log line may show of an error in public: its domain and code.
/// Descriptions can name files and folders, so log them `.private`.
enum LogRedaction {
    static func code(of error: any Error) -> String {
        let ns = error as NSError
        return "domain=\(ns.domain) code=\(ns.code)"
    }
}

@MainActor
final class NativeWallpaperEngine {
    private let displays: DisplayCoordinator
    private let assignments: AssignmentStore
    private var active: [DisplayID: (WallpaperID, DisplayComposition)] = [:]
    private var tiers: [DisplayID: PlaybackTier] = [:]
    private var libraryByID: [WallpaperID: WallpaperAsset] = [:]
    /// Last (stable display UUID → entryID) map actually written to Index.plist.
    /// Restores that resolve to the identical map skip the plist rewrite +
    /// WallpaperAgent kill. Those restarts black-flash every display on a
    /// join/cut burst or redundant refresh.
    ///
    /// Keyed by the CG display UUID, NOT the CGDirectDisplayID: numeric IDs
    /// shift when monitors join/leave (and get reused), so a cg-keyed map can
    /// compare equal after a topology change and skip a rewrite the new
    /// topology actually needs.
    private var lastWrittenMap: [String: String] = [:]
    /// Set when native mode turns off. Work already running stops before its
    /// next copy or store write.
    private var isDetached = false

    private func stableUUID(for cgDisplayID: CGDirectDisplayID) -> String? {
        NativeWallpaperAssignmentService.stableUUID(for: cgDisplayID)
    }

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
            entry = try await NativeWallpaperDeployment.ensureDeployed(
                asset: asset, surfaces: surfaces(showing: asset.id, plus: [connected]))
            nativeHostLog.info("apply: deployment ready id=\(entry.id, privacy: .public)")
            guard !isDetached else { throw NativeWallpaperAssignmentService.AssignmentError.nativeModeOff }
            try NativeWallpaperAssignmentService.apply(entry: entry, to: [connected.cgDisplayID])
        } catch {
            let cocoa = error as NSError
            nativeHostLog.error(
                "apply: failed domain=\(cocoa.domain, privacy: .public) code=\(cocoa.code) description=\(cocoa.localizedDescription, privacy: .private)"
            )
            throw error
        }
        nativeHostLog.info("apply: \(asset.id.rawValue.uuidString, privacy: .public) → display \(displayID.rawValue, privacy: .public)")
        libraryByID[asset.id] = asset
        let replaced = active[displayID]?.0
        active[displayID] = (asset.id, composition)
        if let replaced, replaced != asset.id { reportSurfaces(of: replaced) }
        if let uuid = stableUUID(for: connected.cgDisplayID) {
            lastWrittenMap[uuid] = entry.id
        }
        try await assignments.upsert(
            DisplayAssignment(displayID: displayID, wallpaperID: asset.id, composition: composition, isEnabled: true)
        )
        apply(tier: tiers[displayID] ?? .full, to: displayID)
    }

    /// Applies to every connected display except `excluded`, which the
    /// overlay plays. Returns the displays the system store had no entry for,
    /// for the caller to hand to the overlay.
    @discardableResult
    func applyToAll(
        _ asset: WallpaperAsset, composition: DisplayComposition = .init(), excluding excluded: Set<DisplayID> = []
    ) async throws -> Set<DisplayID> {
        let all = displays.refresh().filter { !excluded.contains($0.displayID) }
        guard !all.isEmpty else { throw OverlayWallpaperEngine.EngineError.missingDisplay }
        let entry = try await NativeWallpaperDeployment.ensureDeployed(asset: asset, surfaces: all.map(surface(on:)))
        guard !isDetached else { throw NativeWallpaperAssignmentService.AssignmentError.nativeModeOff }
        let unassigned = try NativeWallpaperAssignmentService.apply(
            entry: entry,
            to: Set(all.map(\.cgDisplayID))
        )
        let connected = all.filter { !unassigned.contains($0.cgDisplayID) }
        let previous = Set(active.values.map(\.0))
        defer { reportSurfaces(ofAll: previous) }
        nativeHostLog.info("applyToAll: \(asset.id.rawValue.uuidString, privacy: .public) → \(connected.count) display(s)")
        libraryByID[asset.id] = asset
        for display in connected {
            active[display.displayID] = (asset.id, composition)
            if let uuid = stableUUID(for: display.cgDisplayID) {
                lastWrittenMap[uuid] = entry.id
            }
        }
        try await assignments.upsert(
            connected.map {
                DisplayAssignment(displayID: $0.displayID, wallpaperID: asset.id, composition: composition, isEnabled: true)
            })
        return Set(all.filter { unassigned.contains($0.cgDisplayID) }.map(\.displayID))
    }

    func clear(_ displayID: DisplayID) async throws {
        if let removed = active.removeValue(forKey: displayID)?.0 { reportSurfaces(of: removed) }
        tiers.removeValue(forKey: displayID)
        if let cg = displays.display(id: displayID)?.cgDisplayID,
            let uuid = stableUUID(for: cg)
        {
            lastWrittenMap.removeValue(forKey: uuid)
        }
        try await assignments.clear(displayID: displayID)
    }

    func clearAll() async throws {
        let removed = Set(active.values.map(\.0))
        active.removeAll()
        reportSurfaces(ofAll: removed)
        tiers.removeAll()
        lastWrittenMap.removeAll()
        try await assignments.clearAll()
    }

    func apply(tier: PlaybackTier, to displayID: DisplayID) {
        tiers[displayID] = tier
        if let wallpaperID = active[displayID]?.0 { reportSurfaces(of: wallpaperID) }
    }

    private func surface(on display: ConnectedDisplay) -> NativeWallpaperDeployment.Surface {
        .init(pixelSize: display.pixelSize, tier: tiers[display.displayID] ?? .full)
    }

    /// The displays showing `wallpaperID`, plus `extra` it is about to go on.
    private func surfaces(showing wallpaperID: WallpaperID, plus extra: [ConnectedDisplay] = []) -> [NativeWallpaperDeployment.Surface] {
        let showing = displays.displays.filter { active[$0.displayID]?.0 == wallpaperID }
        let extraIDs = Set(extra.map(\.displayID))
        return (showing.filter { !extraIDs.contains($0.displayID) } + extra).map(surface(on:))
    }

    /// Reports every wallpaper in `previous` or showing now, so one that
    /// lost all its displays reports none and its 1440p job is dropped.
    private func reportSurfaces(ofAll previous: Set<WallpaperID>) {
        previous.union(active.values.map(\.0)).forEach(reportSurfaces(of:))
    }

    /// Tells the copy queue where a wallpaper plays and at which tiers.
    private func reportSurfaces(of wallpaperID: WallpaperID) {
        NativeWallpaperDeployment.playbackChanged(entryID: wallpaperID.rawValue.uuidString, surfaces: surfaces(showing: wallpaperID))
    }

    /// Restores persisted assignments through the system host. When the overlay
    /// owns non-default displays (`onlyDefaultCrop`), those assignments are
    /// left for the overlay engine. Writing them here would fight it. So are
    /// the `skipping` displays, where native mode already failed.
    ///
    /// Returns the displays whose copy or assignment failed, for the caller to
    /// hand to the overlay. Permission errors are thrown instead.
    @discardableResult
    func restore(
        using library: [WallpaperAsset], onlyDefaultCrop: Bool = false, skipping: Set<DisplayID> = []
    ) async throws -> Set<DisplayID> {
        let connected = displays.refresh()
        let connectedIDs = Set(connected.map(\.displayID))
        let connectedUUIDs = Set(connected.compactMap { stableUUID(for: $0.cgDisplayID) })
        let previous = Set(active.values.map(\.0))
        defer { reportSurfaces(ofAll: previous) }
        // Drop bookkeeping for removed displays so stale entries can't make
        // the restore look like a no-op (or leak ghost wallpapers into the UI).
        for id in Array(active.keys) where !connectedIDs.contains(id) {
            active.removeValue(forKey: id)
            tiers.removeValue(forKey: id)
        }
        lastWrittenMap = lastWrittenMap.filter { uuid, _ in
            connectedUUIDs.contains(uuid)
        }
        var snapshot = await assignments.current()
        // A newly attached display has no stored assignment yet. Inherit the
        // main display's wallpaper so it joins the current setup instead of
        // keeping whatever macOS put there.
        let inherited = DisplayTopology.inheritedAssignments(
            stored: snapshot.assignments,
            connectedIDs: connectedIDs,
            mainDisplayID: displays.mainDisplay()?.displayID
        )
        if !inherited.isEmpty {
            try? await assignments.upsert(inherited)
            snapshot = await assignments.current()
        }
        let byID = Dictionary(uniqueKeysWithValues: library.map { ($0.id, $0) })
        libraryByID = byID
        let enabled = snapshot.assignments.filter(\.isEnabled)
        nativeHostLog.info("restore: \(enabled.count) enabled assignment(s), \(connected.count) display(s)")
        var map: [UInt32: NativeWallpaperDeployment.EntryInfo] = [:]
        let skipped: (DisplayAssignment) -> Bool = {
            Self.leavesToOverlay($0, onlyDefaultCrop: onlyDefaultCrop) || skipping.contains($0.displayID)
        }
        var failed = Set<DisplayID>()
        // A display that moved to a cropped or spanning overlay no longer
        // plays natively. Leaving its old entry in `active` would tell the
        // copy queue a wallpaper still shows there.
        for displayID in Self.overlayOwnedDisplays(in: enabled, onlyDefaultCrop: onlyDefaultCrop).union(skipping) {
            active.removeValue(forKey: displayID)
        }
        // Each wallpaper's copies are planned for the displays it goes on.
        var targets: [WallpaperID: [ConnectedDisplay]] = [:]
        for assignment in enabled where !skipped(assignment) {
            if let wallpaperID = assignment.wallpaperID,
                let display = connected.first(where: { $0.displayID == assignment.displayID })
            {
                targets[wallpaperID, default: []].append(display)
            }
        }
        for assignment in enabled {
            guard let wallpaperID = assignment.wallpaperID, let asset = byID[wallpaperID] else {
                nativeHostLog.error(
                    "restore: wallpaper \(assignment.wallpaperID?.rawValue.uuidString ?? "nil", privacy: .public) not in library")
                continue
            }
            if skipped(assignment) { continue }
            guard let display = connected.first(where: { $0.displayID == assignment.displayID }) else {
                nativeHostLog.error("restore: display \(assignment.displayID.rawValue, privacy: .public) not connected")
                continue
            }
            guard !isDetached else { return failed }
            do {
                let surfaces = (targets[wallpaperID] ?? [display]).map(surface(on:))
                let entry = try await NativeWallpaperDeployment.ensureDeployed(asset: asset, surfaces: surfaces)
                map[display.cgDisplayID] = entry
                active[assignment.displayID] = (asset.id, assignment.composition)
            } catch NativeWallpaperDeployment.DeploymentError.removed {
                // Removed while it deployed: nothing to play here, and not
                // native mode's failure, so the overlay doesn't take it.
                continue
            } catch {
                if WallpaperHostCapabilities.isPermissionError(error) { throw error }
                nativeHostLog.error(
                    "restore: deploy failed for \(asset.id.rawValue.uuidString, privacy: .public): \(LogRedaction.code(of: error), privacy: .public) \(error.localizedDescription, privacy: .private)"
                )
                failed.insert(assignment.displayID)
            }
        }
        // A wallpaper removed while the loop above waited on another deploy
        // must not be written back. Nothing from here to the write suspends,
        // so a removal can't land in between.
        let batch = Self.withoutRemoved(map, removed: NativeWallpaperDeployment.removedEntries)
        for display in connected where batch.dropped.contains(display.cgDisplayID) {
            // Unless something applied meanwhile put another wallpaper there.
            if active[display.displayID]?.0.rawValue.uuidString == map[display.cgDisplayID]?.id {
                active.removeValue(forKey: display.displayID)
            }
        }
        map = batch.map
        guard !map.isEmpty else {
            nativeHostLog.info("restore: nothing to assign")
            return failed
        }
        // The store is keyed by stable UUID; a display without one can't be
        // assigned and goes to the overlay.
        for (cg, _) in map where stableUUID(for: cg) == nil {
            map.removeValue(forKey: cg)
            if let display = connected.first(where: { $0.cgDisplayID == cg }) {
                failed.insert(display.displayID)
                active.removeValue(forKey: display.displayID)
            }
        }
        guard !map.isEmpty else { return failed }
        let fingerprint = Dictionary(
            uniqueKeysWithValues: map.compactMap { cg, entry in
                stableUUID(for: cg).map { ($0, entry.id) }
            }
        )
        if fingerprint == lastWrittenMap {
            nativeHostLog.info("restore: assignments unchanged, skipping Index.plist rewrite + agent restart")
            return failed
        }
        guard !isDetached else { return failed }
        do {
            let unassigned = try NativeWallpaperAssignmentService.apply(assignments: map)
            lastWrittenMap = fingerprint.filter { uuid, _ in
                !unassigned.contains { stableUUID(for: $0) == uuid }
            }
            let missing = connected.filter { unassigned.contains($0.cgDisplayID) }.map(\.displayID)
            for displayID in missing { active.removeValue(forKey: displayID) }
            failed.formUnion(missing)
            nativeHostLog.info("restore: assigned \(map.count - unassigned.count) display(s)")
        } catch {
            if WallpaperHostCapabilities.isPermissionError(error) { throw error }
            nativeHostLog.error(
                "restore: assignment failed: \(LogRedaction.code(of: error), privacy: .public) \(error.localizedDescription, privacy: .private)"
            )
            let assigned = Set(map.keys)
            failed.formUnion(connected.filter { assigned.contains($0.cgDisplayID) }.map(\.displayID))
            for displayID in failed { active.removeValue(forKey: displayID) }
        }
        return failed
    }

    /// `map` without the entries in `removed`, and the displays they were
    /// for. A dropped display isn't a failure to hand to the overlay: its
    /// wallpaper is gone.
    nonisolated static func withoutRemoved(
        _ map: [UInt32: NativeWallpaperDeployment.EntryInfo], removed: Set<String>
    ) -> (map: [UInt32: NativeWallpaperDeployment.EntryInfo], dropped: Set<UInt32>) {
        let kept = map.filter { !removed.contains($0.value.id) }
        return (kept, Set(map.keys).subtracting(kept.keys))
    }

    /// True when the overlay engine owns this assignment, so a native restore
    /// leaves it alone (`onlyDefaultCrop`).
    nonisolated static func leavesToOverlay(_ assignment: DisplayAssignment, onlyDefaultCrop: Bool) -> Bool {
        onlyDefaultCrop && (!assignment.composition.usesDefaultCrop || assignment.composition.spanningCanvas != nil)
    }

    /// The displays whose enabled assignment the overlay owns.
    nonisolated static func overlayOwnedDisplays(in assignments: [DisplayAssignment], onlyDefaultCrop: Bool) -> Set<DisplayID> {
        Set(assignments.filter { $0.isEnabled && leavesToOverlay($0, onlyDefaultCrop: onlyDefaultCrop) }.map(\.displayID))
    }

    /// Forgets what plays natively without touching stored assignments, so
    /// the copy queue drops this host's jobs when native mode turns off.
    func detach() {
        isDetached = true
        let previous = Set(active.values.map(\.0))
        active.removeAll()
        lastWrittenMap.removeAll()
        reportSurfaces(ofAll: previous)
    }

    func reapplyAssignments() {
        let library = Array(libraryByID.values)
        guard !library.isEmpty else { return }
        Task { try? await restore(using: library) }
    }
}
