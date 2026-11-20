import Foundation

public actor LibraryStore {
    public enum StoreError: LocalizedError, Equatable {
        case duplicate(WallpaperAsset)
        case missingAsset
        case invalidLocation

        public var errorDescription: String? {
            switch self {
            case let .duplicate(asset): "This video is already installed as \"\(asset.name)\"."
            case .missingAsset: "The wallpaper is no longer installed."
            case .invalidLocation: "The wallpaper points outside the library and was not deleted from disk."
            }
        }
    }

    public let rootURL: URL
    private let indexURL: URL
    private var assetsByID: [WallpaperID: WallpaperAsset] = [:]
    /// True when `Library.json` was there and read at init. False on a first
    /// launch and when the index was unreadable and quarantined, so callers
    /// can tell an empty library from a lost one.
    public nonisolated let loadedIndex: Bool
    /// Last folder-walk result. Cleared whenever the library changes, so the
    /// walk runs once per change instead of once per ask.
    private var cachedDiskUsage: Int64?

    public init(rootURL: URL? = nil) throws {
        let base = try StorePaths.appSupportBase(rootURL: rootURL)
        self.rootURL = base
        self.indexURL = base.appendingPathComponent("Library.json")
        // A repeated ID means the index was edited or damaged; building the
        // dictionary from it would trap.
        if let decoded = StoreIO.readJSON(
            from: indexURL, as: [WallpaperAsset].self,
            isValid: { Set($0.map(\.id)).count == $0.count })
        {
            assetsByID = Dictionary(uniqueKeysWithValues: decoded.map { ($0.id, $0) })
            loadedIndex = true
        } else {
            loadedIndex = false
        }
    }

    public func assets(sortedBy sort: LibrarySort = .newest) -> [WallpaperAsset] {
        let values = Array(assetsByID.values)
        switch sort {
        case .newest:
            return values.sorted { $0.createdAt > $1.createdAt }
        case .oldest:
            return values.sorted { $0.createdAt < $1.createdAt }
        case .name:
            return values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .resolution:
            return values.sorted {
                ($0.pixelSize.width * $0.pixelSize.height) > ($1.pixelSize.width * $1.pixelSize.height)
            }
        case .mostUsed:
            return values.sorted {
                if $0.applyCount == $1.applyCount {
                    return ($0.lastAppliedAt ?? .distantPast) > ($1.lastAppliedAt ?? .distantPast)
                }
                return $0.applyCount > $1.applyCount
            }
        }
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

    public func update(_ asset: WallpaperAsset) throws {
        guard assetsByID[asset.id] != nil else { throw StoreError.missingAsset }
        assetsByID[asset.id] = asset
        try persist()
    }

    public func rename(id: WallpaperID, to name: String) throws {
        guard var asset = assetsByID[id] else { throw StoreError.missingAsset }
        asset.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        assetsByID[id] = asset
        try persist()
    }

    public func setCategory(id: WallpaperID, category: WallpaperCategory) throws {
        guard var asset = assetsByID[id] else { throw StoreError.missingAsset }
        asset.category = category
        assetsByID[id] = asset
        try persist()
    }

    public func recordApply(id: WallpaperID, at date: Date = .now) throws {
        guard var asset = assetsByID[id] else { throw StoreError.missingAsset }
        asset.applyCount += 1
        asset.lastAppliedAt = date
        assetsByID[id] = asset
        try persist()
    }

    /// Deletes the entry's folder, then drops it from the index, so a failed
    /// delete leaves an entry the user can remove again.
    ///
    /// The media folder must be exactly this entry's own folder. A corrupt or
    /// hand-edited Library.json could otherwise point mediaURL at an arbitrary
    /// directory or a sibling entry's folder. Such an entry is dropped from
    /// the index without touching disk, and the call throws `invalidLocation`.
    /// The delete itself goes through `TrustedDirectory`, so an entry folder
    /// swapped for a symlink loses the link, not what it points at.
    public func remove(id: WallpaperID) throws {
        guard let asset = assetsByID[id] else { throw StoreError.missingAsset }
        var remaining = assetsByID
        remaining[id] = nil
        let folder = asset.mediaURL.deletingLastPathComponent().standardizedFileURL
        guard isEntryFolder(folder, of: id) else {
            try persist(remaining)
            throw StoreError.invalidLocation
        }
        do {
            // The name as validated, which may be spelled in lower case.
            try TrustedDirectory(url: rootURL).removeItem(named: folder.lastPathComponent)
        } catch POSIXError.ENOENT {
            // Already gone; nothing left to delete.
        }
        // The row leaves memory only once the index no longer lists it, so a
        // failed write can be retried.
        try persist(remaining)
    }

    /// Checks the entry folder's name and parent without resolving the
    /// folder itself: resolving it is what let a symlinked folder match.
    /// The name is parsed as a UUID, so a lower-case spelling still matches,
    /// and the parent is compared to the root by device and inode, so `/var`
    /// and `/private/var` spellings of the same root match too.
    private func isEntryFolder(_ folder: URL, of id: WallpaperID) -> Bool {
        guard UUID(uuidString: folder.lastPathComponent) == id.rawValue else { return false }
        var parent = stat()
        var root = stat()
        guard stat(folder.deletingLastPathComponent().path, &parent) == 0, stat(rootURL.path, &root) == 0 else {
            return false
        }
        return parent.st_dev == root.st_dev && parent.st_ino == root.st_ino
    }

    public func folder(for id: WallpaperID) -> URL {
        rootURL.appendingPathComponent(id.rawValue.uuidString, isDirectory: true)
    }

    /// Bytes under the library root. Walks the folder only when the library
    /// changed since the last call (any index write or remove); call
    /// `invalidateDiskUsage()` after changing files outside those paths.
    public func diskUsageBytes() -> Int64 {
        if let cachedDiskUsage { return cachedDiskUsage }
        let total = measureDiskUsage()
        cachedDiskUsage = total
        return total
    }

    public func invalidateDiskUsage() { cachedDiskUsage = nil }

    private func measureDiskUsage() -> Int64 {
        let urls = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: [.fileSizeKey])
        var total: Int64 = 0
        while let url = urls?.nextObject() as? URL {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    /// Writes `assets` (the current rows by default) and, once written, makes
    /// them the current rows.
    private func persist(_ assets: [WallpaperID: WallpaperAsset]? = nil) throws {
        // Every index write changes the measured size, and install, update and
        // remove change the library folders around it.
        cachedDiskUsage = nil
        let assets = assets ?? assetsByID
        let values = assets.values.sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }
        try StoreIO.writeJSON(values, to: indexURL)
        assetsByID = assets
    }
}
