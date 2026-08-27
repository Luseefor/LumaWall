import Foundation

public actor RecentsStore {
    public static let limit = 10

    private let fileURL: URL
    private var ids: [WallpaperID] = []

    public init(rootURL: URL? = nil) throws {
        let base = rootURL ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("LumaWall", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.fileURL = base.appendingPathComponent("Recents.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder.lumaWall.decode([WallpaperID].self, from: data) {
            ids = decoded
        }
    }

    public func all() -> [WallpaperID] { ids }

    public func push(_ id: WallpaperID) throws {
        ids.removeAll { $0 == id }
        ids.insert(id, at: 0)
        if ids.count > Self.limit { ids = Array(ids.prefix(Self.limit)) }
        try persist()
    }

    public func clear() throws {
        ids = []
        try persist()
    }

    public func remove(_ id: WallpaperID) throws {
        ids.removeAll { $0 == id }
        try persist()
    }

    private func persist() throws {
        let data = try JSONEncoder.lumaWall.encode(ids)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUnlessOpen])
    }
}
