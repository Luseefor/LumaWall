import AppKit
import CoreGraphics
import Darwin
import IOKit.ps
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
            case .home: L10n.home
            case .library: L10n.library
            case .displays: L10n.displays
            case .settings: L10n.settings
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
    /// Live diagnostics. Observed, so the diagnostics views redraw when a poll
    /// lands; only those views read them, and the poll runs only while one is
    /// visible. Assign only on change to avoid redundant invalidations.
    var processCPUPercent: Double = 0
    var systemCPUPercent: Double = 0
    var batteryPercent = 100
    var isOnBattery = false
    var playlistEditor: PlaylistEditorState?
    var isImporting = false
    var isApplying = false
    /// Queued alerts. The old three-var (`alertTitle/alertMessage/showsAlert`)
    /// form tore: a second `present` overwrote the first before dismissal.
    /// `activeAlert` drives a single `.alert(item:)`; the rest wait in `alertQueue`.
    struct AppAlert: Identifiable {
        let id = UUID()
        var title: String
        var message: String
    }
    var activeAlert: AppAlert?
    var alertQueue: [AppAlert] = []
    var activePlaylistID: PlaylistID?
    var processMemoryMB: Double = 0
    var libraryDiskMB: Double = 0
    var activeDecoderCount = 0
    var reduceMotionActive = false
    var energySoakReport: EnergySoakReport?
    var automations = WallpaperAutomations()
    var automationPickSlot: AutomationSlot?
    var dayNightExpanded = true
    var appearanceExpanded = true
    var automationRulesExpanded = true
    var lockAutomationExpanded = true
    var favoriteIDs: Set<WallpaperID> = []
    var activeByDisplay: [DisplayID: WallpaperID] = [:]

    let store: LibraryStore
    let importer: MediaImporter
    let assignmentStore: AssignmentStore
    let playlistStore: PlaylistStore
    let playlistPlaybackStore: PlaylistPlaybackStore
    let recentsStore: RecentsStore
    let automationStore: AutomationStore
    let energyLogStore: EnergyLogStore
    let crashReportStore: CrashReportStore
    var crashReports: [CrashReport] = []
    var lastSessionEndedUncleanly = false
    let displayCoordinator: DisplayCoordinator
    let engine: WallpaperEngine
    var wallpaperHostMode: WallpaperHostMode { engine.mode }
    var playlistTimer: Timer?
    var playlistCursor = 0
    var playlistNextAdvanceAt: Date?
    var statsTimer: Timer?
    var energyTimer: Timer?
    /// Which diagnostics views are on screen; the live stats timer runs only then.
    @ObservationIgnored var diagnosticsVisibility = DiagnosticsVisibility()
    var dayNightTimer: Timer?
    var lastAutomationWallpaperID: WallpaperID?
    var appearanceObserver: NSObjectProtocol?
    var automationObservers: [NSObjectProtocol] = []
    var reduceMotionObserver: NSObjectProtocol?
    var screenObserver: NSObjectProtocol?
    var coverageObservers: [NSObjectProtocol] = []
    var coverageTimer: Timer?
    var coverageDebouncer: CoverageDebouncer?
    var powerTracker = PowerSampleTracker()
    var lockObservers: [NSObjectProtocol] = []
    var powerObservers: [NSObjectProtocol] = []
    /// Owns the IOKit power-source runloop source. A lock-guarded box rather
    /// than a bare property so both MainActor teardown and nonisolated
    /// deinit can release it: the notify context holds an unretained self
    /// pointer, so a source outliving the model would crash on the next
    /// power event. Removal runs on whatever thread deinit lands on;
    /// CFRunLoopRemoveSource is thread-safe.
    final class PowerSourceRegistration: @unchecked Sendable {
        private let lock = NSLock()
        private var source: CFRunLoopSource?

        func set(_ source: CFRunLoopSource?) {
            lock.lock()
            defer { lock.unlock() }
            self.source = source
        }

        /// Removes the source from the main runloop and forgets it. Idempotent.
        /// The lock is released before touching the runloop: never call out
        /// while holding it.
        func invalidate() {
            lock.lock()
            let current = source
            source = nil
            lock.unlock()
            if let current {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), current, .defaultMode)
            }
        }

        deinit { invalidate() }
    }
    let powerSourceRegistration = PowerSourceRegistration()
    var sessionLocked = false
    var displaysAsleep = false
    var cpuSampler = CPUSampler()
    /// Separate from `cpuSampler`: energy samples cover the full interval
    /// between them even while the live stats timer also samples.
    var energyCPUSampler = CPUSampler()
    var playlistIDs: [WallpaperID] = []
    let gameModeMonitor = GameModeMonitor()
    var didAdvancePlaylistOnLogin = false
    var lastPlaylistWakeAdvance: Date?
    var willTerminateObserver: NSObjectProtocol?

    struct PlaylistEditorState: Identifiable {
        var id: PlaylistID
        var existingID: PlaylistID?
        var name: String
        var orderedIDs: [WallpaperID]
        var shuffled: Bool
        var intervalMinutes: Int
    }

    /// Single-sheet router. Four `.sheet(item:)` modifiers on one view mean
    /// only the first non-nil presents and the rest are silently dropped.
    /// `topSheet` exposes priority order; `setTopSheet(nil)` clears the
    /// currently presented sheet's source (replacing double `nil + dismiss()`).
    enum SheetRoute: Identifiable {
        case preview(WallpaperAsset)
        case assign(ConnectedDisplay)
        case automation(AutomationSlot)
        case playlistEditor
        var id: String {
            switch self {
            case .preview(let asset): "preview-\(asset.id.rawValue)"
            case .assign(let display): "assign-\(display.displayID.rawValue)"
            case .automation(let slot): "automation-\(slot.rawValue)"
            case .playlistEditor: "playlist-editor"
            }
        }
    }

    /// Highest-priority presented sheet. Order: preview > assign > automation > editor.
    var topSheet: SheetRoute? {
        if let previewAsset { return .preview(previewAsset) }
        if let assignTarget { return .assign(assignTarget) }
        if let automationPickSlot { return .automation(automationPickSlot) }
        if playlistEditor != nil { return .playlistEditor }
        return nil
    }

    /// Clear (or switch) sheets through the router so sources stay consistent.
    func setTopSheet(_ route: SheetRoute?) {
        switch route {
        case .preview(let asset): previewAsset = asset
        case .assign(let display): assignTarget = display
        case .automation(let slot): automationPickSlot = slot
        case .playlistEditor: break
        case nil:
            previewAsset = nil
            assignTarget = nil
            automationPickSlot = nil
            playlistEditor = nil
        }
    }

    enum AutomationSlot: String, Identifiable {
        case day, night, light, dark, lock
        var id: String { rawValue }

        var title: String {
            switch self {
            case .day: "Day"
            case .night: "Night"
            case .light: "Light"
            case .dark: "Dark"
            case .lock: "Lock Screen"
            }
        }
    }

    init() {
        favoriteIDs = Set(
            UserDefaults.standard.stringArray(forKey: "lumawall.favoriteIDs")?
                .compactMap(UUID.init(uuidString:)).map { WallpaperID(rawValue: $0) } ?? []
        )
        if let raw = UserDefaults.standard.string(forKey: "lumawall.powerProfile"),
            let profile = PowerProfile(rawValue: raw)
        {
            powerProfile = profile
        }
        if let raw = UserDefaults.standard.string(forKey: "lumawall.librarySort"),
            let sort = LibrarySort(rawValue: raw)
        {
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
            let playlistPlayback = try PlaylistPlaybackStore()
            let recents = try RecentsStore()
            let automations = try AutomationStore()
            let energyLog = try EnergyLogStore()
            let crashes = try CrashReportStore()
            let displays = DisplayCoordinator()
            self.store = store
            self.importer = MediaImporter(store: store, probe: MediaServiceClient.shared)
            self.assignmentStore = assignments
            self.playlistStore = playlists
            self.playlistPlaybackStore = playlistPlayback
            self.recentsStore = recents
            self.automationStore = automations
            self.energyLogStore = energyLog
            self.crashReportStore = crashes
            self.displayCoordinator = displays
            self.engine = WallpaperEngine(displays: displays, assignments: assignments)
            self.displays = displays.displays
            self.launchAtLogin = LaunchAtLogin.isEnabled
            startCrashReporting()
            Task { await bootstrap() }
            startEnergyLogging()
            observeAppearanceChanges()
            observeAutomationClockChanges()
            observeReduceMotion()
            observeScreenChanges()
            observeDesktopCoverage()
            observeLockAndSleep()
            observePowerChanges()
            observeGameMode()
        } catch {
            fatalError("Unable to initialize LumaWall: \(error)")
        }
    }

    var displayRefreshWorkItem: DispatchWorkItem?
    var nativeRestoreWorkItem: DispatchWorkItem?

    /// Latched occlusion verdicts (see OcclusionLatch): raw window coverage is
    /// evaluated every policy tick, but the paused verdict holds until coverage
    /// falls back past the release thresholds.
    var occlusionLatch = OcclusionLatch()
}
