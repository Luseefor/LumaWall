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

public enum WallpaperCategory: String, Codable, CaseIterable, Sendable, Identifiable {
    case nature, space, urban, abstract, anime, minimal, monochrome, other

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .nature: "Nature"
        case .space: "Space"
        case .urban: "Urban"
        case .abstract: "Abstract"
        case .anime: "Anime"
        case .minimal: "Minimal"
        case .monochrome: "Monochrome"
        case .other: "Other"
        }
    }

    public var symbol: String {
        switch self {
        case .nature: "leaf.fill"
        case .space: "sparkles"
        case .urban: "building.2.fill"
        case .abstract: "waveform"
        case .anime: "paintpalette.fill"
        case .minimal: "circle.grid.2x2.fill"
        case .monochrome: "circle.lefthalf.filled"
        case .other: "square.grid.2x2.fill"
        }
    }
}

public enum LibrarySort: String, Codable, CaseIterable, Sendable, Identifiable {
    case newest, oldest, name, resolution, mostUsed

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .newest: "Newest"
        case .oldest: "Oldest"
        case .name: "Name"
        case .resolution: "Resolution"
        case .mostUsed: "Most used"
        }
    }
}

public enum ResolutionFilter: String, Codable, CaseIterable, Sendable, Identifiable {
    case all, hd, qhd, fourK

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: "All sizes"
        case .hd: "1080p+"
        case .qhd: "1440p+"
        case .fourK: "4K"
        }
    }

    public func matches(_ size: CGSize) -> Bool {
        let short = min(size.width, size.height)
        switch self {
        case .all: return true
        case .hd: return short >= 1_080
        case .qhd: return short >= 1_440
        case .fourK: return max(size.width, size.height) >= 3_840 || short >= 2_160
        }
    }
}

public struct DisplayComposition: Codable, Equatable, Sendable {
    public var contentMode: ContentMode
    public var focalPoint: CGPoint
    public var scale: Double
    public var rotationDegrees: Double
    public var offset: CGPoint
    /// Global Cocoa-coordinate canvas shared by multiple displays. When present,
    /// each display renders only the portion of this canvas intersecting its frame.
    public var spanningCanvas: CGRect?

    public init(
        contentMode: ContentMode = .fill,
        focalPoint: CGPoint = CGPoint(x: 0.5, y: 0.5),
        scale: Double = 1,
        rotationDegrees: Double = 0,
        offset: CGPoint = .zero,
        spanningCanvas: CGRect? = nil
    ) {
        self.contentMode = contentMode
        self.focalPoint = focalPoint
        self.scale = scale
        self.rotationDegrees = rotationDegrees
        self.offset = offset
        self.spanningCanvas = spanningCanvas
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
    public var category: WallpaperCategory
    public var createdAt: Date
    public var applyCount: Int
    public var lastAppliedAt: Date?

    public init(
        id: WallpaperID = .init(),
        name: String,
        mediaURL: URL,
        posterURL: URL? = nil,
        duration: TimeInterval,
        framesPerSecond: Double,
        pixelSize: CGSize,
        contentHash: String,
        containsAudio: Bool,
        category: WallpaperCategory = .other,
        createdAt: Date = .now,
        applyCount: Int = 0,
        lastAppliedAt: Date? = nil
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
        self.category = category
        self.createdAt = createdAt
        self.applyCount = applyCount
        self.lastAppliedAt = lastAppliedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(WallpaperID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        mediaURL = try container.decode(URL.self, forKey: .mediaURL)
        posterURL = try container.decodeIfPresent(URL.self, forKey: .posterURL)
        duration = try container.decode(TimeInterval.self, forKey: .duration)
        framesPerSecond = try container.decode(Double.self, forKey: .framesPerSecond)
        pixelSize = try container.decode(CGSize.self, forKey: .pixelSize)
        contentHash = try container.decode(String.self, forKey: .contentHash)
        containsAudio = try container.decode(Bool.self, forKey: .containsAudio)
        category = try container.decodeIfPresent(WallpaperCategory.self, forKey: .category) ?? .other
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        applyCount = try container.decodeIfPresent(Int.self, forKey: .applyCount) ?? 0
        lastAppliedAt = try container.decodeIfPresent(Date.self, forKey: .lastAppliedAt)
    }

    public var resolutionLabel: String {
        let w = Int(pixelSize.width)
        let h = Int(pixelSize.height)
        if max(w, h) >= 3_840 || min(w, h) >= 2_160 { return "4K" }
        if min(w, h) >= 1_440 { return "1440p" }
        if min(w, h) >= 1_080 { return "1080p" }
        return "\(w)×\(h)"
    }
}
