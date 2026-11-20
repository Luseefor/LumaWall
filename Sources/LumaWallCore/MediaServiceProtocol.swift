import Foundation

/// The XPC contract between the app and LumaWallMediaService. Requests
/// carry an open read-only file handle; replies are JSON (`MediaInfo`,
/// `PosterFrame`) or a `MediaProbeError`, so both sides share one Codable
/// shape instead of NSSecureCoding classes.
///
/// Compiled into LumaWallCore and into the media service.
@objc public protocol MediaServiceXPC {
    func inspect(_ file: FileHandle, typeIdentifier: String, reply: @escaping @Sendable (Data?, Data?) -> Void)
    func posterFrame(
        _ file: FileHandle, typeIdentifier: String, maxWidth: Double, maxHeight: Double, nearStart: Bool,
        reply: @escaping @Sendable (Data?, Data?) -> Void)
}

public enum MediaServiceContract {
    /// The service's bundle identifier, which is also its XPC name.
    public static let serviceName = "app.lumawall.personal.media"

    public static func interface() -> NSXPCInterface {
        NSXPCInterface(with: MediaServiceXPC.self)
    }

    /// `(reply, error)` for an XPC reply block.
    public static func encode<T: Encodable>(_ result: Result<T, MediaProbeError>) -> (Data?, Data?) {
        switch result {
        case .success(let value): ((try? JSONEncoder().encode(value)), nil)
        case .failure(let error): (nil, try? JSONEncoder().encode(error))
        }
    }

    /// The value in an XPC reply. Anything that doesn't decode counts as the
    /// service failing.
    public static func decode<T: Decodable>(_ type: T.Type, reply: Data?, error: Data?) throws -> T {
        if let error {
            throw (try? JSONDecoder().decode(MediaProbeError.self, from: error)) ?? MediaProbeError.serviceUnavailable
        }
        guard let reply, let value = try? JSONDecoder().decode(type, from: reply) else {
            throw MediaProbeError.serviceUnavailable
        }
        return value
    }
}
