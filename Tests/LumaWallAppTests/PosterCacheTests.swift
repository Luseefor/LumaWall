import AVFoundation
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

    func testMissingPosterFallsBackToAStillFromTheVideo() async throws {
        // A poster that is gone or unreadable left the card blank even though
        // the original plays.
        let video = folder.appendingPathComponent("clip.mov")
        try await writeVideo(to: video)
        let cache = PosterCache()
        let missing = folder.appendingPathComponent("missing.jpg")
        let fromMissing = await cache.image(for: missing, fallbackVideo: video, maxPixelWidth: 640)
        let fromNil = await cache.image(for: nil, fallbackVideo: video, maxPixelWidth: 640)
        XCTAssertNotNil(fromMissing)
        XCTAssertNotNil(fromNil)
        XCTAssertLessThanOrEqual(pixelSize(fromMissing).width, 640)
        let cachedStill = await cache.contains(video, maxPixelWidth: 640)
        XCTAssertTrue(cachedStill)
        let noFallback = await cache.image(for: missing, fallbackVideo: nil, maxPixelWidth: 640)
        XCTAssertNil(noFallback)
    }

    private func cgImage(of image: NSImage?) -> CGImage? {
        var rect = CGRect(origin: .zero, size: image?.size ?? .zero)
        return image?.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    private func writeVideo(to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<10 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &pixelBuffer)
            XCTAssertTrue(adaptor.append(try XCTUnwrap(pixelBuffer), withPresentationTime: CMTime(value: Int64(frame), timescale: 30)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
    }

    private actor CallCounter {
        private(set) var count = 0
        func hit() { count += 1 }
    }

    private func stillFrame() -> CGImage {
        CGContext(
            data: nil, width: 64, height: 36, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!.makeImage()!
    }

    func testFailedStillGenerationRunsOnceUntilTheVideoIsRemoved() async {
        // Every view update re-ran .task and retried a video that can't be read.
        let counter = CallCounter()
        let cache = PosterCache(frameGenerator: { _, _ in
            await counter.hit()
            return nil
        })
        let video = folder.appendingPathComponent("broken.mov")
        let missing = folder.appendingPathComponent("missing.jpg")
        for _ in 0..<3 {
            let image = await cache.image(for: missing, fallbackVideo: video, maxPixelWidth: 640)
            XCTAssertNil(image)
        }
        let afterRepeats = await counter.count
        XCTAssertEqual(afterRepeats, 1)
        // Another width is a different request.
        _ = await cache.image(for: missing, fallbackVideo: video, maxPixelWidth: 1280)
        let afterOtherWidth = await counter.count
        XCTAssertEqual(afterOtherWidth, 2)
        await cache.remove(video)
        _ = await cache.image(for: missing, fallbackVideo: video, maxPixelWidth: 640)
        let afterRemove = await counter.count
        XCTAssertEqual(afterRemove, 3)
    }

    func testConcurrentRequestsForOneStillShareOneGeneration() async {
        let counter = CallCounter()
        let frame = stillFrame()
        let cache = PosterCache(frameGenerator: { _, _ in
            await counter.hit()
            try? await Task.sleep(for: .milliseconds(100))
            return frame
        })
        let video = folder.appendingPathComponent("clip.mov")
        let missing = folder.appendingPathComponent("missing.jpg")
        let images = await withTaskGroup(of: NSImage?.self) { group in
            for _ in 0..<5 {
                group.addTask { await cache.image(for: missing, fallbackVideo: video, maxPixelWidth: 640) }
            }
            return await group.reduce(into: [NSImage?]()) { $0.append($1) }
        }
        XCTAssertEqual(images.compactMap { $0 }.count, 5)
        let calls = await counter.count
        XCTAssertEqual(calls, 1)
    }

    /// Holds a generator open until the test lets it finish.
    private actor Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var opened = false
        func wait() async {
            if opened { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func open() {
            opened = true
            continuation?.resume()
            continuation = nil
        }
    }

    func testFailureFromWorkStartedBeforeRemoveDoesNotOutliveIt() async throws {
        let counter = CallCounter()
        let gate = Gate()
        let cache = PosterCache(frameGenerator: { _, _ in
            await counter.hit()
            await gate.wait()
            return nil
        })
        let video = folder.appendingPathComponent("clip.mov")
        let first = Task { await cache.image(for: nil, fallbackVideo: video, maxPixelWidth: 640) }
        while await counter.count == 0 { try await Task.sleep(for: .milliseconds(5)) }
        // The file changes while the old generation is still running.
        await cache.remove(video)
        await gate.open()
        _ = await first.value
        _ = await cache.image(for: nil, fallbackVideo: video, maxPixelWidth: 640)
        let calls = await counter.count
        XCTAssertEqual(calls, 2, "the stale failure must not block a fresh attempt")
    }

    func testStaleFrameFromBeforeRemoveIsNotCached() async throws {
        let gate = Gate()
        let frame = stillFrame()
        let cache = PosterCache(frameGenerator: { _, _ in
            await gate.wait()
            return frame
        })
        let video = folder.appendingPathComponent("clip.mov")
        let first = Task { await cache.image(for: nil, fallbackVideo: video, maxPixelWidth: 640) }
        try await Task.sleep(for: .milliseconds(50))
        await cache.remove(video)
        await gate.open()
        _ = await first.value
        let cached = await cache.contains(video, maxPixelWidth: 640)
        XCTAssertFalse(cached)
    }

    func testConcurrentRequestsForAFailingStillGenerateOnce() async {
        let counter = CallCounter()
        let cache = PosterCache(frameGenerator: { _, _ in
            await counter.hit()
            try? await Task.sleep(for: .milliseconds(50))
            return nil
        })
        let video = folder.appendingPathComponent("broken.mov")
        let missing = folder.appendingPathComponent("missing.jpg")
        await withTaskGroup(of: Void.self) { group in
            for delay in [0, 20, 60, 90, 120] {
                group.addTask {
                    try? await Task.sleep(for: .milliseconds(delay))
                    _ = await cache.image(for: missing, fallbackVideo: video, maxPixelWidth: 640)
                }
            }
        }
        let calls = await counter.count
        XCTAssertEqual(calls, 1)
    }

    func testPosterWrittenAfterAFailureShowsOnTheNextRequest() async throws {
        let cache = PosterCache(frameGenerator: { _, _ in nil })
        let poster = folder.appendingPathComponent("late.jpg")
        let video = folder.appendingPathComponent("broken.mov")
        let before = await cache.image(for: poster, fallbackVideo: video, maxPixelWidth: 640)
        XCTAssertNil(before)
        let written = try writePoster("late.jpg", width: 800, height: 450)
        XCTAssertEqual(written, poster)
        let after = await cache.image(for: poster, fallbackVideo: video, maxPixelWidth: 640)
        XCTAssertNotNil(after)
    }

    func testPosterWrittenAfterAPosterOnlyFailureShowsOnTheNextRequest() async throws {
        let cache = PosterCache()
        let poster = folder.appendingPathComponent("late.jpg")
        let before = await cache.image(for: poster, maxPixelWidth: 640)
        XCTAssertNil(before)
        _ = try writePoster("late.jpg", width: 800, height: 450)
        let after = await cache.image(for: poster, maxPixelWidth: 640)
        XCTAssertNotNil(after)
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
