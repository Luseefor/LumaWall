import Foundation

/// LumaWallMediaService: parses imported videos for the app inside App
/// Sandbox with no file-access entitlements. Each request brings an open
/// read-only handle to one file; a decoder exploit here can read the files
/// it is handed and nothing else the user owns.

/// Every accepted request in the process. A request still pending past
/// its deadline ends the process (see `MediaServiceWork`); the app's client gives up at
/// 120 seconds, after this 110-second deadline.
let work = MediaServiceWork(onOverrun: { exit(EXIT_FAILURE) })

/// One connection's requests, cancelled when the app drops the connection.
final class MediaService: NSObject, MediaServiceXPC, @unchecked Sendable {
    private let probe = LocalMediaProbe()
    private let lock = NSLock()
    private var requests: [UUID] = []

    func cancelAll() {
        work.cancel(lock.withLock { requests })
    }

    func inspect(_ file: FileHandle, typeIdentifier: String, reply: @escaping @Sendable (Data?, Data?) -> Void) {
        let probe = probe
        run(reply) {
            MediaServiceContract.encode(
                await Self.result {
                    try await probe.inspect(file, typeIdentifier: typeIdentifier)
                } fallback: {
                    .unsupportedMedia
                })
        }
    }

    func posterFrame(
        _ file: FileHandle, typeIdentifier: String, maxWidth: Double, maxHeight: Double, nearStart: Bool,
        reply: @escaping @Sendable (Data?, Data?) -> Void
    ) {
        let probe = probe
        let size = maxWidth > 0 && maxHeight > 0 ? CGSize(width: maxWidth, height: maxHeight) : nil
        run(reply) {
            MediaServiceContract.encode(
                await Self.result {
                    try await probe.posterFrame(file, typeIdentifier: typeIdentifier, maxPixelSize: size, nearStart: nearStart)
                } fallback: {
                    .posterUnavailable
                })
        }
    }

    private func run(_ reply: @escaping @Sendable (Data?, Data?) -> Void, _ body: @escaping @Sendable () async -> (Data?, Data?)) {
        let id = work.start {
            let (data, failure) = await body()
            reply(data, failure)
        }
        guard let id else {
            // Too many requests at once: refuse rather than queue.
            let (data, failure) = MediaServiceContract.encode(Result<MediaInfo, MediaProbeError>.failure(.serviceUnavailable))
            reply(data, failure)
            return
        }
        lock.withLock { requests.append(id) }
    }

    private static func result<T>(_ body: () async throws -> T, fallback: () -> MediaProbeError) async -> Result<
        T, MediaProbeError
    > {
        do {
            return .success(try await body())
        } catch {
            return .failure(error as? MediaProbeError ?? fallback())
        }
    }
}

final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let service = MediaService()
        connection.exportedInterface = MediaServiceContract.interface()
        connection.exportedObject = service
        connection.invalidationHandler = { service.cancelAll() }
        connection.interruptionHandler = { service.cancelAll() }
        connection.resume()
        return true
    }
}

let delegate = ServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
