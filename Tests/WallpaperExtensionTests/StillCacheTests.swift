import ImageIO
import XCTest

/// Decisions for the still-image cache: one BMP per wallpaper, video and
/// display size, under a byte budget (#13).
final class StillCacheTests: XCTestCase {
    private let hashA = String(repeating: "a", count: 64)
    private let hashB = String(repeating: "b", count: 64)
    private let day = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let fourK = StillSize(width: 3840, height: 2160)
    private let qhd = StillSize(width: 2560, height: 1440)

    private func file(
        _ hash: String, _ size: StillSize, version: String? = "v1", written: UInt64 = 1,
        mb: Int = 25, age: TimeInterval = 0, complete: Bool = true,
    ) -> StillCacheFile {
        StillCacheFile(
            entry: StillCacheEntry(key: StillCacheKey(choiceHash: hash, width: size.width, height: size.height), written: written),
            bytes: mb << 20, version: version, lastUsed: day.addingTimeInterval(-age), isComplete: complete,
        )
    }

    // MARK: File names

    func testFileNameKeepsTheWriteTimeLayout() {
        let entry = StillCacheEntry(key: StillCacheKey(choiceHash: hashA, width: 3840, height: 2160), written: 0x41C8_0000_0000_0000)
        XCTAssertEqual(entry.fileName, "\(hashA)-3840-2160-0-41c8000000000000.bmp")
        XCTAssertEqual(StillCacheEntry(fileName: entry.fileName), entry)
    }

    func testForeignFileNamesAreIgnored() {
        XCTAssertNil(StillCacheEntry(fileName: "cacheVersion.db"))
        XCTAssertNil(StillCacheEntry(fileName: ".lumawall-1234.tmp"))
        XCTAssertNil(StillCacheEntry(fileName: "\(hashA)-3840-2160.bmp"))
        XCTAssertNil(StillCacheEntry(fileName: "short-3840-2160-0-41c8000000000000.bmp"))
        XCTAssertNil(StillCacheEntry(fileName: "\(hashA)-wide-2160-0-41c8000000000000.bmp"))
    }

    func testVersionChangesWithThePathTheModificationTimeOrTheSize() {
        let base = StillCache.version(path: "/v/a.mov", modified: day, size: 100)
        XCTAssertEqual(StillCache.version(path: "/v/a.mov", modified: day, size: 100), base)
        XCTAssertNotEqual(StillCache.version(path: "/v/b.mov", modified: day, size: 100), base)
        XCTAssertNotEqual(StillCache.version(path: "/v/a.mov", modified: day.addingTimeInterval(1), size: 100), base)
        XCTAssertNotEqual(StillCache.version(path: "/v/a.mov", modified: day, size: 101), base)
    }

    // MARK: Writing

    func testTwoDisplaySizesBothStayCached() {
        // The bug: writing the 1440p still deleted the 4K one, so the two
        // displays took turns missing and each miss decoded a frame.
        let files = [file(hashA, fourK), file(hashA, qhd)]
        let qhdKey = files[1].entry.key
        XCTAssertEqual(StillCache.source(for: files[0].entry.key, version: "v1", in: files), .existing(files[0].entry))
        XCTAssertEqual(StillCache.source(for: qhdKey, version: "v1", in: files), .existing(files[1].entry))
        XCTAssertEqual(StillCache.evictions(files, current: (hashA, "v1"), keeping: files[1].entry, budget: StillCache.byteBudget), [])
    }

    func testANewSizeCopiesASiblingOfTheSameVideo() {
        let sibling = file(hashA, fourK)
        let key = StillCacheKey(choiceHash: hashA, width: 2560, height: 1440)
        XCTAssertEqual(StillCache.source(for: key, version: "v1", in: [sibling]), .copy(from: sibling.entry))
    }

    func testOnlyACompleteFileOfTheSameVideoCounts() {
        let key = StillCacheKey(choiceHash: hashA, width: 2560, height: 1440)
        XCTAssertEqual(StillCache.source(for: key, version: "v2", in: [file(hashA, qhd), file(hashA, fourK)]), .decode)
        XCTAssertEqual(StillCache.source(for: key, version: "v1", in: [file(hashA, qhd, complete: false)]), .decode)
        XCTAssertEqual(StillCache.source(for: key, version: "v1", in: [file(hashA, qhd, version: nil)]), .decode)
        XCTAssertEqual(StillCache.source(for: key, version: "v1", in: [file(hashB, qhd)]), .decode)
    }

    // MARK: Eviction

    func testTheCurrentVideoRemovesOtherVersionsOfItsWallpaper() {
        let current = file(hashA, fourK, version: "v2")
        let files = [current, file(hashA, fourK, version: "v1", written: 0), file(hashA, qhd, version: "v1"),
                     file(hashA, qhd, version: nil), file(hashB, qhd, version: "v1")]
        let removed = StillCache.evictions(files, current: (hashA, "v2"), keeping: current.entry, budget: StillCache.byteBudget)
        XCTAssertEqual(Set(removed), Set([files[1], files[2], files[3]].map(\.entry)))
    }

    func testIncompleteFilesAndOlderCopiesOfAKeyAreRemoved() {
        let older = file(hashB, qhd, written: 1)
        let newer = file(hashB, qhd, written: 2)
        let partial = file(hashB, fourK, complete: false)
        let removed = StillCache.evictions([older, newer, partial], current: nil, keeping: nil, budget: StillCache.byteBudget)
        XCTAssertEqual(Set(removed), [older.entry, partial.entry])
    }

