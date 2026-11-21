import Foundation

/// Decides when native mode has stopped working on a display because the
/// wallpaper extension no longer serves it (ADR 0003).
///
/// The app pings the extension; the extension answers with the displays it
/// holds a desktop surface for. A display missing from fresh answers for
/// `timeout` falls back to Safe mode. Probes only run while someone can see
/// a native desktop, and every event that can make macOS drop and re-acquire
/// surfaces on its own (launch, wake, unlock, a display change, a Space
/// switch, the screen saver ending, a store write) starts a grace period and
/// forgets earlier misses.
///
/// Times are seconds on a monotonic clock that the caller supplies.
public struct ExtensionHealth: Sendable, Equatable {
    public static let timeout: TimeInterval = 20
    /// Quiet time after a disturbance. Longer than a WallpaperAgent restart
    /// plus re-acquire.
    public static let grace: TimeInterval = 30
    public static let healthyInterval: TimeInterval = 10
    /// Probe sooner while a display is missing, so a fallback lands close
    /// to `timeout` after the first miss.
    public static let suspectInterval: TimeInterval = 4
    /// How long the app waits for the extension to answer a probe.
    public static let replyWait: TimeInterval = 3

    public struct Conditions: Sendable, Equatable {
        public var nativeActive: Bool
        public var sessionLocked: Bool
        public var displaysAsleep: Bool
        public var screenSaverRunning: Bool

        public init(nativeActive: Bool, sessionLocked: Bool, displaysAsleep: Bool, screenSaverRunning: Bool) {
            self.nativeActive = nativeActive
            self.sessionLocked = sessionLocked
            self.displaysAsleep = displaysAsleep
            self.screenSaverRunning = screenSaverRunning
        }

        /// The extension may legitimately idle or be suspended otherwise.
        public var allowsProbing: Bool {
            nativeActive && !sessionLocked && !displaysAsleep && !screenSaverRunning
        }
    }

    /// The extension's answer file. `pid` and `sequence` change on every
    /// answer, so the app can tell a new answer from the last one.
    public struct Reply: Sendable, Equatable, Codable {
        public var pid: Int32
        public var sequence: UInt64
        /// CoreGraphics display IDs with a live (non-preview) surface.
        public var served: Set<UInt32>

        public static let fileName = "lumawall-health.json"
        public static let maxFileSize = 16 * 1024

        public init(pid: Int32, sequence: UInt64, served: Set<UInt32>) {
            self.pid = pid
            self.sequence = sequence
            self.served = served
        }

        /// The extension can write its container, so the file is untrusted.
        public static func decode(_ data: Data) -> Reply? {
            guard data.count <= maxFileSize else { return nil }
            return try? JSONDecoder().decode(Reply.self, from: data)
        }
    }

    public private(set) var quietUntil: TimeInterval
    /// When each watched display was first missing from a fresh answer.
    public private(set) var missingSince: [UInt32: TimeInterval] = [:]
    /// Set once the extension has answered, this session or (`heardBefore`)
    /// an earlier one of the same build. An extension that never answered
    /// is likely an older build still running after an update, so silence
    /// alone doesn't fall anything back until then.
    public private(set) var hasHeardReply = false
    private var pendingSentAt: TimeInterval?
    private var pendingPrevious: Reply?

    /// `heardBefore`: this build's extension answered in an earlier session,
    /// so silence counts from the start.
    public init(now: TimeInterval, heardBefore: Bool = false) {
        quietUntil = now + Self.grace
        hasHeardReply = heardBefore
    }

    public mutating func disturb(at now: TimeInterval) {
        quietUntil = max(quietUntil, now + Self.grace)
        missingSince = [:]
        pendingSentAt = nil
        pendingPrevious = nil
    }

    public func canProbe(_ conditions: Conditions, at now: TimeInterval) -> Bool {
        conditions.allowsProbing && now >= quietUntil && pendingSentAt == nil
    }

    public var nextProbeDelay: TimeInterval {
        missingSince.isEmpty ? Self.healthyInterval : Self.suspectInterval
    }

    /// `previous` is the answer file as it was just before the ping.
    public mutating func probeSent(at now: TimeInterval, previous: Reply?) {
        pendingSentAt = now
        pendingPrevious = previous
    }

    /// Records what the answer file holds `replyWait` after the ping, and
    /// returns the displays to fall back. Each is returned once and then no
    /// longer tracked. A probe a disturbance cancelled returns nothing.
    public mutating func probeFinished(reply: Reply?, watching: Set<UInt32>, at now: TimeInterval) -> Set<UInt32> {
        guard let sentAt = pendingSentAt else { return [] }
        pendingSentAt = nil
        let fresh = reply.flatMap { $0 != pendingPrevious ? $0 : nil }
        pendingPrevious = nil
        if fresh != nil { hasHeardReply = true }
        missingSince = missingSince.filter { watching.contains($0.key) }
        guard fresh != nil || hasHeardReply else { return [] }
        let served = fresh?.served ?? []
        var fallBack = Set<UInt32>()
        for display in watching {
            if served.contains(display) {
                missingSince.removeValue(forKey: display)
                continue
            }
            let since = missingSince[display] ?? sentAt
            if now - since >= Self.timeout {
                fallBack.insert(display)
                missingSince.removeValue(forKey: display)
            } else {
                missingSince[display] = since
            }
        }
        return fallBack
    }
}
