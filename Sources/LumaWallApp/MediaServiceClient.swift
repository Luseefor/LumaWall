import Foundation
import LumaWallCore

/// `MediaProbing` through LumaWallMediaService, the sandboxed XPC service
/// embedded in the app. Each request opens its own connection, so a service
/// that crashes on one file can't fail the next request, and a request that
/// takes longer than `timeout` fails instead of hanging the import.
///
/// A service that hasn't answered by then is stuck, and later requests
/// would queue behind it, each waiting out its own timeout. So a timeout
/// also ends the service process (`onTimeout`); launchd starts a fresh one
/// for the next request.
///
/// Replies are checked before use: `MediaInfo.isPlausible`, and a poster's
/// pixel buffer must match its stated size.
final class MediaServiceClient: MediaProbing {
    static let shared = MediaServiceClient()

    private let timeout: Duration
    private let connect: @Sendable () -> NSXPCConnection
    private let onTimeout: @Sendable (NSXPCConnection) -> Void

    convenience init(serviceName: String = MediaServiceContract.serviceName, timeout: Duration = .seconds(120)) {
        self.init(timeout: timeout, connect: { NSXPCConnection(serviceName: serviceName) }, onTimeout: Self.endService)
    }

    init(
        timeout: Duration, connect: @escaping @Sendable () -> NSXPCConnection,
        onTimeout: @escaping @Sendable (NSXPCConnection) -> Void
    ) {
        self.timeout = timeout
        self.connect = connect
        self.onTimeout = onTimeout
    }

    /// Kills the service on the other end of `connection`. Never this
    /// process: a connection to an in-process listener reports our own pid.
    static func endService(_ connection: NSXPCConnection) {
        let pid = connection.processIdentifier
        guard pid > 0, pid != getpid() else { return }
        kill(pid, SIGKILL)
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
        let onTimeout = onTimeout
        return try await withCheckedThrowingContinuation { continuation in
            let pending = Pending(continuation)
            // A dispatch timer, not a Task: it fires even when the Swift
            // cooperative pool is busy.
            let timer = DispatchWorkItem {
                // Taken first, so a reply racing the timer can't also
                // resume; ended before `invalidate`, while the pid is valid.
                guard let continuation = pending.take() else { return }
                onTimeout(connection)
                continuation.resume(throwing: MediaProbeError.serviceUnavailable)
            }
            pending.timer = timer
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: timer)
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
                pending.finish(.failure(MediaProbeError.serviceUnavailable))
            }
            guard let service = proxy as? MediaServiceXPC else {
                pending.finish(.failure(MediaProbeError.serviceUnavailable))
                return
            }
            send(service) { reply, error in
                pending.finish(
                    Result { try MediaServiceContract.decode(T.self, reply: reply, error: error, maxReplyBytes: maxReplyBytes) })
            }
        }
    }

    /// Resumes the continuation once, from the reply, the error handler or
    /// the timeout, whichever comes first.
    private final class Pending<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, any Error>?
        private var storedTimer: DispatchWorkItem?
        var timer: DispatchWorkItem? {
            get { lock.withLock { storedTimer } }
            set { lock.withLock { storedTimer = newValue } }
        }

        init(_ continuation: CheckedContinuation<T, any Error>) { self.continuation = continuation }

        /// The continuation, if nothing has resumed it yet. The caller must
        /// resume it.
        func take() -> CheckedContinuation<T, any Error>? {
            let (taken, timer) = lock.withLock {
                defer { continuation = nil }
                return (continuation, storedTimer)
            }
            if taken != nil { timer?.cancel() }
            return taken
        }

        func finish(_ result: Result<T, any Error>) {
            take()?.resume(with: result)
        }
    }
}
