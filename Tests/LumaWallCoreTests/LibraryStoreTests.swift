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

    @Test func updateRenameAndCategoryPersist() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(rootURL: root)
        let asset = sampleAsset(hash: "mutable")
        try await store.install(asset)

        var renamed = asset
        renamed.name = "Changed"
        try await store.update(renamed)
        try await store.rename(id: asset.id, to: "  Trimmed  ")
        try await store.setCategory(id: asset.id, category: .space)

        let loaded = await store.asset(id: asset.id)
        #expect(loaded?.name == "Trimmed")
        #expect(loaded?.category == .space)
    }

    @Test func missingAssetOperationsThrow() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(rootURL: root)
        let ghost = WallpaperID()
        await #expect(throws: LibraryStore.StoreError.self) {
            try await store.update(sampleAsset(hash: "ghost"))
        }
        await #expect(throws: LibraryStore.StoreError.self) {
            try await store.rename(id: ghost, to: "x")
        }
        await #expect(throws: LibraryStore.StoreError.self) {
            try await store.setCategory(id: ghost, category: .nature)
        }
        await #expect(throws: LibraryStore.StoreError.self) {
            try await store.recordApply(id: ghost)
        }
        await #expect(throws: LibraryStore.StoreError.self) {
            try await store.remove(id: ghost)
        }
    }

    @Test func removeDeletesAssetFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(rootURL: root)
        let id = WallpaperID()
        let folder = root.appendingPathComponent(id.rawValue.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let asset = WallpaperAsset(
            id: id,
            name: "Doomed",
            mediaURL: folder.appendingPathComponent("wallpaper.mov"),
            duration: 5,
            framesPerSecond: 30,
            pixelSize: CGSize(width: 1920, height: 1080),
            contentHash: "doomed",
            containsAudio: false
        )
        try await store.install(asset)
        #expect(await store.folder(for: id) == folder)

        try await store.remove(id: id)
        #expect(await store.asset(id: id) == nil)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func lookupByContentHashAndErrorText() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(rootURL: root)
        try await store.install(sampleAsset(hash: "find-me", name: "Findable"))
        #expect(await store.asset(contentHash: "find-me")?.name == "Findable")
        #expect(await store.asset(contentHash: "absent") == nil)
        #expect(LibraryStore.StoreError.missingAsset.errorDescription == "The wallpaper is no longer installed.")
        #expect(
            LibraryStore.StoreError.duplicate(sampleAsset(hash: "x", name: "Dup")).errorDescription?
                .contains("Dup") == true
        )
    }

    @Test func sortsByNameResolutionAndAge() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(rootURL: root)
        var small = sampleAsset(hash: "small", name: "banana")
        small.pixelSize = CGSize(width: 1280, height: 720)
        small.createdAt = Date(timeIntervalSince1970: 100)
        var big = sampleAsset(hash: "big", name: "Apple")
        big.pixelSize = CGSize(width: 3840, height: 2160)
        big.createdAt = Date(timeIntervalSince1970: 200)
        try await store.install(small)
        try await store.install(big)

        #expect(await store.assets(sortedBy: .name).map(\.name) == ["Apple", "banana"])
        #expect(await store.assets(sortedBy: .resolution).first?.contentHash == "big")
        #expect(await store.assets(sortedBy: .oldest).first?.contentHash == "small")
        #expect(await store.assets(sortedBy: .newest).first?.contentHash == "big")
    }

    @Test func diskUsageCountsLibraryFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(rootURL: root)
        try await store.install(sampleAsset(hash: "weighed"))
        let blob = root.appendingPathComponent("blob.bin")
        try Data(repeating: 7, count: 4096).write(to: blob)
        #expect(await store.diskUsageBytes() >= 4096)
    }

    @Test func diskUsageIsCachedUntilTheLibraryChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(rootURL: root)
        try await store.install(sampleAsset(hash: "first"))
        let first = await store.diskUsageBytes()
        try Data(repeating: 1, count: 8192).write(to: root.appendingPathComponent("late.bin"))
        // No library change since the last measurement: no new folder walk.
        #expect(await store.diskUsageBytes() == first)
        try await store.install(sampleAsset(hash: "second"))
        #expect(await store.diskUsageBytes() >= first + 8192)
    }

    @Test func diskUsageSeesIndexRewritesFromRenameAndApply() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(rootURL: root)
        let asset = sampleAsset(hash: "renamed")
        try await store.install(asset)
        let before = await store.diskUsageBytes()
        try await store.rename(id: asset.id, to: String(repeating: "n", count: 20_000))
        #expect(await store.diskUsageBytes() >= before + 19_000)
    }

    @Test func removeRefusesPathsOutsideEntryFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Bystander file outside any entry folder; a corrupt mediaURL must
        // never cause its deletion.
        let outside = root.appendingPathComponent("precious.mov")
        try Data(repeating: 1, count: 8).write(to: outside)
        let siblingID = WallpaperID()
        let siblingFolder = root.appendingPathComponent(siblingID.rawValue.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: siblingFolder, withIntermediateDirectories: true)

        func asset(id: WallpaperID, hash: String, mediaURL: URL) -> WallpaperAsset {
            WallpaperAsset(
                id: id, name: "x", mediaURL: mediaURL, duration: 1,
                framesPerSecond: 30, pixelSize: CGSize(width: 640, height: 480),
                contentHash: hash, containsAudio: false
            )
        }
        let store = try LibraryStore(rootURL: root)
        let escapeID = WallpaperID()
        try await store.install(asset(id: escapeID, hash: "stray", mediaURL: outside))
        let sibling = asset(id: siblingID, hash: "sibling", mediaURL: siblingFolder.appendingPathComponent("w.mov"))
        try await store.install(sibling)

        // Points outside the library root: index entry goes, file survives.
        await #expect(throws: LibraryStore.StoreError.invalidLocation) {
            try await store.remove(id: escapeID)
        }
        #expect(await store.asset(id: escapeID) == nil)
        #expect(FileManager.default.fileExists(atPath: outside.path))

        // Points at a sibling entry's folder: also refused.
        let hijackID = WallpaperID()
        try await store.install(
            asset(
                id: hijackID, hash: "hijacker",
                mediaURL: siblingFolder.appendingPathComponent("w.mov")
            ))
        await #expect(throws: LibraryStore.StoreError.invalidLocation) {
            try await store.remove(id: hijackID)
        }
        #expect(FileManager.default.fileExists(atPath: siblingFolder.path))
        #expect(
            LibraryStore.StoreError.invalidLocation.errorDescription?
                .contains("outside the library") == true)
    }

    @Test func removeThroughASymlinkedEntryFolderKeepsTheTarget() async throws {
        // An entry folder swapped for a symlink resolved to the same path as
        // the media URL, so remove deleted whatever the link pointed at.
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: base) }
        let root = base.appendingPathComponent("lib", isDirectory: true)
        let victim = base.appendingPathComponent("Documents", isDirectory: true)
        try fm.createDirectory(at: victim, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: victim.appendingPathComponent("thesis.pages"))
        let store = try LibraryStore(rootURL: root)
        let id = WallpaperID()
        let folder = await store.folder(for: id)
        try await store.install(LibraryStore.entryAsset(id: id, folder: folder, hash: "linked"))
        try fm.createSymbolicLink(at: folder, withDestinationURL: victim)

        try await store.remove(id: id)
        #expect(await store.asset(id: id) == nil)
        #expect(fm.fileExists(atPath: victim.appendingPathComponent("thesis.pages").path))
        #expect((try? fm.destinationOfSymbolicLink(atPath: folder.path)) == nil)
    }

    @Test func removeKeepsTheIndexEntryWhenTheFolderCannotBeDeleted() async throws {
        // The index entry went first, so a failed delete left the files with
        // nothing pointing at them.
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            try? fm.removeItem(at: root)
        }
        let store = try LibraryStore(rootURL: root)
        let id = WallpaperID()
        let folder = await store.folder(for: id)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: folder.appendingPathComponent("wallpaper.mov"))
        try await store.install(LibraryStore.entryAsset(id: id, folder: folder, hash: "stuck"))
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }

        await #expect(throws: (any Error).self) { try await store.remove(id: id) }
        #expect(await store.asset(id: id) != nil)
        #expect(await LibraryStore.reopenedHasAsset(root: root, id: id))
    }

    @Test func removeCanBeRetriedWhenTheIndexWriteFails() async throws {
        // The row left memory before the index write, so a failed write
        // made a retry report missingAsset while Library.json kept the row.
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let store = try LibraryStore(rootURL: root)
        let id = WallpaperID()
        let folder = await store.folder(for: id)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try await store.install(LibraryStore.entryAsset(id: id, folder: folder, hash: "retry"))
        let index = root.appendingPathComponent("Library.json")
        try fm.removeItem(at: index)
        try fm.createDirectory(at: index.appendingPathComponent("blocker"), withIntermediateDirectories: true)

        await #expect(throws: (any Error).self) { try await store.remove(id: id) }
        #expect(await store.asset(id: id) != nil)
        try fm.removeItem(at: index)
        try await store.remove(id: id)
        #expect(await store.asset(id: id) == nil)
        #expect(!fm.fileExists(atPath: folder.path))
    }

    @Test func removeAcceptsALowercaseFolderName() async throws {
        // A URL spelling the UUID in lower case names the same folder on a
        // case-insensitive volume; it was rejected and the files kept.
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let store = try LibraryStore(rootURL: root)
        let id = WallpaperID()
        let lower = root.appendingPathComponent(id.rawValue.uuidString.lowercased(), isDirectory: true)
        try fm.createDirectory(at: lower, withIntermediateDirectories: true)
        try await store.install(LibraryStore.entryAsset(id: id, folder: lower, hash: "lower"))

        try await store.remove(id: id)
        #expect(try fm.contentsOfDirectory(atPath: root.path) == ["Library.json"])
    }

    @Test func duplicateIDsInTheIndexAreTreatedAsCorrupt() async throws {
        // Dictionary(uniqueKeysWithValues:) trapped on a repeated ID.
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let entry = """
            {"id":{"rawValue":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"},"name":"Twin","mediaURL":"file:///tmp/a.mov","duration":10,"framesPerSecond":30,"pixelSize":[1920,1080],"contentHash":"twin","containsAudio":false}
            """
        try Data("[\(entry),\(entry)]".utf8).write(to: root.appendingPathComponent("Library.json"))

        let store = try LibraryStore(rootURL: root)
        #expect(await store.assets().isEmpty)
        let leftovers = try fm.contentsOfDirectory(atPath: root.path)
        #expect(leftovers.contains { $0.hasPrefix("Library.json.corrupt-") })
    }

    @Test func corruptLibraryIsQuarantinedNotSilentlyReset() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "not-json{{".write(
            to: root.appendingPathComponent("Library.json"), atomically: true, encoding: .utf8
        )

        let store = try LibraryStore(rootURL: root)
        #expect(await store.assets().isEmpty)
        let leftovers = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        #expect(leftovers.contains { $0.lastPathComponent.hasPrefix("Library.json.corrupt-") })
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Library.json").path))
    }

    @Test func mostUsedBreaksTiesByRecency() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(rootURL: root)
        let older = sampleAsset(hash: "older", name: "Older")
        let newer = sampleAsset(hash: "newer", name: "Newer")
        try await store.install(older)
        try await store.install(newer)
        // Equal apply counts: the more recently applied asset must win.
        try await store.recordApply(id: older.id, at: Date(timeIntervalSince1970: 1_000))
        try await store.recordApply(id: newer.id, at: Date(timeIntervalSince1970: 2_000))
        #expect(await store.assets(sortedBy: .mostUsed).map(\.contentHash) == ["newer", "older"])
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

extension LibraryStore {
    fileprivate static func entryAsset(id: WallpaperID, folder: URL, hash: String) -> WallpaperAsset {
        WallpaperAsset(
            id: id, name: "Entry", mediaURL: folder.appendingPathComponent("wallpaper.mov"), duration: 5,
            framesPerSecond: 30, pixelSize: CGSize(width: 1920, height: 1080), contentHash: hash, containsAudio: false)
    }

    fileprivate static func reopenedHasAsset(root: URL, id: WallpaperID) async -> Bool {
        guard let store = try? LibraryStore(rootURL: root) else { return false }
        return await store.asset(id: id) != nil
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

    @Test func removeAndClearDropEntries() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecentsStore(rootURL: root)
        let a = WallpaperID()
        let b = WallpaperID()
        try await store.push(a)
        try await store.push(b)
        try await store.remove(a)
        #expect(await store.all() == [b])
        try await store.clear()
        #expect(await store.all().isEmpty)

        // Clearing persists: a reopened store stays empty.
        let reopened = try RecentsStore(rootURL: root)
        #expect(await reopened.all().isEmpty)
    }
}
