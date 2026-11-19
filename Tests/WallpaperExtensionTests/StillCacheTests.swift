import XCTest

/// The still-image cache keeps one BMP per wallpaper, content version and
/// display size, and stays under a byte budget (#13).
final class StillCacheTests: XCTestCase {
    private let hashA = String(repeating: "a", count: 64)
    private let hashB = String(repeating: "b", count: 64)
    private let day = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func entry(_ hash: String, _ width: Int, _ height: Int, version: UInt64 = 1) -> StillCacheEntry {
        StillCacheEntry(choiceHash: hash, width: width, height: height, version: version)
    }

    private func file(_ entry: StillCacheEntry, mb: Int = 25, age: TimeInterval = 0) -> StillCacheFile {
        StillCacheFile(entry: entry, bytes: mb << 20, modified: day.addingTimeInterval(-age))
    }

    // MARK: File names

    func testFileNameKeepsTheAgentLayout() {
        let name = entry(hashA, 3840, 2160, version: 0x41C8_0000_0000_0000).fileName
        XCTAssertEqual(name, "\(hashA)-3840-2160-0-41c8000000000000.bmp")
    }

    func testFileNameRoundTrips() {
        let original = entry(hashA, 2560, 1440, version: 0xDEAD_BEEF)
        XCTAssertEqual(StillCacheEntry(fileName: original.fileName), original)
    }

    func testForeignFileNamesAreIgnored() {
        XCTAssertNil(StillCacheEntry(fileName: "cacheVersion.db"))
        XCTAssertNil(StillCacheEntry(fileName: "\(hashA)-3840-2160.bmp"))
        XCTAssertNil(StillCacheEntry(fileName: "short-3840-2160-0-41c8000000000000.bmp"))
        XCTAssertNil(StillCacheEntry(fileName: "\(hashA)-wide-2160-0-41c8000000000000.bmp"))
    }

    func testVersionFollowsTheVideoModificationTime() {
        let earlier = StillCache.version(modified: day)
        let later = StillCache.version(modified: day.addingTimeInterval(1))
        XCTAssertNotEqual(earlier, later)
        XCTAssertEqual(StillCache.version(modified: day), earlier)
        XCTAssertEqual(StillCache.version(modified: nil), 0)
    }

    // MARK: Writing

    func testTwoDisplaySizesBothStayCached() {
        // The bug: writing the 1440p still deleted the 4K one, so the two
        // displays took turns missing and each miss decoded a frame.
        let fourK = entry(hashA, 3840, 2160)
        let qhd = entry(hashA, 2560, 1440)
        let files = [file(fourK), file(qhd)]
        XCTAssertEqual(StillCache.source(for: fourK, in: files), .existing)
        XCTAssertEqual(StillCache.source(for: qhd, in: files), .existing)
        XCTAssertEqual(StillCache.evictions(files, keeping: [qhd], budget: StillCache.byteBudget), [])
    }

    func testANewSizeCopiesASiblingInsteadOfDecoding() {
        // The BMP holds the video's own frame, whatever the display size.
        let fourK = entry(hashA, 3840, 2160)
        XCTAssertEqual(StillCache.source(for: entry(hashA, 2560, 1440), in: [file(fourK)]), .copy(from: fourK))
    }

    func testAnOlderVersionIsNotCopied() {
        let stale = entry(hashA, 3840, 2160, version: 1)
        XCTAssertEqual(StillCache.source(for: entry(hashA, 2560, 1440, version: 2), in: [file(stale)]), .decode)
    }

    func testOtherWallpapersAreNotCopied() {
        XCTAssertEqual(StillCache.source(for: entry(hashA, 2560, 1440), in: [file(entry(hashB, 2560, 1440))]), .decode)
    }

    // MARK: Eviction

