import Foundation

/// LumaWallMediaService: parses imported videos for the app inside App
/// Sandbox with no file-access entitlements. Each request brings an open
/// read-only handle to one file; a decoder exploit here can read that file
/// and nothing else the user owns.
final class MediaService: NSObject, MediaServiceXPC {
    private let probe = LocalMediaProbe()

    func inspect(_ file: FileHandle, typeIdentifier: String, reply: @escaping @Sendable (Data?, Data?) -> Void) {
        let probe = probe
        Task {
            let result: Result<MediaInfo, MediaProbeError>
            do {
                result = .success(try await probe.inspect(file, typeIdentifier: typeIdentifier))
            } catch {
                result = .failure(error as? MediaProbeError ?? .unsupportedMedia)
            }
            let (data, failure) = MediaServiceContract.encode(result)
            reply(data, failure)
        }
    }

    func posterFrame(
        _ file: FileHandle, typeIdentifier: String, maxWidth: Double, maxHeight: Double, nearStart: Bool,
        reply: @escaping @Sendable (Data?, Data?) -> Void
    ) {
        let probe = probe
        let size = maxWidth > 0 && maxHeight > 0 ? CGSize(width: maxWidth, height: maxHeight) : nil
        Task {
            let result: Result<PosterFrame, MediaProbeError>
            do {
                result = .success(
                    try await probe.posterFrame(file, typeIdentifier: typeIdentifier, maxPixelSize: size, nearStart: nearStart))
            } catch {
                result = .failure(error as? MediaProbeError ?? .posterUnavailable)
            }
            let (data, failure) = MediaServiceContract.encode(result)
            reply(data, failure)
        }
    }
}

final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = MediaServiceContract.interface()
        connection.exportedObject = MediaService()
        connection.resume()
        return true
    }
}

let delegate = ServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
