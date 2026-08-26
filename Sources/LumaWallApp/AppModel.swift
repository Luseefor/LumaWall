import AppKit
import LumaWallCore
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class AppModel {
    enum LibraryFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case favorites = "Favorites"
        case fourK = "4K"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .all: "square.grid.2x2.fill"
            case .favorites: "heart.fill"
            case .fourK: "4k.tv.fill"
            }
        }
    }

    enum Section: String, CaseIterable, Identifiable {
        case home = "Home", explore = "Explore", library = "Library", displays = "Displays", playlists = "Playlists", settings = "Settings"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .home: "house.fill"
            case .explore: "safari.fill"
            case .library: "square.grid.2x2.fill"
            case .displays: "display.2"
            case .playlists: "rectangle.stack.fill"
            case .settings: "gearshape.fill"
            }
        }
    }

    var section: Section = .home
    var assets: [WallpaperAsset] = []
    var previewAsset: WallpaperAsset?
    var searchText = ""
    var libraryFilter: LibraryFilter = .all
    private(set) var favoriteIDs: Set<WallpaperID> = []
    var isImporting = false
    var alertTitle = ""
    var alertMessage = ""
    var showsAlert = false
    private let store: LibraryStore
    private let importer: MediaImporter

    init() {
        favoriteIDs = Set(
            UserDefaults.standard.stringArray(forKey: "lumawall.favoriteIDs")?.compactMap(UUID.init(uuidString:)).map {
                WallpaperID(rawValue: $0)
            } ?? []
        )
        do {
            let store = try LibraryStore()
            self.store = store
            self.importer = MediaImporter(store: store)
            Task { await reload() }
        } catch { fatalError("Unable to initialize LumaWall: \(error)") }
    }

    var filteredAssets: [WallpaperAsset] {
        assets.filter { asset in
            let matchesSearch = searchText.isEmpty || asset.name.localizedCaseInsensitiveContains(searchText)
            let matchesFilter = switch libraryFilter {
            case .all: true
            case .favorites: favoriteIDs.contains(asset.id)
            case .fourK: asset.pixelSize.width >= 3_840 || asset.pixelSize.height >= 2_160
            }
            return matchesSearch && matchesFilter
        }
    }

    func isFavorite(_ asset: WallpaperAsset) -> Bool { favoriteIDs.contains(asset.id) }

    func toggleFavorite(_ asset: WallpaperAsset) {
        if favoriteIDs.contains(asset.id) { favoriteIDs.remove(asset.id) } else { favoriteIDs.insert(asset.id) }
        UserDefaults.standard.set(favoriteIDs.map { $0.rawValue.uuidString }, forKey: "lumawall.favoriteIDs")
    }

    func chooseVideos() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose one or more videos for your LumaWall library."
        guard panel.runModal() == .OK else { return }
        importVideos(panel.urls)
    }

    func importVideos(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        isImporting = true
        Task {
            var notes: [String] = []
            for url in urls {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                do {
                    let result = try await importer.importVideo(url)
                    notes += result.inspection.recommendations.map { "\(result.asset.name): \($0)" }
                } catch { notes.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            }
            await reload()
            isImporting = false
            if !notes.isEmpty {
                alertTitle = "Import details"
                alertMessage = notes.joined(separator: "\n")
                showsAlert = true
            }
        }
    }

    func remove(_ asset: WallpaperAsset) {
        Task {
            do { try await store.remove(id: asset.id); await reload() }
            catch { alertTitle = "LumaWall"; alertMessage = error.localizedDescription; showsAlert = true }
        }
    }

    func reload() async { assets = await store.assets() }
}
