import ImageIO
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

    // MARK: Encoding

    /// A 5x130 opaque image whose pixel at (x, y) from the top-left is
    /// B = y, G = 40 * x, R = 255 - y.
    private func gradientImage(width: Int = 5, height: Int = 130) throws -> CGImage {
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue,
        ))
        let pixels = try XCTUnwrap(ctx.data).assumingMemoryBound(to: UInt8.self)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let p = pixels + y * width * 4 + x * 4
                p[0] = UInt8(y); p[1] = UInt8(40 * x); p[2] = UInt8(255 - y); p[3] = 255
            }
        }
        return try XCTUnwrap(ctx.makeImage())
    }

    func testEncodesATopDownPaddedBGRBitmap() throws {
        let bmp = try XCTUnwrap(StillCache.encodeBMP(gradientImage()))
        // 5 px * 3 bytes = 15, padded to 16 per row.
        XCTAssertEqual(bmp.count, 54 + 16 * 130)
        XCTAssertEqual(Array(bmp[0 ..< 2]), [0x42, 0x4D])
        let field = { (offset: Int) in bmp[offset ..< offset + 4].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * $1.offset) } }
        XCTAssertEqual(field(2), UInt32(54 + 16 * 130))
        XCTAssertEqual(field(18), 5)
        XCTAssertEqual(Int32(bitPattern: field(22)), -130)
        // Rows 0, 63, 64 (second strip), 129 (partial last strip).
        for y in [0, 63, 64, 100, 129] {
            for x in 0 ..< 5 {
                let o = 54 + y * 16 + x * 3
                XCTAssertEqual(Array(bmp[o ..< o + 3]), [UInt8(y), UInt8(40 * x), UInt8(255 - y)], "pixel \(x),\(y)")
            }
        }
    }

    func testEncodedBitmapDecodesAtTheImageSize() throws {
        let bmp = try XCTUnwrap(StillCache.encodeBMP(gradientImage(width: 7, height: 3)))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(bmp as CFData, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(decoded.width, 7)
        XCTAssertEqual(decoded.height, 3)
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
