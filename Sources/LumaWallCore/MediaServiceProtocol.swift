import CoreGraphics
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

    /// `(reply, error)` for an XPC reply block. Slashes stay unescaped:
    /// base64 of bright pixels is mostly `/`, and escaping each one would
    /// push a poster past `maxPosterReplyBytes`.
    public static func encode<T: Encodable>(_ result: Result<T, MediaProbeError>) -> (Data?, Data?) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return switch result {
        case .success(let value): ((try? encoder.encode(value)), nil)
        case .failure(let error): (nil, try? encoder.encode(error))
        }
    }

    /// Largest metadata reply (`MediaInfo`) the app decodes.
    public static let maxInfoReplyBytes = 16_384
    /// Largest error reply the app decodes.
    public static let maxErrorReplyBytes = 1_024

    /// Largest poster reply for a frame fitting `box` (or the largest frame
    /// the service makes): its pixels, base64's third more, and room for
    /// the other fields.
    public static func maxPosterReplyBytes(fitting box: CGSize?) -> Int {
        let side = Double(PosterFrame.maxSide)
        let width = min(box.map { Double($0.width) } ?? side, side).rounded(.up)
        let height = min(box.map { Double($0.height) } ?? side, side).rounded(.up)
        return Int(width * height * 4 * 4 / 3) + 4_096
    }

    /// The value in an XPC reply. A reply over `maxReplyBytes`, an error
    /// over `maxErrorReplyBytes`, or anything that doesn't decode counts as
    /// the service failing; sizes are checked before decoding.
    public static func decode<T: Decodable>(_ type: T.Type, reply: Data?, error: Data?, maxReplyBytes: Int) throws -> T {
        if let error {
            guard error.count <= maxErrorReplyBytes else { throw MediaProbeError.serviceUnavailable }
            throw (try? JSONDecoder().decode(MediaProbeError.self, from: error)) ?? MediaProbeError.serviceUnavailable
        }
        guard let reply, reply.count <= maxReplyBytes, let value = try? JSONDecoder().decode(type, from: reply) else {
            throw MediaProbeError.serviceUnavailable
        }
        return value
    }
}

/// The media service's running requests. At most `limit` run at once;
/// more are refused. A connection that goes away cancels its requests.
/// A request still running after `deadline`, cancelled or not, calls
/// `onOverrun`, which in the service ends the process: launchd starts a
/// fresh one on the next request, and a decode stuck past cancellation
/// stops holding its file and a CPU.
public final class MediaServiceWork: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private let deadline: Duration
    private let onOverrun: @Sendable () -> Void
    /// Removed only when the work returns, so cancelled work that ignores
    /// cancellation still counts and still trips the deadline.
    private var running: [UUID: Task<Void, Never>] = [:]

    public init(limit: Int = 4, deadline: Duration = .seconds(110), onOverrun: @escaping @Sendable () -> Void) {
        self.limit = limit
        self.deadline = deadline
        self.onOverrun = onOverrun
    }

    public var activeCount: Int { lock.withLock { running.count } }

    /// Starts `work`, or returns nil when `limit` requests are running.
    public func start(_ work: @escaping @Sendable () async -> Void) -> UUID? {
        let id = UUID()
        let accepted = lock.withLock { () -> Bool in
            guard running.count < limit else { return false }
            running[id] = Task {
                await work()
                self.finish(id)
            }
            return true
        }
        guard accepted else { return nil }
        let deadline = deadline
        Task.detached { [weak self] in
            try? await Task.sleep(for: deadline)
            guard let self, self.isRunning(id) else { return }
            self.onOverrun()
        }
        return id
    }

    public func cancel(_ ids: some Sequence<UUID>) {
        let tasks = lock.withLock { ids.compactMap { running[$0] } }
        for task in tasks { task.cancel() }
    }

    private func finish(_ id: UUID) {
        _ = lock.withLock { running.removeValue(forKey: id) }
    }

    private func isRunning(_ id: UUID) -> Bool {
        lock.withLock { running[id] != nil }
    }
}
