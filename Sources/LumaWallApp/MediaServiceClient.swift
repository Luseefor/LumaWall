import Foundation
import LumaWallCore

/// `MediaProbing` through LumaWallMediaService, the sandboxed XPC service
/// embedded in the app. Each request opens its own connection, so a service
/// that crashes on one file can't fail the next request, and a request that
/// takes longer than `timeout` fails instead of hanging the import.
///
/// Replies are checked before use: `MediaInfo.isPlausible`, and a poster's
/// pixel buffer must match its stated size.
final class MediaServiceClient: MediaProbing {
    static let shared = MediaServiceClient()

    private let timeout: Duration
    private let connect: @Sendable () -> NSXPCConnection

    convenience init(serviceName: String = MediaServiceContract.serviceName, timeout: Duration = .seconds(120)) {
        self.init(timeout: timeout, connect: { NSXPCConnection(serviceName: serviceName) })
    }

    init(timeout: Duration, connect: @escaping @Sendable () -> NSXPCConnection) {
        self.timeout = timeout
        self.connect = connect
    }

    func inspect(_ file: FileHandle, typeIdentifier: String) async throws -> MediaInfo {
        let info = try await call(MediaInfo.self, maxReplyBytes: MediaServiceContract.maxInfoReplyBytes) {
            $0.inspect(file, typeIdentifier: typeIdentifier, reply: $1)
        }
        guard info.isPlausible else { throw MediaProbeError.unsupportedMedia }
        return info
    }

    func posterFrame(_ file: FileHandle, typeIdentifier: String, maxPixelSize: CGSize?, nearStart: Bool) async throws
        -> PosterFrame
    {
        let limit = MediaServiceContract.maxPosterReplyBytes(fitting: maxPixelSize)
        let frame = try await call(PosterFrame.self, maxReplyBytes: limit) {
            $0.posterFrame(
                file, typeIdentifier: typeIdentifier, maxWidth: Double(maxPixelSize?.width ?? 0),
                maxHeight: Double(maxPixelSize?.height ?? 0), nearStart: nearStart, reply: $1)
        }
        guard frame.fits(maxPixelSize), frame.makeImage() != nil else { throw MediaProbeError.posterUnavailable }
        return frame
    }

    private func call<T: Decodable & Sendable>(
        _ type: T.Type, maxReplyBytes: Int, _ send: (MediaServiceXPC, @escaping @Sendable (Data?, Data?) -> Void) -> Void
    ) async throws -> T {
        let connection = connect()
        connection.remoteObjectInterface = MediaServiceContract.interface()
        connection.resume()
        defer { connection.invalidate() }
        let (seconds, attoseconds) = timeout.components
        let delay = Double(seconds) + Double(attoseconds) / 1e18
        let deadline = DispatchWallTime.now() + delay
        return try await withCheckedThrowingContinuation { continuation in
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            let pending = Pending(continuation, timer: timer)
            timer.schedule(wallDeadline: deadline)
            timer.setEventHandler { [weak connection] in
                guard let continuation = pending.take() else { return }
                connection?.invalidate()
                continuation.resume(throwing: MediaProbeError.serviceUnavailable)
            }
            timer.activate()
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
                pending.finish(.failure(MediaProbeError.serviceUnavailable))
            }
            guard let service = proxy as? MediaServiceXPC else {
                pending.finish(.failure(MediaProbeError.serviceUnavailable))
                return
            }
            send(service) { reply, error in
                guard let continuation = pending.take() else { return }
                continuation.resume(
                    with: Result { try MediaServiceContract.decode(T.self, reply: reply, error: error, maxReplyBytes: maxReplyBytes) })
            }
        }
    }

    /// Resumes the continuation once, from the reply, the error handler or
    /// the timeout, whichever comes first.
    private final class Pending<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, any Error>?
        private var timer: DispatchSourceTimer?

        init(_ continuation: CheckedContinuation<T, any Error>, timer: DispatchSourceTimer) {
            self.continuation = continuation
            self.timer = timer
        }

        /// The continuation, if nothing has resumed it yet. The caller must
        /// resume it.
        func take() -> CheckedContinuation<T, any Error>? {
            // Clearing the timer also breaks the cycle between it and this.
            let (taken, timer) = lock.withLock {
                defer {
                    continuation = nil
                    self.timer = nil
                }
                return (continuation, self.timer)
            }
            if taken != nil { timer?.cancel() }
            return taken
        }

        func finish(_ result: Result<T, any Error>) {
            take()?.resume(with: result)
        }
    }
}