    func testANewVersionRemovesTheOldOnesAtEverySize() {
        let current = entry(hashA, 3840, 2160, version: 2)
        let staleSame = entry(hashA, 3840, 2160, version: 1)
        let staleOther = entry(hashA, 2560, 1440, version: 1)
        let otherWallpaper = entry(hashB, 2560, 1440, version: 1)
        let files = [file(current), file(staleSame), file(staleOther), file(otherWallpaper)]
        XCTAssertEqual(
            Set(StillCache.evictions(files, keeping: [current], budget: StillCache.byteBudget)),
            [staleSame, staleOther],
        )
    }

    func testOverBudgetRemovesTheLeastRecentlyUsedFirst() {
        let kept = entry(hashA, 3840, 2160)
        let oldest = entry(hashB, 3840, 2160)
        let middle = entry(hashB, 2560, 1440)
        let files = [file(kept, mb: 40), file(oldest, mb: 40, age: 300), file(middle, mb: 40, age: 100)]
        XCTAssertEqual(StillCache.evictions(files, keeping: [kept], budget: 90 << 20), [oldest])
        XCTAssertEqual(StillCache.evictions(files, keeping: [kept], budget: 40 << 20), [oldest, middle])
    }

    func testTheEntriesJustWrittenSurviveEvenOverBudget() {
        let kept = entry(hashA, 6016, 3384)
        XCTAssertEqual(StillCache.evictions([file(kept, mb: 60)], keeping: [kept], budget: 10 << 20), [])
    }

    // MARK: Loading

    func testLoadPrefersTheExactSizeOfTheCurrentVersion() {
        let exact = entry(hashA, 2560, 1440)
        let files = [file(entry(hashA, 3840, 2160)), file(exact, age: 500), file(entry(hashB, 2560, 1440))]
        XCTAssertEqual(StillCache.lookup(files, choiceHash: hashA, version: 1, width: 2560, height: 1440)?.entry, exact)
    }

    func testLoadFallsBackToAnotherSizeThenAnOlderVersion() {
        let otherSize = entry(hashA, 3840, 2160)
        let stale = entry(hashA, 2560, 1440, version: 0)
        XCTAssertEqual(
            StillCache.lookup([file(stale), file(otherSize)], choiceHash: hashA, version: 1, width: 2560, height: 1440)?.entry,
            otherSize,
        )
        XCTAssertEqual(
            StillCache.lookup([file(stale), file(entry(hashB, 2560, 1440))], choiceHash: hashA, version: 1, width: 2560, height: 1440)?.entry,
            stale,
        )
    }

    func testLoadFallsBackToTheNewestStillOfAnyWallpaper() {
        // Matches the old behaviour of showing some still over black.
        let newer = entry(hashB, 2560, 1440)
        let files = [file(entry(hashB, 3840, 2160), age: 60), file(newer)]
        XCTAssertEqual(StillCache.lookup(files, choiceHash: hashA, version: 1, width: 2560, height: 1440)?.entry, newer)
        XCTAssertNil(StillCache.lookup([], choiceHash: hashA, version: 1, width: 2560, height: 1440))
    }

    // MARK: Coalescing

    func testConcurrentMissesShareOneWrite() {
        let flights = StillCacheFlights()
        let fourK = StillSize(width: 3840, height: 2160)
        let qhd = StillSize(width: 2560, height: 1440)
        XCTAssertTrue(flights.join("A-1", size: fourK))
        XCTAssertFalse(flights.join("A-1", size: fourK))
        XCTAssertFalse(flights.join("A-1", size: qhd))
        XCTAssertFalse(flights.join("A-1", size: qhd))
        // The leader writes the sizes that joined, once each, then the group ends.
        XCTAssertEqual(flights.next("A-1"), qhd)
        XCTAssertNil(flights.next("A-1"))
        XCTAssertTrue(flights.join("A-1", size: qhd))
    }

    func testDifferentWallpapersWriteIndependently() {
        let flights = StillCacheFlights()
        let size = StillSize(width: 3840, height: 2160)
        XCTAssertTrue(flights.join("A-1", size: size))
        XCTAssertTrue(flights.join("B-1", size: size))
        XCTAssertTrue(flights.join("A-2", size: size))
    }
}
