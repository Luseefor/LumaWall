import AppKit
import CoreGraphics
import Darwin
import LumaWallCore
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class AppModel {
    enum Section: String, CaseIterable, Identifiable {
        case home, library, displays, settings
        var id: String { rawValue }
        var title: String {
            switch self {
            case .home: "Home"
            case .library: "Library"
            case .displays: "Displays"
            case .settings: "Settings"
            }
        }

        var symbol: String {
            switch self {
            case .home: "house.fill"
            case .library: "square.grid.2x2.fill"
            case .displays: "display.2"
            case .settings: "gearshape.fill"
            }
        }
    }

    var section: Section = .home
    var assets: [WallpaperAsset] = []
    var playlists: [WallpaperPlaylist] = []
    var displays: [ConnectedDisplay] = []
    var recentIDs: [WallpaperID] = []
    var previewAsset: WallpaperAsset?
    var assignTarget: ConnectedDisplay?
    var searchText = ""
    var librarySort: LibrarySort = .newest
    var resolutionFilter: ResolutionFilter = .all
    var categoryFilter: WallpaperCategory? = nil
    var favoritesOnly = false
    var powerProfile: PowerProfile = .automatic
    var pauseWhenObscured = true
    var pauseOnLock = true
    var hideDesktopVideo = false
    var userPaused = false
    var playbackStopped = false
    var pausedDisplayIDs: Set<DisplayID> = []
    var launchAtLogin = false
    var processCPUPercent: Double = 0
    var systemCPUPercent: Double = 0
    var batteryPercent = 100
    var isOnBattery = false
    var playlistEditor: PlaylistEditorState?
    var isImporting = false
    var isApplying = false
    var alertTitle = ""
    var alertMessage = ""
    var showsAlert = false
    var activePlaylistID: PlaylistID?
    var processMemoryMB: Double = 0
    var libraryDiskMB: Double = 0
    var automations = WallpaperAutomations()
    var automationPickSlot: AutomationSlot?
    var dayNightExpanded = true
    var appearanceExpanded = true
    private(set) var favoriteIDs: Set<WallpaperID> = []
    private(set) var activeByDisplay: [DisplayID: WallpaperID] = [:]

    private let store: LibraryStore
    private let importer: MediaImporter
    private let assignmentStore: AssignmentStore
    private let playlistStore: PlaylistStore
    private let recentsStore: RecentsStore
    private let automationStore: AutomationStore
    let displayCoordinator: DisplayCoordinator
    private let engine: WallpaperEngine
    private var playlistTimer: Timer?
    private var playlistCursor = 0
    private var statsTimer: Timer?
    private var dayNightTimer: Timer?
    private var lastAutomationWallpaperID: WallpaperID?
    private var appearanceObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var coverageObservers: [NSObjectProtocol] = []
    private var coverageTimer: Timer?
    private var lockObservers: [NSObjectProtocol] = []
    private var sessionLocked = false
    private var displaysAsleep = false
    private var cpuSampler = CPUSampler()
    private var playlistIDs: [WallpaperID] = []

    struct PlaylistEditorState: Identifiable {
        var id: PlaylistID
        var existingID: PlaylistID?
        var name: String
        var orderedIDs: [WallpaperID]
        var shuffled: Bool
        var intervalMinutes: Int
    }

    enum AutomationSlot: String, Identifiable {
        case day, night, light, dark
        var id: String { rawValue }

        var title: String {
            switch self {
            case .day: "Day"
            case .night: "Night"
            case .light: "Light"
            case .dark: "Dark"
            }
        }
    }

    init() {
        favoriteIDs = Set(
            UserDefaults.standard.stringArray(forKey: "lumawall.favoriteIDs")?
                .compactMap(UUID.init(uuidString:)).map { WallpaperID(rawValue: $0) } ?? []
        )
        if let raw = UserDefaults.standard.string(forKey: "lumawall.powerProfile"),
           let profile = PowerProfile(rawValue: raw) {
            powerProfile = profile
        }
        if let raw = UserDefaults.standard.string(forKey: "lumawall.librarySort"),
           let sort = LibrarySort(rawValue: raw) {
            librarySort = sort
        }
        pauseWhenObscured = UserDefaults.standard.object(forKey: "lumawall.pauseWhenObscured") as? Bool ?? true
        pauseOnLock = UserDefaults.standard.object(forKey: "lumawall.pauseOnLock") as? Bool ?? true
        hideDesktopVideo = UserDefaults.standard.bool(forKey: "lumawall.hideDesktopVideo")
        userPaused = UserDefaults.standard.bool(forKey: "lumawall.userPaused")
        if let paused = UserDefaults.standard.stringArray(forKey: "lumawall.pausedDisplayIDs") {
            pausedDisplayIDs = Set(paused.map(DisplayID.init(rawValue:)))
        }

        do {
            let store = try LibraryStore()
            let assignments = try AssignmentStore()
            let playlists = try PlaylistStore()
            let recents = try RecentsStore()
            let automations = try AutomationStore()
            let displays = DisplayCoordinator()
            self.store = store
            self.importer = MediaImporter(store: store)
            self.assignmentStore = assignments
            self.playlistStore = playlists
            self.recentsStore = recents
            self.automationStore = automations
            self.displayCoordinator = displays
            self.engine = WallpaperEngine(displays: displays, assignments: assignments)
            self.displays = displays.displays
            self.launchAtLogin = LaunchAtLogin.isEnabled
            Task { await bootstrap() }
            startStatsPolling()
            observeAppearanceChanges()
            observeScreenChanges()
            observeDesktopCoverage()
            observeLockAndSleep()
        } catch {
            fatalError("Unable to initialize LumaWall: \(error)")
        }
    }

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
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                do {
                    let result = try await importer.importVideo(url)
                    notes += result.inspection.recommendations.map { "\(result.asset.name): \($0)" }
                    if result.removedAudio {
                        notes.append("\(result.asset.name): Audio removed for silent desktop playback.")
                    }
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
                try? await recentsStore.remove(asset.id)
                favoriteIDs.remove(asset.id)
                UserDefaults.standard.set(favoriteIDs.map(\.rawValue.uuidString), forKey: "lumawall.favoriteIDs")
                await reload()
            } catch {
                present("LumaWall", error.localizedDescription)
            }
        }
    }

    func apply(
        _ asset: WallpaperAsset,
        to displayID: DisplayID? = nil,
        composition: DisplayComposition = .init(),
        continuingPlaylist: Bool = false
    ) {
        isApplying = true
        if !continuingPlaylist { stopPlaylistRotation() }
        Task {
            do {
                if let displayID {
                    try await engine.apply(asset, to: displayID, composition: composition)
                } else if let main = displayCoordinator.mainDisplay() {
                    try await engine.apply(asset, to: main.displayID, composition: composition)
                }
                try? await store.recordApply(id: asset.id)
                try? await recentsStore.push(asset.id)
                await reload()
                applyPlaybackPolicy()
            } catch {
                present("Couldn’t apply wallpaper", error.localizedDescription)
            }
            isApplying = false
        }
    }

    func composition(on display: ConnectedDisplay) -> DisplayComposition {
        engine.composition(on: display.displayID)
    }

    func applyToAll(_ asset: WallpaperAsset, continuingPlaylist: Bool = false) {
        isApplying = true
        if !continuingPlaylist { stopPlaylistRotation() }
        Task {
            do {
                try await engine.applyToAll(asset)
                try? await store.recordApply(id: asset.id)
                try? await recentsStore.push(asset.id)
                await reload()
                applyPlaybackPolicy()
            } catch {
                present("Couldn’t apply wallpaper", error.localizedDescription)
            }
            isApplying = false
        }
    }

    func reapplyActive() {
        guard let featured else { return }
        applyToAll(featured)
    }

    func clearDisplay(_ display: ConnectedDisplay) {
        Task {
            try? await engine.clear(display.displayID)
            refreshActive()
            applyPlaybackPolicy()
        }
    }

    func togglePause() {
        userPaused.toggle()
        UserDefaults.standard.set(userPaused, forKey: "lumawall.userPaused")
        applyPlaybackPolicy()
    }

    func togglePause(on display: ConnectedDisplay) {
        if pausedDisplayIDs.contains(display.displayID) {
            pausedDisplayIDs.remove(display.displayID)
        } else {
            pausedDisplayIDs.insert(display.displayID)
        }
        UserDefaults.standard.set(pausedDisplayIDs.map(\.rawValue), forKey: "lumawall.pausedDisplayIDs")
        applyPlaybackPolicy()
    }

    func isDisplayPaused(_ display: ConnectedDisplay) -> Bool {
        userPaused || pausedDisplayIDs.contains(display.displayID) || engine.tier(on: display.displayID) == .paused
    }

    func setPauseWhenObscured(_ enabled: Bool) {
        pauseWhenObscured = enabled
        UserDefaults.standard.set(enabled, forKey: "lumawall.pauseWhenObscured")
        applyPlaybackPolicy()
    }

    func setPauseOnLock(_ enabled: Bool) {
        pauseOnLock = enabled
        UserDefaults.standard.set(enabled, forKey: "lumawall.pauseOnLock")
        applyPlaybackPolicy()
    }

    func setHideDesktopVideo(_ enabled: Bool) {
        hideDesktopVideo = enabled
        UserDefaults.standard.set(enabled, forKey: "lumawall.hideDesktopVideo")
        applyPlaybackPolicy()
    }

    func setPowerProfile(_ profile: PowerProfile) {
        powerProfile = profile
        UserDefaults.standard.set(profile.rawValue, forKey: "lumawall.powerProfile")
        applyPlaybackPolicy()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            launchAtLogin = try LaunchAtLogin.setEnabled(enabled)
        } catch {
            launchAtLogin = LaunchAtLogin.isEnabled
            present("Launch at Login", error.localizedDescription)
        }
    }

    func clearMemoryCache() {
        CacheCleaner.clearMemory()
        refreshStats()
        present("Cache", "In-memory caches cleared.")
    }

    func clearDiskCache() {
        Task {
            do {
                let removed = try await CacheCleaner.clearDisk(preservingLibraryRoot: store.rootURL)
                refreshStats()
                present("Cache", removed == 0 ? "No cache files to remove." : "Cleared \(removed) cache items.")
            } catch {
                present("Cache", error.localizedDescription)
            }
        }
    }

    func createPlaylist(name: String, from selection: [WallpaperAsset], shuffled: Bool, intervalMinutes: Int) {
        guard !selection.isEmpty else { return }
        beginPlaylistEditor()
        playlistEditor?.name = name
        playlistEditor?.orderedIDs = selection.map(\.id)
        playlistEditor?.shuffled = shuffled
        playlistEditor?.intervalMinutes = max(1, intervalMinutes)
        savePlaylistEditor()
    }

    func beginPlaylistEditor(existing: WallpaperPlaylist? = nil) {
        if let existing {
            playlistEditor = PlaylistEditorState(
                id: existing.id,
                existingID: existing.id,
                name: existing.name,
                orderedIDs: existing.wallpaperIDs,
                shuffled: existing.shuffled,
                intervalMinutes: existing.intervalMinutes
            )
        } else {
            let id = PlaylistID()
            playlistEditor = PlaylistEditorState(
                id: id,
                existingID: nil,
                name: "",
                orderedIDs: [],
                shuffled: false,
                intervalMinutes: 30
            )
        }
    }

    func toggleEditorEntry(_ asset: WallpaperAsset) {
        guard var draft = playlistEditor else { return }
        if let index = draft.orderedIDs.firstIndex(of: asset.id) {
            draft.orderedIDs.remove(at: index)
        } else {
            draft.orderedIDs.append(asset.id)
        }
        playlistEditor = draft
    }

    func moveEditorEntry(from source: Int, to destination: Int) {
        guard var draft = playlistEditor, draft.orderedIDs.indices.contains(source) else { return }
        let id = draft.orderedIDs.remove(at: source)
        draft.orderedIDs.insert(id, at: min(destination, draft.orderedIDs.count))
        playlistEditor = draft
    }

    func savePlaylistEditor() {
        guard let draft = playlistEditor, !draft.orderedIDs.isEmpty else { return }
        Task {
            let playlist = WallpaperPlaylist(
                id: draft.existingID ?? draft.id,
                name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "Playlist \(playlists.count + 1)"
                    : draft.name,
                wallpaperIDs: draft.orderedIDs,
                shuffled: draft.shuffled,
                intervalMinutes: max(1, draft.intervalMinutes)
            )
            try? await playlistStore.upsert(playlist)
            playlists = await playlistStore.all()
            playlistEditor = nil
        }
    }

    func deletePlaylist(_ playlist: WallpaperPlaylist) {
        if activePlaylistID == playlist.id { stopPlaylistRotation() }
        Task {
            try? await playlistStore.remove(id: playlist.id)
            playlists = await playlistStore.all()
        }
    }

    func applyPlaylist(_ playlist: WallpaperPlaylist) {
        let ids = playlist.shuffled ? playlist.wallpaperIDs.shuffled() : playlist.wallpaperIDs
        guard let firstID = ids.first,
              let asset = assets.first(where: { $0.id == firstID }) else { return }
        automations.dayNightEnabled = false
        automations.appearanceEnabled = false
        persistAutomations()
        activePlaylistID = playlist.id
        playlistIDs = ids
        playlistCursor = 0
        applyToAll(asset, continuingPlaylist: true)
        startPlaylistRotation(ids: ids, intervalMinutes: playlist.intervalMinutes)
    }

    func stepPlaylist(_ delta: Int) {
        guard !playlistIDs.isEmpty else { return }
        playlistCursor = (playlistCursor + delta + playlistIDs.count) % playlistIDs.count
        let nextID = playlistIDs[playlistCursor]
        guard let asset = assets.first(where: { $0.id == nextID }) else { return }
        applyToAll(asset, continuingPlaylist: true)
    }

    func stopPlaylistRotation() {
        playlistTimer?.invalidate()
        playlistTimer = nil
        activePlaylistID = nil
        playlistIDs = []
    }

    func refreshDisplays() {
        displays = displayCoordinator.refresh()
        refreshActive()
    }

    private func startPlaylistRotation(ids: [WallpaperID], intervalMinutes: Int) {
        playlistIDs = ids
        playlistTimer?.invalidate()
        let seconds = TimeInterval(max(1, intervalMinutes) * 60)
        playlistTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.stepPlaylist(1) }
        }
    }

    func displaysUsing(_ asset: WallpaperAsset) -> [ConnectedDisplay] {
        displays.filter { activeByDisplay[$0.displayID] == asset.id }
    }

    func asset(for id: WallpaperID?) -> WallpaperAsset? {
        guard let id else { return nil }
        return assets.first { $0.id == id }
    }

    func setDayNightEnabled(_ enabled: Bool) {
        automations.dayNightEnabled = enabled
        if enabled {
            automations.appearanceEnabled = false
            stopPlaylistRotation()
        }
        persistAutomations()
        evaluateAutomations(force: true)
    }

    func setAppearanceEnabled(_ enabled: Bool) {
        automations.appearanceEnabled = enabled
        if enabled {
            automations.dayNightEnabled = false
            stopPlaylistRotation()
        }
        persistAutomations()
        evaluateAutomations(force: true)
    }

    func assignAutomation(slot: AutomationSlot, asset: WallpaperAsset) {
        switch slot {
        case .day: automations.dayWallpaperID = asset.id
        case .night: automations.nightWallpaperID = asset.id
        case .light: automations.lightWallpaperID = asset.id
        case .dark: automations.darkWallpaperID = asset.id
        }
        automationPickSlot = nil
        persistAutomations()
        evaluateAutomations(force: true)
    }

    func clearAutomation(slot: AutomationSlot) {
        switch slot {
        case .day: automations.dayWallpaperID = nil
        case .night: automations.nightWallpaperID = nil
        case .light: automations.lightWallpaperID = nil
        case .dark: automations.darkWallpaperID = nil
        }
        persistAutomations()
    }

    private func persistAutomations() {
        Task { try? await automationStore.save(automations) }
        syncDayNightTimer()
    }

    private func syncDayNightTimer() {
        dayNightTimer?.invalidate()
        dayNightTimer = nil
        guard automations.dayNightEnabled else { return }
        dayNightTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.evaluateAutomations(force: false) }
        }
    }

    private func observeAppearanceChanges() {
        appearanceObserver = DistributedNotificationCenter.default.addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                self?.evaluateAutomations(force: false)
            }
        }
    }

    private func observeScreenChanges() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshDisplays() }
        }
    }

    func evaluateAutomations(force: Bool) {
        let targetID: WallpaperID?
        if automations.dayNightEnabled {
            targetID = automations.isDayPeriod() ? automations.dayWallpaperID : automations.nightWallpaperID
        } else if automations.appearanceEnabled {
            targetID = isSystemDarkAppearance() ? automations.darkWallpaperID : automations.lightWallpaperID
        } else {
            return
        }
        guard let targetID, let asset = assets.first(where: { $0.id == targetID }) else { return }
        if !force, lastAutomationWallpaperID == targetID { return }
        lastAutomationWallpaperID = targetID
        stopPlaylistRotation()
        Task {
            do {
                try await engine.applyToAll(asset)
                try? await store.recordApply(id: asset.id)
                try? await recentsStore.push(asset.id)
                await reload()
            } catch {
                present("Automation", error.localizedDescription)
            }
        }
    }

    private func isSystemDarkAppearance() -> Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private func bootstrap() async {
        await reload()
        playlists = await playlistStore.all()
        automations = await automationStore.current()
        displays = displayCoordinator.refresh()
        await engine.restore(using: assets)
        refreshActive()
        refreshStats()
        applyPlaybackPolicy()
        syncDayNightTimer()
        evaluateAutomations(force: false)
    }

    func reload() async {
        assets = await store.assets(sortedBy: librarySort)
        recentIDs = await recentsStore.all()
        refreshActive()
        refreshStats()
    }

    private func refreshActive() {
        activeByDisplay = Dictionary(uniqueKeysWithValues: engine.activeDisplayIDs.compactMap { id in
            guard let wallpaper = engine.wallpaperID(on: id) else { return nil }
            return (id, wallpaper)
        })
        displays = displayCoordinator.displays
    }

    private func startStatsPolling() {
        refreshStats()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshStats() }
        }
        RunLoop.main.add(timer, forMode: .common)
        statsTimer = timer
    }

    func refreshStats() {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            processMemoryMB = Double(info.resident_size) / 1_048_576
        }
        let cpu = cpuSampler.sample()
        processCPUPercent = cpu.process
        systemCPUPercent = cpu.system
        let power = PowerStatus.current()
        batteryPercent = power.percent
        isOnBattery = power.isOnBattery
        Task { @MainActor in
            let bytes = await store.diskUsageBytes()
            libraryDiskMB = Double(bytes) / 1_048_576
        }
    }

    private func observeLockAndSleep() {
        let distributed = DistributedNotificationCenter.default()
        lockObservers.append(
            distributed.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.sessionLocked = true
                    self?.applyPlaybackPolicy()
                }
            }
        )
        lockObservers.append(
            distributed.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.sessionLocked = false
                    self?.applyPlaybackPolicy()
                }
            }
        )
        let workspace = NSWorkspace.shared.notificationCenter
        lockObservers.append(
            workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.displaysAsleep = true
                    self?.applyPlaybackPolicy()
                }
            }
        )
        lockObservers.append(
            workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.displaysAsleep = false
                    self?.applyPlaybackPolicy()
                }
            }
        )
    }

    private func observeDesktopCoverage() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [NSNotification.Name] = [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didDeactivateApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification
        ]
        for name in names {
            coverageObservers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.applyPlaybackPolicy() }
                }
            )
        }
        // Workspace/Space notifications handle normal transitions. This slow fallback
        // catches apps that resize opaque windows without publishing a workspace event.
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.applyPlaybackPolicy() }
        }
        RunLoop.main.add(timer, forMode: .common)
        coverageTimer = timer
        applyPlaybackPolicy()
    }

    func applyPlaybackPolicy() {
        let power = PowerStatus.current()
        batteryPercent = power.percent
        isOnBattery = power.isOnBattery
        let covered = DisplayOcclusion.coveredIDs(in: displays)
        for display in displays {
            let conditions = PlaybackConditions(
                profile: powerProfile,
                isOnBattery: power.isOnBattery,
                batteryPercent: power.percent,
                lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                thermalState: ProcessInfo.processInfo.thermalState,
                displayIsAsleep: displaysAsleep,
                sessionIsLocked: pauseOnLock && sessionLocked,
                displayIsObscured: pauseWhenObscured && covered.contains(display.displayID),
                userPaused: userPaused || pausedDisplayIDs.contains(display.displayID),
                hideDesktopVideo: hideDesktopVideo
            )
            engine.apply(tier: PlaybackPolicy.resolve(conditions), to: display.displayID)
        }
        playbackStopped = displays.contains { engine.wallpaperID(on: $0.displayID) != nil }
            && displays.allSatisfy { display in
                guard engine.wallpaperID(on: display.displayID) != nil else { return true }
                switch engine.tier(on: display.displayID) {
                case .full, .reduced: return false
                default: return true
                }
            }
    }

    private func present(_ title: String, _ message: String) {
        alertTitle = title
        alertMessage = message
        showsAlert = true
    }
}

private enum DisplayOcclusion {
    static func coveredIDs(in displays: [ConnectedDisplay]) -> Set<DisplayID> {
        let desktopLayer = Int(CGWindowLevelForKey(.desktopIconWindow))
        let desktop = displays.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        guard !desktop.isNull,
              let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }

        var windows: [CGRect] = []
        for dict in info {
            let layer = dict[kCGWindowLayer as String] as? Int ?? 0
            if layer <= desktopLayer { continue }
            guard let bounds = dict[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let quartz = CGRect(
                x: bounds["X"] ?? 0,
                y: bounds["Y"] ?? 0,
                width: bounds["Width"] ?? 0,
                height: bounds["Height"] ?? 0
            )
            windows.append(ScreenGeometry.cocoa(fromQuartz: quartz, desktop: desktop))
        }

        var covered: Set<DisplayID> = []
        for display in displays {
            if ScreenGeometry.isCovered(screen: display.frame, windows: windows) {
                covered.insert(display.displayID)
            }
        }
        return covered
    }
}
