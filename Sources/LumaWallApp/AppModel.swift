import AppKit
import LumaWallCore
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class AppModel {
    enum Section: String, CaseIterable, Identifiable {
        case home, explore, library, displays, playlists, settings
        var id: String { rawValue }
        var title: String {
            switch self {
            case .home: "Home"
            case .explore: "Explore"
            case .library: "Library"
            case .displays: "Displays"
            case .playlists: "Playlists"
            case .settings: "Settings"
            }
        }
    }

    enum LibraryFilter: String, CaseIterable, Identifiable {
        case all = "All", favorites = "Favorites", fourK = "4K", inUse = "In Use"
        var id: String { rawValue }
    }

    var section: Section = .home
    var assets: [WallpaperAsset] = []
    var playlists: [WallpaperPlaylist] = []
    var displays: [ConnectedDisplay] = []
    var previewAsset: WallpaperAsset?
    var assignTarget: ConnectedDisplay?
    var searchText = ""
    var libraryFilter: LibraryFilter = .all
    var powerProfile: PowerProfile = .automatic
    var pauseWhenObscured = true
    var launchAtLogin = false
    var isImporting = false
    var isApplying = false
    var alertTitle = ""
    var alertMessage = ""
    var showsAlert = false
    private(set) var favoriteIDs: Set<WallpaperID> = []
    private(set) var activeByDisplay: [DisplayID: WallpaperID] = [:]

    private let store: LibraryStore
    private let importer: MediaImporter
    private let assignmentStore: AssignmentStore
    private let playlistStore: PlaylistStore
    let displayCoordinator: DisplayCoordinator
    private let engine: WallpaperEngine

    init() {
        favoriteIDs = Set(
            UserDefaults.standard.stringArray(forKey: "lumawall.favoriteIDs")?
                .compactMap(UUID.init(uuidString:)).map { WallpaperID(rawValue: $0) } ?? []
        )
        if let raw = UserDefaults.standard.string(forKey: "lumawall.powerProfile"),
           let profile = PowerProfile(rawValue: raw) {
            powerProfile = profile
        }
        pauseWhenObscured = UserDefaults.standard.object(forKey: "lumawall.pauseWhenObscured") as? Bool ?? true

        do {
            let store = try LibraryStore()
            let assignments = try AssignmentStore()
            let playlists = try PlaylistStore()
            let displays = DisplayCoordinator()
            self.store = store
            self.importer = MediaImporter(store: store)
            self.assignmentStore = assignments
            self.playlistStore = playlists
            self.displayCoordinator = displays
            self.engine = WallpaperEngine(displays: displays, assignments: assignments)
            self.displays = displays.displays
            Task { await bootstrap() }
        } catch {
            fatalError("Unable to initialize LumaWall: \(error)")
        }
    }

    var featured: WallpaperAsset? {
        if let main = displayCoordinator.mainDisplay(), let id = activeByDisplay[main.displayID],
           let asset = assets.first(where: { $0.id == id }) {
            return asset
        }
        return assets.last
    }

    var filteredAssets: [WallpaperAsset] {
        assets.filter { asset in
            let matchesSearch = searchText.isEmpty || asset.name.localizedCaseInsensitiveContains(searchText)
            let matchesFilter: Bool = switch libraryFilter {
            case .all: true
            case .favorites: favoriteIDs.contains(asset.id)
            case .fourK: asset.pixelSize.width >= 3_840 || asset.pixelSize.height >= 2_160
            case .inUse: activeByDisplay.values.contains(asset.id)
            }
            return matchesSearch && matchesFilter
        }
    }

    var isPaused: Bool { engine.isPausedGlobally }

    func isFavorite(_ asset: WallpaperAsset) -> Bool { favoriteIDs.contains(asset.id) }
    func isActive(_ asset: WallpaperAsset) -> Bool { activeByDisplay.values.contains(asset.id) }
    func activeName(on display: ConnectedDisplay) -> String? {
        guard let id = activeByDisplay[display.displayID] else { return nil }
        return assets.first { $0.id == id }?.name
    }

    func toggleFavorite(_ asset: WallpaperAsset) {
        if favoriteIDs.contains(asset.id) { favoriteIDs.remove(asset.id) } else { favoriteIDs.insert(asset.id) }
        UserDefaults.standard.set(favoriteIDs.map(\.rawValue.uuidString), forKey: "lumawall.favoriteIDs")
    }

    func chooseVideos() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose videos for your LumaWall library."
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
                } catch {
                    notes.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            await reload()
            isImporting = false
            if !notes.isEmpty {
                present("Import details", notes.joined(separator: "\n"))
            }
        }
    }

    func remove(_ asset: WallpaperAsset) {
        Task {
            for (displayID, wallpaperID) in activeByDisplay where wallpaperID == asset.id {
                try? await engine.clear(displayID)
            }
            do {
                try await store.remove(id: asset.id)
                await reload()
            } catch {
                present("LumaWall", error.localizedDescription)
            }
        }
    }

    func apply(_ asset: WallpaperAsset, to displayID: DisplayID? = nil) {
        isApplying = true
        Task {
            do {
                if let displayID {
                    try await engine.apply(asset, to: displayID)
                } else if let main = displayCoordinator.mainDisplay() {
                    try await engine.apply(asset, to: main.displayID)
                }
                refreshActive()
                section = .displays
            } catch {
                present("Couldn’t apply wallpaper", error.localizedDescription)
            }
            isApplying = false
        }
    }

    func applyToAll(_ asset: WallpaperAsset) {
        isApplying = true
        Task {
            do {
                try await engine.applyToAll(asset)
                refreshActive()
                section = .displays
            } catch {
                present("Couldn’t apply wallpaper", error.localizedDescription)
            }
            isApplying = false
        }
    }

    func clearDisplay(_ display: ConnectedDisplay) {
        Task {
            try? await engine.clear(display.displayID)
            refreshActive()
        }
    }

    func togglePause() {
        engine.setPaused(!engine.isPausedGlobally)
    }

    func setPowerProfile(_ profile: PowerProfile) {
        powerProfile = profile
        UserDefaults.standard.set(profile.rawValue, forKey: "lumawall.powerProfile")
        // Battery profiles map to pause/static behavior until the native extension lands.
        switch profile {
        case .staticOnBattery:
            let onBattery = !ProcessInfo.processInfo.isLowPowerModeEnabled // placeholder; refined later
            _ = onBattery
        case .batterySaver, .automatic, .fullQuality:
            break
        }
    }

    func createPlaylist(name: String, from selection: [WallpaperAsset], shuffled: Bool) {
        guard !selection.isEmpty else { return }
        Task {
            let playlist = WallpaperPlaylist(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Playlist \(playlists.count + 1)" : name,
                wallpaperIDs: selection.map(\.id),
                shuffled: shuffled
            )
            try? await playlistStore.upsert(playlist)
            playlists = await playlistStore.all()
        }
    }

    func deletePlaylist(_ playlist: WallpaperPlaylist) {
        Task {
            try? await playlistStore.remove(id: playlist.id)
            playlists = await playlistStore.all()
        }
    }

    func applyPlaylist(_ playlist: WallpaperPlaylist) {
        guard let firstID = playlist.wallpaperIDs.first,
              let asset = assets.first(where: { $0.id == firstID }) else { return }
        applyToAll(asset)
    }

    func refreshDisplays() {
        displays = displayCoordinator.refresh()
        refreshActive()
    }

    private func bootstrap() async {
        await reload()
        playlists = await playlistStore.all()
        displays = displayCoordinator.refresh()
        await engine.restore(using: assets)
        refreshActive()
    }

    func reload() async {
        assets = await store.assets()
        refreshActive()
    }

    private func refreshActive() {
        activeByDisplay = Dictionary(uniqueKeysWithValues: engine.activeDisplayIDs.compactMap { id in
            guard let wallpaper = engine.wallpaperID(on: id) else { return nil }
            return (id, wallpaper)
        })
        displays = displayCoordinator.displays
    }

    private func present(_ title: String, _ message: String) {
        alertTitle = title
        alertMessage = message
        showsAlert = true
    }
}
