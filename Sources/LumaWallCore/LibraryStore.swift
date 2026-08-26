import Foundation

public actor LibraryStore {
    public enum StoreError: LocalizedError {
        case duplicate(WallpaperAsset)
        case missingAsset

        public var errorDescription: String? {
            switch self {
            case let .duplicate(asset): "This video is already installed as “\(asset.name)”."
            case .missingAsset: "The wallpaper is no longer installed."
            }
        }
    }

    public let rootURL: URL
    private let indexURL: URL
    private var assetsByID: [WallpaperID: WallpaperAsset] = [:]

    public init(rootURL: URL? = nil) throws {
        let base = rootURL ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("LumaWall", isDirectory: true)
        self.rootURL = base
        self.indexURL = base.appendingPathComponent("Library.json")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL),
           let decoded = try? JSONDecoder.lumaWall.decode([WallpaperAsset].self, from: data) {
            assetsByID = Dictionary(uniqueKeysWithValues: decoded.map { ($0.id, $0) })
        }
    }

    public func assets() -> [WallpaperAsset] {
        assetsByID.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func asset(id: WallpaperID) -> WallpaperAsset? { assetsByID[id] }

    public func asset(contentHash: String) -> WallpaperAsset? {
        assetsByID.values.first { $0.contentHash == contentHash }
    }

    public func install(_ asset: WallpaperAsset) throws {
        if let duplicate = assetsByID.values.first(where: { $0.contentHash == asset.contentHash }) {
            throw StoreError.duplicate(duplicate)
        }
        assetsByID[asset.id] = asset
        try persist()
    }

    public func rename(id: WallpaperID, to name: String) throws {
        guard var asset = assetsByID[id] else { throw StoreError.missingAsset }
        asset.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        assetsByID[id] = asset
        try persist()
    }

    public func remove(id: WallpaperID) throws {
        guard let asset = assetsByID.removeValue(forKey: id) else { throw StoreError.missingAsset }
        try persist()
        try? FileManager.default.removeItem(at: asset.mediaURL.deletingLastPathComponent())
    }

    public func folder(for id: WallpaperID) -> URL {
        rootURL.appendingPathComponent(id.rawValue.uuidString, isDirectory: true)
    }

    private func persist() throws {
        let values = assetsByID.values.sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }
        let data = try JSONEncoder.lumaWall.encode(values)
        try data.write(to: indexURL, options: [.atomic, .completeFileProtectionUnlessOpen])
    }
}
