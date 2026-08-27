import Foundation
import LumaWallCore
import Testing

struct LibraryStoreTests {
    @Test func persistsAndReloadsAssets() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let asset = sampleAsset(hash: "unique", category: .nature)
        let first = try LibraryStore(rootURL: root)
        try await first.install(asset)

        let second = try LibraryStore(rootURL: root)
        let loaded = await second.asset(id: asset.id)
        #expect(loaded?.id == asset.id)
        #expect(loaded?.name == asset.name)
        #expect(loaded?.contentHash == asset.contentHash)
        #expect(loaded?.category == .nature)
        #expect(loaded?.applyCount == 0)
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

    @Test func recordsApplyAndSortsMostUsed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(rootURL: root)
        let a = sampleAsset(hash: "a", name: "A")
        let b = sampleAsset(hash: "b", name: "B")
        try await store.install(a)
        try await store.install(b)
        try await store.recordApply(id: b.id)
        try await store.recordApply(id: b.id)
        try await store.recordApply(id: a.id)
        let sorted = await store.assets(sortedBy: .mostUsed)
        #expect(sorted.first?.id == b.id)
        #expect(sorted.first?.applyCount == 2)
    }

    @Test func migratesLegacyAssetsWithoutCategory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let legacy = """
        [{"id":{"rawValue":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"},"name":"Legacy","mediaURL":"file:///tmp/a.mov","duration":10,"framesPerSecond":30,"pixelSize":[1920,1080],"contentHash":"legacy","containsAudio":false}]
        """
        try Data(legacy.utf8).write(to: root.appendingPathComponent("Library.json"))
        let store = try LibraryStore(rootURL: root)
        let assets = await store.assets()
        #expect(assets.count == 1)
        #expect(assets[0].category == .other)
        #expect(assets[0].applyCount == 0)
    }

    private func sampleAsset(
        hash: String,
        name: String = "Wallpaper",
        category: WallpaperCategory = .other
    ) -> WallpaperAsset {
        WallpaperAsset(
            name: name,
            mediaURL: URL(fileURLWithPath: "/tmp/wallpaper.mov"),
            duration: 12,
            framesPerSecond: 30,
            pixelSize: CGSize(width: 3_840, height: 2_160),
            contentHash: hash,
            containsAudio: false,
            category: category
        )
    }
}

struct RecentsStoreTests {
    @Test func keepsMostRecentFirstAndCapsAtTen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecentsStore(rootURL: root)
        for _ in 0..<12 {
            try await store.push(WallpaperID())
        }
        let ids = await store.all()
        #expect(ids.count == 10)
        let first = ids[0]
        try await store.push(first)
        #expect(await store.all().first == first)
        #expect(await store.all().count == 10)
    }
}
