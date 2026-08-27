import Foundation
import LumaWallCore
import Testing

struct PlaylistPlaybackStoreTests {
    @Test func persistsOrderAndCursorThenClears() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = PlaylistPlaybackState(
            playlistID: PlaylistID(),
            orderedIDs: [WallpaperID(), WallpaperID(), WallpaperID()],
            cursor: 2
        )
        let store = try PlaylistPlaybackStore(rootURL: root)
        try await store.save(state)
        let restored = try PlaylistPlaybackStore(rootURL: root)
        #expect(await restored.current() == state)
        try await restored.clear()
        #expect(await restored.current() == nil)
        let emptyReload = try PlaylistPlaybackStore(rootURL: root)
        #expect(await emptyReload.current() == nil)
    }
}
