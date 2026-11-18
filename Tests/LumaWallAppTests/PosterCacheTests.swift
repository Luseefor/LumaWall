import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import LumaWall

final class PosterCacheTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    private func writePoster(_ name: String, width: Int, height: Int) throws -> URL {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let url = folder.appendingPathComponent(name)
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func pixelSize(_ image: NSImage?) -> CGSize {
        var rect = CGRect(origin: .zero, size: image?.size ?? .zero)
        guard let cgImage = image?.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return .zero }
        return CGSize(width: cgImage.width, height: cgImage.height)
    }

    func testPosterDecodesAtDisplayWidthNotSourceSize() async throws {
        // A 4K poster decodes to about 32 MB; a 280 pt card needs about 1 MB.
        let url = try writePoster("wide.jpg", width: 3840, height: 2400)
        let image = await PosterCache().image(for: url, maxPixelWidth: 640)
        XCTAssertEqual(pixelSize(image).width, 640)
        XCTAssertEqual(pixelSize(image).height, 400)
    }

    func testPortraitPosterKeepsTheRequestedWidth() async throws {
        // Cards aspect-fill by width, so a portrait poster needs 640 px across,
        // not 640 on its long edge.
        let url = try writePoster("tall.jpg", width: 2000, height: 4000)
        let image = await PosterCache().image(for: url, maxPixelWidth: 640)
        XCTAssertEqual(pixelSize(image).width, 640)
        XCTAssertEqual(pixelSize(image).height, 1280)
    }

    func testSmallPosterIsNotUpscaled() async throws {
        let url = try writePoster("small.jpg", width: 320, height: 200)
        let image = await PosterCache().image(for: url, maxPixelWidth: 640)
        XCTAssertEqual(pixelSize(image).width, 320)
    }

    func testCacheEvictsOldestPosterWhenDecodedBytesExceedTheLimit() async throws {
        let a = try writePoster("a.jpg", width: 1000, height: 1000)
        let b = try writePoster("b.jpg", width: 1000, height: 1000)
        let c = try writePoster("c.jpg", width: 1000, height: 1000)
        // Each decodes to 1000 x 1000 x 4 bytes: room for two, not three.
        let cache = PosterCache(maxBytes: 9_000_000, maxCount: 200)
        _ = await cache.image(for: a, maxPixelWidth: 1000)
        _ = await cache.image(for: b, maxPixelWidth: 1000)
        _ = await cache.image(for: c, maxPixelWidth: 1000)
        let hasA = await cache.contains(a, maxPixelWidth: 1000)
        let hasB = await cache.contains(b, maxPixelWidth: 1000)
        let hasC = await cache.contains(c, maxPixelWidth: 1000)
        let bytes = await cache.totalBytes
        XCTAssertFalse(hasA)
        XCTAssertTrue(hasB)
        XCTAssertTrue(hasC)
        let keptImage = await cache.image(for: b, maxPixelWidth: 1000)
        let kept = try XCTUnwrap(cgImage(of: keptImage))
        XCTAssertEqual(bytes, 2 * PosterCache.decodedBytes(of: kept))
    }

    func testDecodedCostCountsPaddedRows() throws {
        // Rows can be padded past width * 4; the budget must count real memory.
        let context = CGContext(
            data: nil, width: 1000, height: 10, bitsPerComponent: 8, bytesPerRow: 4096,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        let image = try XCTUnwrap(context.makeImage())
        XCTAssertEqual(PosterCache.decodedBytes(of: image), image.bytesPerRow * 10)
        XCTAssertGreaterThanOrEqual(PosterCache.decodedBytes(of: image), 40_000)
    }

    func testPosterLargerThanTheBudgetIsReturnedButNotCached() async throws {
        let url = try writePoster("big.jpg", width: 1000, height: 1000)
        let cache = PosterCache(maxBytes: 1_000_000, maxCount: 200)
        let image = await cache.image(for: url, maxPixelWidth: 1000)
        let cached = await cache.contains(url, maxPixelWidth: 1000)
        let bytes = await cache.totalBytes
        XCTAssertNotNil(image)
        XCTAssertFalse(cached)
        XCTAssertEqual(bytes, 0)
    }

    private func cgImage(of image: NSImage?) -> CGImage? {
        var rect = CGRect(origin: .zero, size: image?.size ?? .zero)
        return image?.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    func testRemoveDropsEverySizeOfAPoster() async throws {
        let url = try writePoster("a.jpg", width: 2000, height: 1250)
        let cache = PosterCache()
        _ = await cache.image(for: url, maxPixelWidth: 640)
        _ = await cache.image(for: url, maxPixelWidth: 1280)
        await cache.remove(url)
        let bytes = await cache.totalBytes
        XCTAssertEqual(bytes, 0)
    }

    func testUnreadablePosterReturnsNil() async {
        let image = await PosterCache().image(for: folder.appendingPathComponent("missing.jpg"), maxPixelWidth: 640)
        XCTAssertNil(image)
    }
}