    func testOverBudgetRemovesTheLeastRecentlyUsedFirst() {
        let kept = file(hashA, fourK, mb: 40)
        let oldest = file(hashB, fourK, mb: 40, age: 300)
        let middle = file(hashB, qhd, mb: 40, age: 100)
        let files = [kept, oldest, middle]
        XCTAssertEqual(StillCache.evictions(files, current: nil, keeping: kept.entry, budget: 90 << 20), [oldest.entry])
        XCTAssertEqual(StillCache.evictions(files, current: nil, keeping: kept.entry, budget: 40 << 20), [oldest.entry, middle.entry])
    }

    func testOnlyTheEntryJustWrittenSurvivesOverBudget() {
        // Other sizes of the same video get no protection.
        let kept = file(hashA, fourK, mb: 60)
        let sibling = file(hashA, qhd, mb: 60, age: 1)
        XCTAssertEqual(StillCache.evictions([kept, sibling], current: (hashA, "v1"), keeping: kept.entry, budget: 10 << 20), [sibling.entry])
        XCTAssertEqual(StillCache.evictions([kept], current: (hashA, "v1"), keeping: kept.entry, budget: 10 << 20), [])
    }

    // MARK: Loading

    func testCandidatesPreferTheExactSizeThenOtherSizesOfTheSameVideo() {
        let exact = file(hashA, qhd, written: 1)
        let other = file(hashA, fourK, written: 5)
        let files = [other, exact, file(hashA, qhd, version: "v0", written: 9), file(hashB, qhd), file(hashA, StillSize(width: 1920, height: 1080), complete: false)]
        XCTAssertEqual(StillCache.candidates(files, choiceHash: hashA, version: "v1", size: qhd).map(\.entry), [exact.entry, other.entry])
    }

    func testNoCandidateFromAnotherWallpaperOrVideo() {
        let files = [file(hashB, qhd), file(hashA, qhd, version: "v0")]
        XCTAssertTrue(StillCache.candidates(files, choiceHash: hashA, version: "v1", size: qhd).isEmpty)
    }

    // MARK: Encoding

    func testEncodesATopDownPaddedBGRBitmap() throws {
        let bmp = try XCTUnwrap(StillCache.encodeBMP(stillTestGradient(width: 5, height: 130)))
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
            XCTAssertEqual(bmp[54 + y * 16 + 15], 0, "padding in row \(y)")
        }
    }

    func testEncodedBitmapDecodesToTheSamePixels() throws {
        let bmp = try XCTUnwrap(StillCache.encodeBMP(stillTestGradient(width: 7, height: 70)))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(bmp as CFData, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(decoded.width, 7)
        XCTAssertEqual(decoded.height, 70)
        for (x, y) in [(0, 0), (6, 0), (3, 63), (3, 64), (6, 69)] {
            XCTAssertEqual(try stillTestPixel(decoded, x: x, y: y), [UInt8(y), UInt8(40 * x), UInt8(255 - y)], "pixel \(x),\(y)")
        }
    }

    func testHeaderPromisesTheEncodedSize() throws {
        let bmp = try XCTUnwrap(StillCache.encodeBMP(stillTestGradient(width: 5, height: 3)))
        XCTAssertEqual(StillCache.bmpFileSize(header: bmp), bmp.count)
        XCTAssertNil(StillCache.bmpFileSize(header: bmp.prefix(40)))
        XCTAssertNil(StillCache.bmpFileSize(header: Data(repeating: 0, count: 54)))
    }

    // MARK: Coalescing

    func testAMissWhileAWriteIsInFlightJoinsIt() {
        var flights = StillCacheFlights()
        XCTAssertTrue(flights.join("A-1", size: fourK))
        XCTAssertFalse(flights.join("A-1", size: fourK))
        XCTAssertFalse(flights.join("A-1", size: qhd))
        XCTAssertFalse(flights.join("A-1", size: qhd))
        // The leader writes each size that joined once, then the group ends.
        XCTAssertEqual(flights.next("A-1"), qhd)
        XCTAssertNil(flights.next("A-1"))
        XCTAssertTrue(flights.join("A-1", size: qhd))
        XCTAssertTrue(flights.join("B-1", size: qhd))
    }
}

/// An opaque image whose pixel at (x, y) from the top-left is
/// B = y, G = 40 * x, R = 255 - y.
func stillTestGradient(width: Int, height: Int) throws -> CGImage {
    try stillTestImage(width: width, height: height) { x, y in [UInt8(y), UInt8(40 * x), UInt8(255 - y)] }
}

func stillTestImage(width: Int, height: Int, bgr: (Int, Int) -> [UInt8]) throws -> CGImage {
    let ctx = try XCTUnwrap(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue,
    ))
    let pixels = try XCTUnwrap(ctx.data).assumingMemoryBound(to: UInt8.self)
    for y in 0 ..< height {
        for x in 0 ..< width {
            let p = pixels + y * width * 4 + x * 4
            let c = bgr(x, y)
            p[0] = c[0]; p[1] = c[1]; p[2] = c[2]; p[3] = 255
        }
    }
    return try XCTUnwrap(ctx.makeImage())
}

/// The B, G, R bytes of `image` at (x, y) from the top-left, in device RGB.
func stillTestPixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
    let ctx = try XCTUnwrap(CGContext(
        data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue,
    ))
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let p = try XCTUnwrap(ctx.data).assumingMemoryBound(to: UInt8.self) + y * image.width * 4 + x * 4
    return [p[0], p[1], p[2]]
}
