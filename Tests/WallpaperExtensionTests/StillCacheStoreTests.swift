import Darwin
import os
import XCTest

/// The still cache on disk, in a temp directory (#13 review).
final class StillCacheStoreTests: XCTestCase {
    private let hashA = String(repeating: "a", count: 64)
    private let hashB = String(repeating: "b", count: 64)
    private let fourK = StillSize(width: 3840, height: 2160)
    private let qhd = StillSize(width: 2560, height: 1440)
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("StillCacheStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private static let red: [UInt8] = [0, 0, 255]
    private static let blue: [UInt8] = [255, 0, 0]
    private static let green: [UInt8] = [0, 255, 0]

    /// A 4x2 still of one colour: 54 + 16 * 2 = 86 bytes.
    private static func bmp(_ bgr: [UInt8]) -> Data? {
        (try? stillTestImage(width: 4, height: 2) { _, _ in bgr }).flatMap(StillCache.encodeBMP)
    }

    private static let fileBytes = 86

    /// A still at its final name, as an earlier write would have left it.
    @discardableResult
    private func place(_ hash: String, _ size: StillSize, version: String?, usedAgo: TimeInterval, data: Data? = bmp(blue)) throws -> URL {
        let entry = StillCacheEntry(key: StillCacheKey(choiceHash: hash, width: size.width, height: size.height), written: 1)
        let url = dir.appendingPathComponent(entry.fileName)
        try XCTUnwrap(data).write(to: url)
        if let version { XCTAssertEqual(setStillAttribute(url, StillCacheStore.versionAttribute, version), 0) }
        let used = Date().addingTimeInterval(-usedAgo).timeIntervalSinceReferenceDate
        XCTAssertEqual(setStillAttribute(url, StillCacheStore.usedAttribute, String(used)), 0)
        return url
    }

    private func names() -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
    }

    // MARK: Ordering

    func testAnOlderVideoFinishingLastLeavesTheNewerOne() async throws {
        // V1 starts decoding, the wallpaper's video changes, V2 is written,
        // then V1's decode returns. V1 must not replace or evict V2.
        // V2 alone is over budget, so only its own write may keep it.
        let store = StillCacheStore(budget: 10)
        let gate = StillTestGate()
        let dir = dir!, hashA = hashA, qhd = qhd
        let v1 = Task {
            await store.write(in: dir, choiceHash: hashA, version: "v1", size: qhd) {
                await gate.pass()
                return Self.bmp(Self.red)
            }
        }
        guard await gate.reached() else { gate.open(); return XCTFail("V1 never started decoding") }
        let v2 = await store.write(in: dir, choiceHash: hashA, version: "v2", size: qhd) { Self.bmp(Self.blue) }
        XCTAssertEqual(v2.outcome, .created)
        gate.open()
        let late = await v1.value
        XCTAssertEqual(late.outcome, .superseded)
        XCTAssertEqual(StillCacheStore.scan(dir).map(\.version), ["v2"])
        let seed = try XCTUnwrap(StillCacheStore().load(in: dir, choiceHash: hashA, version: "v2", size: qhd))
        XCTAssertEqual(try stillTestPixel(seed, x: 0, y: 0), Self.blue)
        XCTAssertNil(StillCacheStore().load(in: dir, choiceHash: hashA, version: "v1", size: qhd))
    }

    func testDifferentCacheDirectoriesDontSupersedeEachOther() async throws {
        let store = StillCacheStore()
        let gate = StillTestGate()
        let other = dir.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let dir = dir!, hashA = hashA, qhd = qhd
        let first = Task {
            await store.write(in: dir, choiceHash: hashA, version: "v1", size: qhd) {
                await gate.pass()
                return Self.bmp(Self.red)
            }
        }
        guard await gate.reached() else { gate.open(); return XCTFail("the first write never started decoding") }
        let second = await store.write(in: other, choiceHash: hashA, version: "v2", size: qhd) { Self.bmp(Self.blue) }
        let joined = await store.write(in: other, choiceHash: hashA, version: "v1", size: qhd) { Self.bmp(Self.red) }
        gate.open()
        XCTAssertEqual(second.outcome, .created)
        XCTAssertEqual(joined.outcome, .created)
        let late = await first.value
        XCTAssertEqual(late.outcome, .created)
    }

