import AppKit
import CoreGraphics
import Darwin
import IOKit.ps
import LumaWallCore
import Observation
import UniformTypeIdentifiers

extension AppModel {
    func createPlaylist(name: String, from selection: [WallpaperAsset], shuffled: Bool, intervalMinutes: Int) {
        guard !selection.isEmpty else { return }
        beginPlaylistEditor()
        playlistEditor?.name = name
        playlistEditor?.orderedIDs = selection.map(\.id)
        playlistEditor?.shuffled = shuffled
        playlistEditor?.intervalMinutes = max(1, intervalMinutes)
        savePlaylistEditor()
    }

    func beginPlaylistEditor(existing: WallpaperPlaylist? = nil) {
        if let existing {
            playlistEditor = PlaylistEditorState(
                id: existing.id,
                existingID: existing.id,
                name: existing.name,
                orderedIDs: existing.wallpaperIDs,
                shuffled: existing.shuffled,
                intervalMinutes: existing.intervalMinutes
            )
        } else {
            let id = PlaylistID()
            playlistEditor = PlaylistEditorState(
                id: id,
                existingID: nil,
                name: "",
                orderedIDs: [],
                shuffled: false,
                intervalMinutes: 30
            )
        }
    }

    func toggleEditorEntry(_ asset: WallpaperAsset) {
        guard var draft = playlistEditor else { return }
        if let index = draft.orderedIDs.firstIndex(of: asset.id) {
            draft.orderedIDs.remove(at: index)
        } else {
            draft.orderedIDs.append(asset.id)
        }
        playlistEditor = draft
    }

    func moveEditorEntry(from source: Int, to destination: Int) {
        guard var draft = playlistEditor, draft.orderedIDs.indices.contains(source) else { return }
        let id = draft.orderedIDs.remove(at: source)
        draft.orderedIDs.insert(id, at: min(destination, draft.orderedIDs.count))
        playlistEditor = draft
    }

    /// Explicit copy-writeback setters for the editor draft. Direct optional-chain
    /// mutation (`playlistEditor?.name = …`) is fragile under `@Observable`
    /// tracking; these mirror `toggleEditorEntry`'s proven pattern.
    func setPlaylistEditorName(_ name: String) {
        guard var draft = playlistEditor else { return }
        draft.name = name
        playlistEditor = draft
    }

    func setPlaylistEditorInterval(_ minutes: Int) {
        guard var draft = playlistEditor else { return }
        draft.intervalMinutes = minutes
        playlistEditor = draft
    }

    func setPlaylistEditorShuffled(_ shuffled: Bool) {
        guard var draft = playlistEditor else { return }
        draft.shuffled = shuffled
        playlistEditor = draft
    }

    func savePlaylistEditor() {
        guard let draft = playlistEditor, !draft.orderedIDs.isEmpty else { return }
        Task {
            let playlist = WallpaperPlaylist(
                id: draft.existingID ?? draft.id,
                name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "Playlist \(playlists.count + 1)"
                    : draft.name,
                wallpaperIDs: draft.orderedIDs,
                shuffled: draft.shuffled,
                intervalMinutes: max(1, draft.intervalMinutes)
            )
            try? await playlistStore.upsert(playlist)
            playlists = await playlistStore.all()
            playlistEditor = nil
        }
    }

    func deletePlaylist(_ playlist: WallpaperPlaylist) {
        if activePlaylistID == playlist.id { stopPlaylistRotation() }
        Task {
            try? await playlistStore.remove(id: playlist.id)
            playlists = await playlistStore.all()
        }
    }

    func applyPlaylist(_ playlist: WallpaperPlaylist) {
        let ids = playlist.shuffled ? playlist.wallpaperIDs.shuffled() : playlist.wallpaperIDs
        guard let firstID = ids.first,
              let asset = assets.first(where: { $0.id == firstID }) else { return }
        automations.dayNightEnabled = false
        automations.appearanceEnabled = false
        persistAutomations()
        activePlaylistID = playlist.id
        playlistIDs = ids
        playlistCursor = 0
        applyToAll(asset, continuingPlaylist: true)
        startPlaylistRotation(ids: ids, intervalMinutes: playlist.intervalMinutes)
    }

