import AppKit
import LumaWallCore
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class AppModel {
    enum Section: String, CaseIterable, Identifiable {
        case home = "Home", library = "Library", displays = "Displays", playlists = "Playlists", settings = "Settings"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .home: "house.fill"
            case .library: "square.grid.2x2.fill"
            case .displays: "display.2"
            case .playlists: "rectangle.stack.fill"
            case .settings: "gearshape.fill"
            }
        }
    }

    var section: Section = .home
    var assets: [WallpaperAsset] = []
    var searchText = ""
    var isImporting = false
    var alertTitle = ""
    var alertMessage = ""
    var showsAlert = false
    private let store: LibraryStore
    private let importer: MediaImporter

    init() {
        do {
            let store = try LibraryStore()
            self.store = store
            self.importer = MediaImporter(store: store)
            Task { await reload() }
        } catch { fatalError("Unable to initialize LumaWall: \(error)") }
    }

    var filteredAssets: [WallpaperAsset] {
        searchText.isEmpty ? assets : assets.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
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
