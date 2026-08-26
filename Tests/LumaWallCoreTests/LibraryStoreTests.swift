import Foundation
import LumaWallCore
import Testing

struct LibraryStoreTests {
    @Test func persistsAndReloadsAssets() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let asset = sampleAsset(hash: "unique")
        let first = try LibraryStore(rootURL: root)
        try await first.install(asset)

        let second = try LibraryStore(rootURL: root)
        #expect(await second.asset(id: asset.id) == asset)
    }

    @Test func rejectsContentDuplicatesWithDifferentNames() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(rootURL: root)
        try await store.install(sampleAsset(hash: "same", name: "First"))

        await #expect(throws: LibraryStore.StoreError.self) {
            try await store.install(sampleAsset(hash: "same", name: "Renamed Copy"))
        }
    }

    private func sampleAsset(hash: String, name: String = "Wallpaper") -> WallpaperAsset {
        WallpaperAsset(
            name: name,
            mediaURL: URL(fileURLWithPath: "/tmp/wallpaper.mov"),
            duration: 12,
            framesPerSecond: 30,
            pixelSize: CGSize(width: 3_840, height: 2_160),
            contentHash: hash,
            containsAudio: false
        )
    }
}
