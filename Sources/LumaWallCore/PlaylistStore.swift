import Foundation

public struct PlaylistID: Hashable, Codable, Sendable, RawRepresentable, Identifiable {
    public var id: UUID { rawValue }
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init() { rawValue = UUID() }
}

public struct WallpaperPlaylist: Codable, Equatable, Sendable, Identifiable {
    public let id: PlaylistID
    public var name: String
    public var wallpaperIDs: [WallpaperID]
    public var shuffled: Bool
    public var intervalMinutes: Int
    public var createdAt: Date

    public init(
        id: PlaylistID = .init(),
        name: String,
        wallpaperIDs: [WallpaperID] = [],
        shuffled: Bool = false,
        intervalMinutes: Int = 30,
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.wallpaperIDs = wallpaperIDs
        self.shuffled = shuffled
        self.intervalMinutes = intervalMinutes
        self.createdAt = createdAt
    }
}

public actor PlaylistStore {
    private let fileURL: URL
    private var playlists: [PlaylistID: WallpaperPlaylist] = [:]

    public init(rootURL: URL? = nil) throws {
        let base = try StorePaths.appSupportBase(rootURL: rootURL)
        self.fileURL = base.appendingPathComponent("Playlists.json")
        if let decoded: [WallpaperPlaylist] = StoreIO.readJSON(from: fileURL, as: [WallpaperPlaylist].self) {
            playlists = Dictionary(uniqueKeysWithValues: decoded.map { ($0.id, $0) })
        }
    }

    public func all() -> [WallpaperPlaylist] {
        playlists.values.sorted { $0.createdAt > $1.createdAt }
    }

    public func upsert(_ playlist: WallpaperPlaylist) throws {
        playlists[playlist.id] = playlist
        try persist()
    }

    public func remove(id: PlaylistID) throws {
        playlists.removeValue(forKey: id)
        try persist()
    }

    private func persist() throws {
        let values = playlists.values.sorted { $0.createdAt > $1.createdAt }
        try StoreIO.writeJSON(values, to: fileURL)
    }
}
