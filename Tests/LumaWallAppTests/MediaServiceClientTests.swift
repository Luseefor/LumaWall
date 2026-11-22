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

    func testAServiceThatNeverRepliesTimesOutAndIsEnded() async throws {
        let video = dir.appendingPathComponent("clip.mov")
        try await writeVideo(to: video)
        let service = SilentService()
        let listener = NSXPCListener.anonymous()
        listener.delegate = service
        listener.resume()
        defer { listener.invalidate() }
        let endpoint = listener.endpoint
        let ended = expectation(description: "the stuck service is ended")
        let client = MediaServiceClient(
            timeout: .seconds(1), connect: { NSXPCConnection(listenerEndpoint: endpoint) },
            onTimeout: { _ in ended.fulfill() })

        let start = ContinuousClock.now
        do {
            _ = try await client.inspect(fileAt: video)
            XCTFail("expected a silent service to time out")
        } catch MediaProbeError.serviceUnavailable {}
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(10))
        // The request reached the service and the connection stayed up:
        // only the timeout could have ended the call.
        XCTAssertEqual(service.requestCount, 1)
        await fulfillment(of: [ended], timeout: 5)
    }

    /// launchd throttles the relaunch of a killed service by about 10
    /// seconds, so the next test that uses the real service waits that long.
    func testEndingTheServiceStopsItsProcess() async throws {
        let video = dir.appendingPathComponent("clip.mov")
        try await writeVideo(to: video)
        let connection = NSXPCConnection(serviceName: MediaServiceContract.serviceName)
        connection.remoteObjectInterface = MediaServiceContract.interface()
        connection.resume()
        defer { connection.invalidate() }
        let service = try XCTUnwrap(connection.remoteObjectProxyWithErrorHandler { _ in } as? MediaServiceXPC)
        let handle = try MediaFile.open(video)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            service.inspect(handle, typeIdentifier: MediaFile.typeIdentifier(for: video)) { _, _ in done.resume() }
        }
        let pid = connection.processIdentifier
        XCTAssertGreaterThan(pid, 0)
        XCTAssertNotEqual(pid, getpid())

        MediaServiceClient.endService(connection)
        let deadline = ContinuousClock.now + .seconds(5)
        while kill(pid, 0) == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(kill(pid, 0), -1)
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

/// Accepts every request and never answers it, holding the reply blocks so
/// the connection stays up.
private final class SilentService: NSObject, NSXPCListenerDelegate, MediaServiceXPC, @unchecked Sendable {
    private let lock = NSLock()
    private var held: [Any] = []
    private var connections: [NSXPCConnection] = []

    var requestCount: Int { lock.withLock { held.count } }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = MediaServiceContract.interface()
        connection.exportedObject = self
        lock.withLock { connections.append(connection) }
        connection.resume()
        return true
    }

    func inspect(_ file: FileHandle, typeIdentifier: String, reply: @escaping @Sendable (Data?, Data?) -> Void) {
        lock.withLock { held.append(reply) }
    }

    func posterFrame(
        _ file: FileHandle, typeIdentifier: String, maxWidth: Double, maxHeight: Double, nearStart: Bool,
        reply: @escaping @Sendable (Data?, Data?) -> Void
    ) {
        lock.withLock { held.append(reply) }
    }
}