    func stepPlaylist(_ delta: Int) {
        guard !playlistIDs.isEmpty else { return }
        playlistCursor = (playlistCursor + delta + playlistIDs.count) % playlistIDs.count
        persistPlaylistPlaybackState()
        let nextID = playlistIDs[playlistCursor]
        guard let asset = assets.first(where: { $0.id == nextID }) else { return }
        applyToAll(asset, continuingPlaylist: true)
    }

    func stopPlaylistRotation() {
        playlistTimer?.invalidate()
        playlistTimer = nil
        activePlaylistID = nil
        playlistIDs = []
        playlistNextAdvanceAt = nil
        Task { try? await playlistPlaybackStore.clear() }
    }


    func startPlaylistRotation(
        ids: [WallpaperID],
        intervalMinutes: Int,
        nextAdvanceAt: Date? = nil
    ) {
        playlistIDs = ids
        playlistTimer?.invalidate()
        let seconds = TimeInterval(max(1, intervalMinutes) * 60)
        let fireDate = max(nextAdvanceAt ?? Date().addingTimeInterval(seconds), Date().addingTimeInterval(0.25))
        playlistNextAdvanceAt = fireDate
        let timer = Timer(fire: fireDate, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, let playlistID = self.activePlaylistID,
                      let playlist = self.playlists.first(where: { $0.id == playlistID }) else { return }
                self.stepPlaylist(1)
                self.startPlaylistRotation(ids: self.playlistIDs, intervalMinutes: playlist.intervalMinutes)
            }
        }
        timer.tolerance = min(2, seconds * 0.02)
        RunLoop.main.add(timer, forMode: .common)
        playlistTimer = timer
        persistPlaylistPlaybackState()
    }

    private func persistPlaylistPlaybackState() {
        guard let activePlaylistID else { return }
        let state = PlaylistPlaybackState(
            playlistID: activePlaylistID,
            orderedIDs: playlistIDs,
            cursor: playlistCursor,
            nextAdvanceAt: playlistNextAdvanceAt
        )
        Task { try? await playlistPlaybackStore.save(state) }
    }

    func restorePlaylistPlaybackState() async {
        guard let saved = await playlistPlaybackStore.current(),
              let playlist = playlists.first(where: { $0.id == saved.playlistID }) else {
            try? await playlistPlaybackStore.clear()
            return
        }
        let ids = Set(saved.orderedIDs) == Set(playlist.wallpaperIDs)
            ? saved.orderedIDs
            : (playlist.shuffled ? playlist.wallpaperIDs.shuffled() : playlist.wallpaperIDs)
        guard !ids.isEmpty else {
            try? await playlistPlaybackStore.clear()
            return
        }
        activePlaylistID = playlist.id
        playlistIDs = ids
        playlistCursor = min(max(saved.cursor, 0), ids.count - 1)
        guard let schedule = PlaylistSchedule.resume(
            nextAdvanceAt: saved.nextAdvanceAt,
            intervalMinutes: playlist.intervalMinutes,
            cursor: playlistCursor,
            itemCount: ids.count
        ) else { return }
        playlistCursor = schedule.cursor
        if playlistCursor != saved.cursor,
           let asset = assets.first(where: { $0.id == ids[playlistCursor] }) {
            try? await engine.applyToAll(asset)
        }
        startPlaylistRotation(
            ids: ids,
            intervalMinutes: playlist.intervalMinutes,
            nextAdvanceAt: schedule.nextAdvanceAt
        )
    }

    func displaysUsing(_ asset: WallpaperAsset) -> [ConnectedDisplay] {
        displays.filter { activeByDisplay[$0.displayID] == asset.id }
    }

    func asset(for id: WallpaperID?) -> WallpaperAsset? {
        guard let id else { return nil }
        return assets.first { $0.id == id }
    }
}
