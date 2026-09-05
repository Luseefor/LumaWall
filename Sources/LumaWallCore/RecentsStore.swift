import Foundation

public actor RecentsStore {
    public static let limit = 10

    private let fileURL: URL
    private var ids: [WallpaperID] = []

    public init(rootURL: URL? = nil) throws {
        let base = try StorePaths.appSupportBase(rootURL: rootURL)
        self.fileURL = base.appendingPathComponent("Recents.json")
        if let decoded: [WallpaperID] = StoreIO.readJSON(from: fileURL, as: [WallpaperID].self) {
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
        try StoreIO.writeJSON(ids, to: fileURL)
    }
}
