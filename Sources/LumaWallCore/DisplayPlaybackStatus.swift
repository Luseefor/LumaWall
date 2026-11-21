import Foundation

/// Why a display is paused, or playing a lighter copy. Shared by the
/// extension, which decides it, and the app, which shows it, so the two
/// can't disagree on a name. Raw values are the wire format.
public enum PlaybackStatusReason: String, Codable, Sendable, CaseIterable {
    // Paused.
    case userPause
    case covered
    case fullscreenApp
    case gameMode
    case displayAsleep
    case displayDimmed
    case batteryCritical
    case batteryStatic
    case desktopPaused
    case screensaver
    case suspended
    // Playing, with a lighter copy or a lower rate.
    case batteryTier
    case lowPowerMode
    case thermal

    /// A short phrase that completes "Paused: …" or "Playing lighter: …".
    public var phrase: String {
        switch self {
        case .userPause: "paused by you"
        case .covered: "covered by a window"
        case .fullscreenApp: "a full-screen app is open"
        case .gameMode: "Game Mode is on"
        case .displayAsleep: "display asleep"
        case .displayDimmed: "display dimmed to zero"
        case .batteryCritical: "battery nearly empty"
        case .batteryStatic: "still image on battery"
        case .desktopPaused: "plays on the lock screen only"
        case .screensaver: "a screen saver is showing"
        case .suspended: "macOS suspended it"
        case .batteryTier: "on battery"
        case .lowPowerMode: "Low Power Mode"
        case .thermal: "Mac is running hot"
        }
    }
}

/// The copy of the video a display plays.
public enum PlaybackCopy: String, Codable, Sendable, CaseIterable {
    case full
    case p1440
    case p1080
    case p720

    public var label: String {
        switch self {
        case .full: "Full"
        case .p1440: "1440p"
        case .p1080: "1080p"
        case .p720: "720p"
        }
    }

    /// The copy a library file is, from its name. The importer names its
    /// copies by tier; anything else is the original.
    public init(filename: String) {
        switch filename {
        case "Wallpaper.qhd.mov": self = .p1440
        case "Wallpaper.reduced.mov": self = .p1080
        case "Wallpaper.minimal.mov": self = .p720
        default: self = .full
        }
    }
}

/// What one display is doing now.
public struct DisplayPlaybackStatus: Codable, Equatable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable {
        case playing
        case paused
    }

    /// Which engine draws this display. Overlay is Safe mode.
    public enum Engine: String, Codable, Sendable {
        case native
        case overlay
    }

    public var displayID: UInt32
    public var state: State
    public var reason: PlaybackStatusReason?
    /// The copy being played or held; nil when nothing is loaded.
    public var copy: PlaybackCopy?
    public var frameRate: Int?
    public var engine: Engine

    public var id: UInt32 { displayID }

    public init(
        displayID: UInt32,
        state: State,
        reason: PlaybackStatusReason? = nil,
        copy: PlaybackCopy? = nil,
        frameRate: Int? = nil,
        engine: Engine = .native
    ) {
        self.displayID = displayID
        self.state = state
        self.reason = reason
        self.copy = copy
        self.frameRate = frameRate
        self.engine = engine
    }

    /// "Playing", "Paused" or "Playing lighter".
    public var headline: String {
        switch state {
        case .paused: "Paused"
        case .playing: reason == nil ? "Playing" : "Playing lighter"
        }
    }

    /// The copy and rate, like "1080p · 30 fps". Nil when unknown.
    public var copyDetail: String? {
        var parts: [String] = []
        if let copy { parts.append(copy.label) }
        if let frameRate, frameRate > 0 { parts.append("\(frameRate) fps") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// One line for a row: "Paused · covered by a window",
    /// "Playing · 1080p · 30 fps · on battery".
    public var summary: String {
        var parts = [state == .paused ? "Paused" : "Playing"]
        if state == .playing, let copyDetail { parts.append(copyDetail) }
        if let reason { parts.append(reason.phrase) }
        if engine == .overlay { parts.append("Safe mode") }
        return parts.joined(separator: " · ")
    }

    /// The same, spelled for VoiceOver.
    public func accessibilityLabel(displayName: String) -> String {
        var sentence = "\(displayName): \(state == .paused ? "paused" : "playing")"
        if state == .playing, let copy {
            sentence += " the \(copy.label) copy"
            if let frameRate, frameRate > 0 { sentence += " at \(frameRate) frames per second" }
        }
        if let reason { sentence += ", \(reason.phrase)" }
        if engine == .overlay { sentence += ", in Safe mode" }
        return sentence
    }
}

/// The file the extension writes and the app reads.
public struct PlaybackStatusSnapshot: Codable, Equatable, Sendable {
    public static let fileName = "playback-status.json"
    public static let version = 1
    /// Posted (Darwin) after the file changes; the app re-reads on it.
    public static let notificationName = "app.lumawall.personal.playbackStatusChanged"

    public var version: Int
    public var statuses: [DisplayPlaybackStatus]

    public init(statuses: [DisplayPlaybackStatus]) {
        version = Self.version
        self.statuses = statuses.sorted { $0.displayID < $1.displayID }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    /// Nil for bytes that aren't a snapshot of a version this build reads.
    public static func decode(_ data: Data) -> PlaybackStatusSnapshot? {
        guard let snapshot = try? JSONDecoder().decode(PlaybackStatusSnapshot.self, from: data),
            snapshot.version == Self.version
        else { return nil }
        return snapshot
    }

    public func status(forDisplay id: UInt32) -> DisplayPlaybackStatus? {
        statuses.first { $0.displayID == id }
    }
}
