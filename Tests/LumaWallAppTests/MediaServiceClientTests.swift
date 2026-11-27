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
        try await withinTestDeadline {
            try await Self.writeVideo(to: video)
            let client = MediaServiceClient()
            let info = try await client.inspect(fileAt: video)
            XCTAssertEqual(info.pixelSize, CGSize(width: 64, height: 64))
            XCTAssertEqual(info.videoTrackCount, 1)
            XCTAssertFalse(info.hasAudio)
            let poster = try await client.posterFrame(fileAt: video, maxPixelSize: CGSize(width: 32, height: 32))
            XCTAssertLessThanOrEqual(poster.width, 32)
            XCTAssertNotNil(poster.makeImage())
        }
    }

    func testTheServiceReportsMediaItCannotRead() async throws {
        let text = dir.appendingPathComponent("notes.mov")
        try Data("not a movie".utf8).write(to: text)
        try await withinTestDeadline {
            do {
                _ = try await MediaServiceClient().inspect(fileAt: text)
                XCTFail("expected the service to refuse a text file")
            } catch MediaProbeError.unsupportedMedia {}
        }
    }

    func testAMissingServiceFailsInsteadOfHanging() async throws {
        let video = dir.appendingPathComponent("clip.mov")
        try Data().write(to: video)
        try await withinTestDeadline {
            let client = MediaServiceClient(serviceName: "app.lumawall.personal.no-such-service")
            do {
                _ = try await client.inspect(fileAt: video)
                XCTFail("expected an unreachable service to fail")
            } catch MediaProbeError.serviceUnavailable {}
        }
    }

    func testAServiceThatNeverRepliesTimesOut() async throws {
        let video = dir.appendingPathComponent("clip.mov")
        try Data().write(to: video)
        let service = SilentService()
        let listener = NSXPCListener.anonymous()
        listener.delegate = service
        listener.resume()
        defer {
            listener.invalidate()
            service.invalidateConnections()
        }
        let endpoint = listener.endpoint
        try await withinTestDeadline {
            let client = MediaServiceClient(timeout: .seconds(1), connect: { NSXPCConnection(listenerEndpoint: endpoint) })
            let start = ContinuousClock.now
            do {
                _ = try await client.inspect(fileAt: video)
                XCTFail("expected a silent service to time out")
            } catch MediaProbeError.serviceUnavailable {}
            let elapsed = ContinuousClock.now - start
            XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(950))
            XCTAssertLessThan(elapsed, .seconds(5))
            XCTAssertEqual(service.requestCount, 1)
        }
    }

    private func withinTestDeadline(_ operation: @escaping @Sendable () async throws -> Void) async throws {
        let done = XCTestExpectation(description: "media request completed")
        let task = Task.detached {
            defer { done.fulfill() }
            try await operation()
        }
        defer { task.cancel() }
        guard await XCTWaiter.fulfillment(of: [done], timeout: 15) == .completed else {
            XCTFail("media request exceeded the test deadline")
            return
        }
        try await task.value
    }

    private static func writeVideo(to url: URL) async throws {
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

    func invalidateConnections() {
        let accepted = lock.withLock {
            defer {
                connections.removeAll()
                held.removeAll()
            }
            return connections
        }
        for connection in accepted { connection.invalidate() }
    }

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
