import Foundation

public struct PlaylistPlaybackState: Codable, Equatable, Sendable {
    public var playlistID: PlaylistID
    public var orderedIDs: [WallpaperID]
    public var cursor: Int
    public var nextAdvanceAt: Date?

    public init(
        playlistID: PlaylistID,
        orderedIDs: [WallpaperID],
        cursor: Int,
        nextAdvanceAt: Date? = nil
    ) {
        self.playlistID = playlistID
        self.orderedIDs = orderedIDs
        self.cursor = cursor
        self.nextAdvanceAt = nextAdvanceAt
    }
}

public actor PlaylistPlaybackStore {
    private let fileURL: URL
    private var value: PlaylistPlaybackState?

    public init(rootURL: URL? = nil) throws {
        let base = try StorePaths.appSupportBase(rootURL: rootURL)
        fileURL = base.appendingPathComponent("PlaylistPlayback.json")
        value = StoreIO.readJSON(from: fileURL, as: PlaylistPlaybackState.self)
    }

    public func current() -> PlaylistPlaybackState? { value }

    public func save(_ state: PlaylistPlaybackState) throws {
        value = state
        try StoreIO.writeJSON(state, to: fileURL)
    }

    public func clear() throws {
        value = nil
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }
}
