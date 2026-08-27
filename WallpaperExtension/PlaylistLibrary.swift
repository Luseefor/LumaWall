import Foundation

struct ExtensionWallpaperPlaylist: Codable, Sendable {
    let id: UUID
    var name: String
    var entryIDs: [String]
    var shuffle: Bool
    var intervalMinutes: Int
    var isEnabled: Bool
    var createdAt: Date
}

enum ExtensionPlaylistLibrary {
    static let choicePrefix = "playlist:"

    private static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/lumawall-playlists.json")
    }

    static func load() -> [ExtensionWallpaperPlaylist] {
        guard let data = try? Data(contentsOf: fileURL),
              let playlists = try? JSONDecoder().decode([ExtensionWallpaperPlaylist].self, from: data)
        else { return [] }
        return playlists
    }

    static func choiceID(for playlist: ExtensionWallpaperPlaylist) -> String {
        choicePrefix + playlist.id.uuidString
    }

    static func isShuffleChoice(_ id: String?) -> Bool {
        guard let id else { return false }
        return id == shuffleChoiceID || id.hasPrefix(choicePrefix)
    }

    static func playlist(forChoiceID id: String) -> ExtensionWallpaperPlaylist? {
        guard id.hasPrefix(choicePrefix),
              let uuid = UUID(uuidString: String(id.dropFirst(choicePrefix.count)))
        else { return nil }
        return load().first { $0.id == uuid }
    }

    static func videoIDs(forChoiceID id: String) -> [String] {
        let available = Set(VideoLibrary.shared.entries.map(\.id))
        if id == shuffleChoiceID {
            return VideoLibrary.shared.entries.map(\.id)
        }
        guard let playlist = playlist(forChoiceID: id) else { return [] }
        return playlist.entryIDs.filter(available.contains)
    }

    static func defaultFrequency(for playlist: ExtensionWallpaperPlaylist) -> ShuffleFrequencyID {
        switch playlist.intervalMinutes {
        case ...5: .fiveMinutes
        case ...15: .fifteenMinutes
        case ...30: .thirtyMinutes
        case ...60: .oneHour
        default: .oneDay
        }
    }
}
