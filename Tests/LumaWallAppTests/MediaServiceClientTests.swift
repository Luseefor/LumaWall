import AVFoundation
import Foundation
import LumaWallCore
import XCTest

@testable import LumaWall

/// Round trips through the real LumaWallMediaService embedded in the test
/// host: the app sends a file handle, the sandboxed service parses it.
final class MediaServiceClientTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testTheServiceInspectsAndExtractsAPoster() async throws {
        let video = dir.appendingPathComponent("clip.mov")
        try await writeVideo(to: video)
        let client = MediaServiceClient()

        let info = try await client.inspect(fileAt: video)
        XCTAssertEqual(info.pixelSize, CGSize(width: 64, height: 64))
        XCTAssertEqual(info.videoTrackCount, 1)
        XCTAssertFalse(info.hasAudio)
        let poster = try await client.posterFrame(fileAt: video, maxPixelSize: CGSize(width: 32, height: 32))
        XCTAssertLessThanOrEqual(poster.width, 32)
        XCTAssertNotNil(poster.makeImage())
    }

    func testTheServiceReportsMediaItCannotRead() async throws {
        let text = dir.appendingPathComponent("notes.mov")
        try Data("not a movie".utf8).write(to: text)
        do {
            _ = try await MediaServiceClient().inspect(fileAt: text)
            XCTFail("expected the service to refuse a text file")
        } catch MediaProbeError.unsupportedMedia {}
    }

    func testAMissingServiceFailsInsteadOfHanging() async throws {
        let video = dir.appendingPathComponent("clip.mov")
        try await writeVideo(to: video)
        let client = MediaServiceClient(serviceName: "app.lumawall.personal.no-such-service", timeout: .seconds(10))
        do {
            _ = try await client.inspect(fileAt: video)
            XCTFail("expected an unreachable service to fail")
        } catch MediaProbeError.serviceUnavailable {}
    }

    private func writeVideo(to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64,
            ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<10 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &buffer)
            XCTAssertTrue(adaptor.append(try XCTUnwrap(buffer), withPresentationTime: CMTime(value: Int64(frame), timescale: 30)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
    }
}