    // MARK: Seeds and eviction

    func testASeedWaitsForAnEvictionThatHasScanned() throws {
        // Eviction picks the least recently used from its scan. A seed
        // started between that scan and the delete must wait for the
        // delete, not touch a file the eviction already chose.
        let seeded = try place(hashA, qhd, version: "v1", usedAgo: 300)
        try place(hashB, qhd, version: "v1", usedAgo: 100)
        let dir = dir!, hashA = hashA, qhd = qhd
        let shared = OSAllocatedUnfairLock<StillCacheStore?>(initialState: nil)
        let seedReturned = DispatchSemaphore(value: 0)
        let seedFound = OSAllocatedUnfairLock<Bool?>(initialState: nil)
        let seedWaited = OSAllocatedUnfairLock<Bool?>(initialState: nil)
        let seedDone = expectation(description: "seed returned")
        let store = StillCacheStore(budget: 2 * Self.fileBytes, onEvictionScan: {
            DispatchQueue.global().async {
                let image = shared.withLock { $0 }?.load(in: dir, choiceHash: hashA, version: "v1", size: qhd)
                seedFound.withLock { $0 = image != nil }
                seedReturned.signal()
                seedDone.fulfill()
            }
            // An unblocked load of an 86-byte file returns well within this.
            let waited = seedReturned.wait(timeout: .now() + 1) == .timedOut
            seedWaited.withLock { $0 = waited }
        })
        shared.withLock { $0 = store }
        let writeDone = expectation(description: "write returned")
        let hashB = hashB, fourK = fourK
        Task {
            _ = await store.write(in: dir, choiceHash: hashB, version: "v1", size: fourK) { Self.bmp(Self.green) }
            writeDone.fulfill()
        }
        wait(for: [writeDone, seedDone], timeout: 10)
        XCTAssertEqual(seedWaited.withLock { $0 }, true, "the seed ran while eviction held its scan")
        XCTAssertEqual(seedFound.withLock { $0 }, false, "the seed's only candidate was evicted before it could pick it")
        XCTAssertFalse(FileManager.default.fileExists(atPath: seeded.path))
    }

    func testASeedOutlivesAnEvictionAfterItsPick() throws {
        // A newer video's write removes the picked still before the seed
        // decodes it; the seed must still decode what it picked.
        try place(hashA, qhd, version: "v1", usedAgo: 10, data: Self.bmp(Self.blue))
        let dir = dir!, hashA = hashA, qhd = qhd
        let shared = OSAllocatedUnfairLock<StillCacheStore?>(initialState: nil)
        let store = StillCacheStore(onSeedPicked: {
            guard let store = shared.withLock({ $0 }) else { return }
            let written = DispatchSemaphore(value: 0)
            Task {
                _ = await store.write(in: dir, choiceHash: hashA, version: "v2", size: qhd) { Self.bmp(Self.red) }
                written.signal()
            }
            written.wait()
        })
        shared.withLock { $0 = store }
        let image = try XCTUnwrap(store.load(in: dir, choiceHash: hashA, version: "v1", size: qhd))
        XCTAssertEqual(try stillTestPixel(image, x: 0, y: 0), Self.blue)
        XCTAssertEqual(StillCacheStore.scan(dir).map(\.version), ["v2"])
    }

    // MARK: Failed writes

