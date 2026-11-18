import Foundation
import XCTest
@testable import LumaWall

/// Counts calls to a stand-in hasher.
private final class HashCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }
    func hash(_ url: URL) throws -> String {
        lock.withLock { count += 1 }
        return "hash-of-" + (try String(contentsOf: url, encoding: .utf8))
    }
}

final class ContentHashStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @MainActor
    func testUnchangedFileIsNotRehashedAfterRelaunch() async throws {
        // Every launch read and SHA-256'd each multi-GB source again.
        let source = root.appendingPathComponent("a.mov")
        try Data("one".utf8).write(to: source)
        let storeURL = root.appendingPathComponent("hashes.json")
        let counter = HashCounter()

        let first = NativeWallpaperDeployment.ContentHashStore(fileURL: storeURL, hasher: counter.hash)
        let hash = try await first.hash(for: source)
        XCTAssertEqual(hash, "hash-of-one")
        _ = try await first.hash(for: source)
        XCTAssertEqual(counter.calls, 1)

        let relaunched = NativeWallpaperDeployment.ContentHashStore(fileURL: storeURL, hasher: counter.hash)
        let again = try await relaunched.hash(for: source)
        XCTAssertEqual(again, "hash-of-one")
        XCTAssertEqual(counter.calls, 1)
    }

    @MainActor
    func testChangedFileIsRehashed() async throws {
        let source = root.appendingPathComponent("a.mov")
        try Data("one".utf8).write(to: source)
        let storeURL = root.appendingPathComponent("hashes.json")
        let counter = HashCounter()
        _ = try await NativeWallpaperDeployment.ContentHashStore(fileURL: storeURL, hasher: counter.hash).hash(for: source)

        try Data("two!".utf8).write(to: source)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: source.path)
        let relaunched = NativeWallpaperDeployment.ContentHashStore(fileURL: storeURL, hasher: counter.hash)
        let hash = try await relaunched.hash(for: source)
        XCTAssertEqual(hash, "hash-of-two!")
        XCTAssertEqual(counter.calls, 2)
    }

    @MainActor
    func testUnreadableStoreFallsBackToHashing() async throws {
        let source = root.appendingPathComponent("a.mov")
        try Data("one".utf8).write(to: source)
        let storeURL = root.appendingPathComponent("hashes.json")
        try Data("not json".utf8).write(to: storeURL)
        let counter = HashCounter()
        let hash = try await NativeWallpaperDeployment.ContentHashStore(fileURL: storeURL, hasher: counter.hash).hash(for: source)
        XCTAssertEqual(hash, "hash-of-one")
        XCTAssertEqual(counter.calls, 1)
    }

    @MainActor
    func testSameSizeSameMtimeReplacementIsRehashed() async throws {
        // A different file of the same size, given the old modification
        // date, returned the old hash, so deploy kept the old video.
        let source = root.appendingPathComponent("a.mov")
        try Data("one".utf8).write(to: source)
        let mtime = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: source.path)[.modificationDate] as? Date)
        let storeURL = root.appendingPathComponent("hashes.json")
        let counter = HashCounter()
        _ = try await NativeWallpaperDeployment.ContentHashStore(fileURL: storeURL, hasher: counter.hash).hash(for: source)

        let replacement = root.appendingPathComponent("b.mov")
        try Data("two".utf8).write(to: replacement)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: replacement.path)
        _ = try FileManager.default.replaceItemAt(source, withItemAt: replacement)
        let relaunched = NativeWallpaperDeployment.ContentHashStore(fileURL: storeURL, hasher: counter.hash)
        let replaced = try await relaunched.hash(for: source)
        XCTAssertEqual(replaced, "hash-of-two")

        // Rewritten in place, then the old date put back.
        let handle = try FileHandle(forWritingTo: source)
        try handle.write(contentsOf: Data("six".utf8))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: source.path)
        let rewritten = try await relaunched.hash(for: source)
        XCTAssertEqual(rewritten, "hash-of-six")
        XCTAssertEqual(counter.calls, 3)
    }

    @MainActor
    func testFileChangingWhileHashedIsNotCached() async throws {
        let source = root.appendingPathComponent("a.mov")
        try Data("one".utf8).write(to: source)
        let counter = HashCounter()
        let store = NativeWallpaperDeployment.ContentHashStore(fileURL: root.appendingPathComponent("hashes.json")) { url in
            let hash = try counter.hash(url)
            if counter.calls == 1 {
                let mtime = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]
                try Data("two".utf8).write(to: url)
                try FileManager.default.setAttributes([.modificationDate: mtime as Any], ofItemAtPath: url.path)
            }
            return hash
        }
        _ = try await store.hash(for: source)
        let second = try await store.hash(for: source)
        XCTAssertEqual(second, "hash-of-two")
        XCTAssertEqual(counter.calls, 2)
    }
}
