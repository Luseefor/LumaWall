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
        let base = rootURL ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("LumaWall", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("PlaylistPlayback.json")
        if let data = try? Data(contentsOf: fileURL) {
            value = try? JSONDecoder.lumaWall.decode(PlaylistPlaybackState.self, from: data)
        }
    }

    public func current() -> PlaylistPlaybackState? { value }

    public func save(_ state: PlaylistPlaybackState) throws {
        value = state
        let data = try JSONEncoder.lumaWall.encode(state)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    public func clear() throws {
        value = nil
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }
}
