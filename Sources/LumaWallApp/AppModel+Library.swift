import AppKit
import CoreGraphics
import Darwin
import IOKit.ps
import LumaWallCore
import Observation
import UniformTypeIdentifiers

extension AppModel {
    var featured: WallpaperAsset? {
        if let main = displayCoordinator.mainDisplay(), let id = activeByDisplay[main.displayID],
           let asset = assets.first(where: { $0.id == id }) {
            return asset
        }
        return assets.first
    }

    var recentAssets: [WallpaperAsset] {
        recentIDs.compactMap { id in assets.first { $0.id == id } }
    }

    var likedAssets: [WallpaperAsset] {
        assets.filter { favoriteIDs.contains($0.id) }
    }

    var popularAssets: [WallpaperAsset] {
        assets.sorted {
            if $0.applyCount == $1.applyCount {
                return ($0.lastAppliedAt ?? .distantPast) > ($1.lastAppliedAt ?? .distantPast)
            }
            return $0.applyCount > $1.applyCount
        }
    }

    var filteredAssets: [WallpaperAsset] {
        assets.filter { asset in
            let matchesSearch = searchText.isEmpty || asset.name.localizedCaseInsensitiveContains(searchText)
                || asset.category.title.localizedCaseInsensitiveContains(searchText)
            let matchesResolution = resolutionFilter.matches(asset.pixelSize)
            let matchesCategory = categoryFilter.map { asset.category == $0 } ?? true
            let matchesFavorite = !favoritesOnly || favoriteIDs.contains(asset.id)
            return matchesSearch && matchesResolution && matchesCategory && matchesFavorite
        }
    }

    func assets(in category: WallpaperCategory) -> [WallpaperAsset] {
        assets.filter { $0.category == category }
    }

    var isPaused: Bool { userPaused }

    var playbackScope: PlaybackScope {
        if userPaused { return .paused }
        if hideDesktopVideo { return .lockScreen }
        return .everywhere
    }

    func setPlaybackScope(_ scope: PlaybackScope) {
        switch scope {
        case .everywhere:
            userPaused = false
            setHideDesktopVideo(false)
        case .lockScreen:
            userPaused = false
            setHideDesktopVideo(true)
        case .paused:
            userPaused = true
            setHideDesktopVideo(false)
        }
        UserDefaults.standard.set(userPaused, forKey: "lumawall.userPaused")
    }

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

    func setSort(_ sort: LibrarySort) {
        librarySort = sort
        UserDefaults.standard.set(sort.rawValue, forKey: "lumawall.librarySort")
        Task { await reload() }
    }

    func setCategory(_ category: WallpaperCategory, for asset: WallpaperAsset) {
        Task {
            try? await store.setCategory(id: asset.id, category: category)
            await reload()
        }
    }

    func rename(_ asset: WallpaperAsset, to name: String) {
        Task {
            try? await store.rename(id: asset.id, to: name)
            await reload()
        }
    }

    func chooseVideos() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Choose videos for your LumaWall library (1080p+, under 60s preferred)."
        panel.prompt = "Import"
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK else { return }
            self?.importVideos(panel.urls)
        }
        if let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    func importVideos(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        isImporting = true
        Task {
            var notes: [String] = []
            for url in urls {
                // NOTE: `defer` inside a loop defers to the enclosing scope, not
                // the iteration, the old code held all security-scoped refs until
                // every import finished. Per-URL helper scopes each access.
                notes += await importOneVideo(url)
            }
            await reload()
            isImporting = false
            if !notes.isEmpty {
                present("Import details", notes.joined(separator: "\n"))
            }
        }
    }

    /// Import a single URL, balancing its security-scoped access within the call.
    private func importOneVideo(_ url: URL) async -> [String] {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let result = try await importer.importVideo(url)
            var notes = result.inspection.recommendations.map { "\(result.asset.name): \($0)" }
            if result.removedAudio {
                notes.append("\(result.asset.name): Audio removed for silent desktop playback.")
            }
            return notes
        } catch {
            return ["\(url.lastPathComponent): \(error.localizedDescription)"]
        }
    }

    func remove(_ asset: WallpaperAsset) {
        Task {
            for (displayID, wallpaperID) in activeByDisplay where wallpaperID == asset.id {
                try? await engine.clear(displayID)
            }
            do {
                try await store.remove(id: asset.id)
                try? await recentsStore.remove(asset.id)
                favoriteIDs.remove(asset.id)
                UserDefaults.standard.set(favoriteIDs.map(\.rawValue.uuidString), forKey: "lumawall.favoriteIDs")
                if let posterURL = asset.posterURL {
                    await PosterCache.shared.remove(posterURL)
                }
                await PosterCache.shared.remove(asset.mediaURL)
                await reload()
            } catch {
                present("LumaWall", error.localizedDescription)
            }
        }
    }
}