    func testAFailedWriteRemovesNothing() async throws {
        let legacy = try place(hashA, fourK, version: nil, usedAgo: 10)
        let report = await StillCacheStore(budget: 0).write(in: dir, choiceHash: hashA, version: "v1", size: qhd) { nil }
        XCTAssertEqual(report.outcome, .failed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
    }

    func testADirectoryThatRefusesAttributesIsBypassed() async throws {
        // A complete v1 still the refused directory must not serve.
        let v1 = try place(hashA, qhd, version: "v1", usedAgo: 10)
        let decodes = OSAllocatedUnfairLock(initialState: 0)
        let encode: @Sendable () async -> Data? = {
            decodes.withLock { $0 += 1 }
            return Self.bmp(Self.blue)
        }
        let store = StillCacheStore(tag: { _, _, _ in EPERM })
        let first = await store.write(in: dir, choiceHash: hashA, version: "v2", size: qhd, encode: encode)
        let again = await store.write(in: dir, choiceHash: hashA, version: "v2", size: fourK, encode: encode)
        XCTAssertEqual(first.outcome, .refused(errno: EPERM))
        XCTAssertEqual(again.outcome, .refused(errno: EPERM))
        XCTAssertEqual(decodes.withLock { $0 }, 1, "a refused directory must not be decoded for again")
        XCTAssertNil(store.load(in: dir, choiceHash: hashA, version: "v1", size: qhd))
        XCTAssertEqual(names(), [v1.lastPathComponent])
    }

    func testARefusedLastUseTagMarksTheDirectory() async {
        let decodes = OSAllocatedUnfairLock(initialState: 0)
        let encode: @Sendable () async -> Data? = {
            decodes.withLock { $0 += 1 }
            return Self.bmp(Self.blue)
        }
        let store = StillCacheStore(tag: { _, name, _ in name == StillCacheStore.usedAttribute ? EACCES : 0 })
        let first = await store.write(in: dir, choiceHash: hashA, version: "v1", size: qhd, encode: encode)
        let again = await store.write(in: dir, choiceHash: hashA, version: "v1", size: fourK, encode: encode)
        XCTAssertEqual(first.outcome, .refused(errno: EACCES))
        XCTAssertEqual(again.outcome, .refused(errno: EACCES))
        XCTAssertEqual(decodes.withLock { $0 }, 1)
    }

    func testAWriteDecodingWhenTheDirectoryIsRefusedDoesntPublish() async {
        let tags = OSAllocatedUnfairLock(initialState: 0)
        let store = StillCacheStore(tag: { _, _, _ in
            tags.withLock { $0 += 1 }
            return EPERM
        })
        let gate = StillTestGate()
        let dir = dir!, hashA = hashA, qhd = qhd
        let suspended = Task {
            await store.write(in: dir, choiceHash: hashA, version: "v1", size: qhd) {
                await gate.pass()
                return Self.bmp(Self.blue)
            }
        }
        guard await gate.reached() else { gate.open(); return XCTFail("the first write never started decoding") }
        let refused = await store.write(in: dir, choiceHash: hashB, version: "v1", size: qhd) { Self.bmp(Self.red) }
        XCTAssertEqual(refused.outcome, .refused(errno: EPERM))
        gate.open()
        let late = await suspended.value
        XCTAssertEqual(late.outcome, .refused(errno: EPERM))
        XCTAssertEqual(tags.withLock { $0 }, 1, "the suspended write tried to publish into a refused directory")
        XCTAssertEqual(names(), [])
    }

    // MARK: Interrupted writes

    func testATruncatedStillIsNeitherAHitNorASeed() async throws {
        try place(hashA, fourK, version: "v1", usedAgo: 10, data: Self.bmp(Self.blue))
        let partial = try place(hashA, qhd, version: "v1", usedAgo: 0, data: Self.bmp(Self.red)?.prefix(70))
        let seed = try XCTUnwrap(StillCacheStore().load(in: dir, choiceHash: hashA, version: "v1", size: qhd))
        XCTAssertEqual(seed.width, 4)
        XCTAssertEqual(try stillTestPixel(seed, x: 0, y: 0), Self.blue)

        let report = await StillCacheStore().write(in: dir, choiceHash: hashA, version: "v1", size: qhd) {
            XCTFail("the complete 4K still should be copied, not decoded")
            return nil
        }
        XCTAssertEqual(report, .init(outcome: .created, created: 1))
        XCTAssertFalse(names().contains(partial.lastPathComponent))
        let files = StillCacheStore.scan(dir)
        XCTAssertEqual(files.count, 2)
        XCTAssertTrue(files.allSatisfy { $0.isComplete && $0.version == "v1" })
    }

    func testLeftoverTempFilesAreRemoved() async {
        let leftover = dir.appendingPathComponent(".lumawall-\(UUID().uuidString).tmp")
        FileManager.default.createFile(atPath: leftover.path, contents: Data(repeating: 1, count: 10))
        _ = await StillCacheStore().write(in: dir, choiceHash: hashA, version: "v1", size: qhd) { Self.bmp(Self.blue) }
        XCTAssertEqual(names().filter { $0.hasSuffix(".tmp") }, [])
    }

    // MARK: Budget

    func testAHitStillEnforcesTheBudget() async throws {
        // A crash after a write can leave the folder over budget; the next
        // write trims it even if it only hits.
        let oldest = try place(hashB, fourK, version: "v1", usedAgo: 300)
        try place(hashB, qhd, version: "v1", usedAgo: 200)
        try place(hashA, qhd, version: "v1", usedAgo: 100)
        let store = StillCacheStore(budget: 2 * Self.fileBytes)
        let report = await store.write(in: dir, choiceHash: hashA, version: "v1", size: qhd) { nil }
        XCTAssertEqual(report.outcome, .hit)
        XCTAssertEqual(names().count, 2)
        XCTAssertFalse(names().contains(oldest.lastPathComponent))
    }

    func testALoadCountsAsAUse() async throws {
        let read = try place(hashA, qhd, version: "v1", usedAgo: 300)
        let unread = try place(hashB, qhd, version: "v1", usedAgo: 100)
        XCTAssertNotNil(StillCacheStore().load(in: dir, choiceHash: hashA, version: "v1", size: qhd))
        let store = StillCacheStore(budget: 2 * Self.fileBytes)
        _ = await store.write(in: dir, choiceHash: hashB, version: "v1", size: fourK) { Self.bmp(Self.green) }
        XCTAssertTrue(names().contains(read.lastPathComponent))
        XCTAssertFalse(names().contains(unread.lastPathComponent))
    }

    // MARK: Reuse

    func testTwoDisplaySizesDecodeOnceAndBothStay() async {
        let store = StillCacheStore()
        let decodes = OSAllocatedUnfairLock(initialState: 0)
        let encode: @Sendable () async -> Data? = {
            decodes.withLock { $0 += 1 }
            return Self.bmp(Self.blue)
        }
        let a = await store.write(in: dir, choiceHash: hashA, version: "v1", size: fourK, encode: encode)
        let b = await store.write(in: dir, choiceHash: hashA, version: "v1", size: qhd, encode: encode)
        let c = await store.write(in: dir, choiceHash: hashA, version: "v1", size: fourK, encode: encode)
        XCTAssertEqual([a.outcome, b.outcome, c.outcome], [.created, .created, .hit])
        XCTAssertEqual(decodes.withLock { $0 }, 1)
        XCTAssertEqual(StillCacheStore.scan(dir).count, 2)
    }

    func testConcurrentMissesShareOneDecode() async {
        let store = StillCacheStore()
        let gate = StillTestGate()
        let decodes = OSAllocatedUnfairLock(initialState: 0)
        let dir = dir!, hashA = hashA, qhd = qhd
        let leader = Task {
            await store.write(in: dir, choiceHash: hashA, version: "v1", size: qhd) {
                decodes.withLock { $0 += 1 }
                await gate.pass()
                return Self.bmp(Self.blue)
            }
        }
        guard await gate.reached() else { gate.open(); return XCTFail("the leader never started decoding") }
        let follower = await store.write(in: dir, choiceHash: hashA, version: "v1", size: fourK) {
            decodes.withLock { $0 += 1 }
            return Self.bmp(Self.blue)
        }
        XCTAssertEqual(follower.outcome, .joined)
        gate.open()
        let led = await leader.value
        XCTAssertEqual(led, .init(outcome: .created, created: 2))
        XCTAssertEqual(decodes.withLock { $0 }, 1)
        XCTAssertEqual(Set(StillCacheStore.scan(dir).map(\.entry.key.width)), [2560, 3840])
    }
}

/// Holds an encode until the test opens it.
final class StillTestGate: Sendable {
    private let arrived = AsyncStream<Void>.makeStream()
    private let opened = AsyncStream<Void>.makeStream()

    func pass() async {
        arrived.continuation.yield()
        for await _ in opened.stream { break }
    }

    /// True once an encode is waiting at the gate; false after 5 s, so a
    /// store that never encodes fails the test instead of hanging it.
    func reached() async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { for await _ in self.arrived.stream { return true }; return false }
            group.addTask { try? await Task.sleep(for: .seconds(5)); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    func open() {
        opened.continuation.finish()
    }
}
