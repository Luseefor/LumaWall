import CoreGraphics
import Foundation

public struct WallpaperID: Hashable, Codable, Sendable, RawRepresentable {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init() { rawValue = UUID() }
}

public struct DisplayID: Hashable, Codable, Sendable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public enum ContentMode: String, Codable, CaseIterable, Sendable {
    case fill
    case fit
    case stretch
}

public struct DisplayComposition: Codable, Equatable, Sendable {
    public var contentMode: ContentMode
    public var focalPoint: CGPoint
    public var scale: Double
    public var rotationDegrees: Double
    public var offset: CGPoint

    public init(
        contentMode: ContentMode = .fill,
        focalPoint: CGPoint = CGPoint(x: 0.5, y: 0.5),
        scale: Double = 1,
        rotationDegrees: Double = 0,
        offset: CGPoint = .zero
    ) {
        self.contentMode = contentMode
        self.focalPoint = focalPoint
        self.scale = scale
        self.rotationDegrees = rotationDegrees
        self.offset = offset
    }
}

public struct DisplayAssignment: Codable, Equatable, Sendable, Identifiable {
    public var id: DisplayID { displayID }
    public let displayID: DisplayID
    public var wallpaperID: WallpaperID?
    public var composition: DisplayComposition
    public var isEnabled: Bool

    public init(
        displayID: DisplayID,
        wallpaperID: WallpaperID? = nil,
        composition: DisplayComposition = .init(),
        isEnabled: Bool = true
    ) {
        self.displayID = displayID
        self.wallpaperID = wallpaperID
        self.composition = composition
        self.isEnabled = isEnabled
    }
}

public struct WallpaperAsset: Codable, Equatable, Sendable, Identifiable {
    public let id: WallpaperID
    public var name: String
    public var mediaURL: URL
    public var posterURL: URL?
    public var duration: TimeInterval
    public var framesPerSecond: Double
    public var pixelSize: CGSize
    public var contentHash: String
    public var containsAudio: Bool

    public init(
        id: WallpaperID = .init(),
        name: String,
        mediaURL: URL,
        posterURL: URL? = nil,
        duration: TimeInterval,
        framesPerSecond: Double,
        pixelSize: CGSize,
        contentHash: String,
        containsAudio: Bool
    ) {
        self.id = id
        self.name = name
        self.mediaURL = mediaURL
        self.posterURL = posterURL
        self.duration = duration
        self.framesPerSecond = framesPerSecond
        self.pixelSize = pixelSize
        self.contentHash = contentHash
        self.containsAudio = containsAudio
    }
}
