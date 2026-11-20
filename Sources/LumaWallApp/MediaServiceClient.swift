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

    private let serviceName: String
    private let timeout: Duration

    init(serviceName: String = MediaServiceContract.serviceName, timeout: Duration = .seconds(120)) {
        self.serviceName = serviceName
        self.timeout = timeout
    }

    func inspect(_ file: FileHandle, typeIdentifier: String) async throws -> MediaInfo {
        let info = try await call(MediaInfo.self) { $0.inspect(file, typeIdentifier: typeIdentifier, reply: $1) }
        guard info.isPlausible else { throw MediaProbeError.unsupportedMedia }
        return info
    }

    func posterFrame(_ file: FileHandle, typeIdentifier: String, maxPixelSize: CGSize?, nearStart: Bool) async throws
        -> PosterFrame
    {
        let frame = try await call(PosterFrame.self) {
            $0.posterFrame(
                file, typeIdentifier: typeIdentifier, maxWidth: Double(maxPixelSize?.width ?? 0),
                maxHeight: Double(maxPixelSize?.height ?? 0), nearStart: nearStart, reply: $1)
        }
        guard frame.makeImage() != nil else { throw MediaProbeError.posterUnavailable }
        return frame
    }

    private func call<T: Decodable & Sendable>(
        _ type: T.Type, _ send: (MediaServiceXPC, @escaping @Sendable (Data?, Data?) -> Void) -> Void
    ) async throws -> T {
        let connection = NSXPCConnection(serviceName: serviceName)
        connection.remoteObjectInterface = MediaServiceContract.interface()
        connection.resume()
        defer { connection.invalidate() }
        let timeout = timeout
        return try await withCheckedThrowingContinuation { continuation in
            let pending = Pending(continuation)
            pending.timer = Task {
                try? await Task.sleep(for: timeout)
                if !Task.isCancelled { pending.finish(.failure(MediaProbeError.serviceUnavailable)) }
            }
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
                pending.finish(.failure(MediaProbeError.serviceUnavailable))
            }
            guard let service = proxy as? MediaServiceXPC else {
                pending.finish(.failure(MediaProbeError.serviceUnavailable))
                return
            }
            send(service) { reply, error in
                pending.finish(Result { try MediaServiceContract.decode(T.self, reply: reply, error: error) })
            }
        }
    }

    /// Resumes the continuation once, from the reply, the error handler or
    /// the timeout, whichever comes first.
    private final class Pending<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, any Error>?
        var timer: Task<Void, Never>? {
            get { lock.withLock { storedTimer } }
            set { lock.withLock { storedTimer = newValue } }
        }
        private var storedTimer: Task<Void, Never>?

        init(_ continuation: CheckedContinuation<T, any Error>) { self.continuation = continuation }

        func finish(_ result: Result<T, any Error>) {
            let (resume, timer) = lock.withLock {
                defer { continuation = nil }
                return (continuation, storedTimer)
            }
            timer?.cancel()
            resume?.resume(with: result)
        }
    }
}
