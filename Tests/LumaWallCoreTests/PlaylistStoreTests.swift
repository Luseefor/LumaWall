import Foundation
import LumaWallCore
import Testing

/// PlaylistStore had zero coverage. All cases use an isolated temp directory —
/// never production data — and each test is independently runnable.
struct PlaylistStoreTests {
    @Test func upsertedPlaylistsListNewestFirst() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try PlaylistStore(rootURL: root)
        let older = WallpaperPlaylist(name: "Older", createdAt: Date(timeIntervalSince1970: 1_000))
        let newer = WallpaperPlaylist(name: "Newer", createdAt: Date(timeIntervalSince1970: 2_000))
        try await store.upsert(older)
        try await store.upsert(newer)

        let all = await store.all()
        #expect(all.map(\.id) == [newer.id, older.id])
    }

    @Test func upsertOverwritesSameID() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try PlaylistStore(rootURL: root)
        let id = PlaylistID()
        try await store.upsert(WallpaperPlaylist(id: id, name: "First"))
        try await store.upsert(WallpaperPlaylist(id: id, name: "Second"))

        let all = await store.all()
        #expect(all.count == 1)
        #expect(all.first?.name == "Second")
    }

    @Test func removeDropsOnlyTarget() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try PlaylistStore(rootURL: root)
        let keep = WallpaperPlaylist(name: "Keep")
        let drop = WallpaperPlaylist(name: "Drop")
        try await store.upsert(keep)
        try await store.upsert(drop)
        try await store.remove(id: drop.id)

        let all = await store.all()
        #expect(all.map(\.id) == [keep.id])
    }

    @Test func playlistsPersistAcrossRelaunch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let playlist = WallpaperPlaylist(
            name: "Rotation",
            wallpaperIDs: [WallpaperID(), WallpaperID()],
            shuffled: true,
            intervalMinutes: 15
        )
        let first = try PlaylistStore(rootURL: root)
        try await first.upsert(playlist)

        let second = try PlaylistStore(rootURL: root)
        let loaded = await second.all()
        #expect(loaded.count == 1)
        #expect(loaded.first?.name == "Rotation")
        #expect(loaded.first?.wallpaperIDs == playlist.wallpaperIDs)
        #expect(loaded.first?.shuffled == true)
        #expect(loaded.first?.intervalMinutes == 15)
    }

    @Test func playlistIDRoundTripsThroughRawValue() {
        let uuid = UUID()
        #expect(PlaylistID(rawValue: uuid).rawValue == uuid)
        #expect(PlaylistID(rawValue: uuid).id == uuid)
    }
}
