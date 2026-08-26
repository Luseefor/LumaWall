import AVFoundation
import AppKit
import LumaWallCore
import QuartzCore

/// Live wallpaper presenter for the current milestone.
///
/// Strategy:
/// 1. Install the poster as the *real* macOS desktop picture for that screen.
/// 2. Keep a muted looping video panel at desktop-icon level so motion continues.
/// 3. If the compositor briefly hides the panel during Space switches, the matching
///    poster remains as the system wallpaper — never the previous static image.
@MainActor
final class WallpaperEngine {
    private let displays: DisplayCoordinator
    private let assignments: AssignmentStore
    private var sessions: [DisplayID: DesktopVideoSession] = [:]
    private(set) var isPausedGlobally = false

    init(displays: DisplayCoordinator, assignments: AssignmentStore) {
        self.displays = displays
        self.assignments = assignments
        NotificationCenter.default.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reassertAll() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.rebuildGeometry() }
        }
    }

    var activeDisplayIDs: Set<DisplayID> { Set(sessions.keys) }

    func wallpaperID(on displayID: DisplayID) -> WallpaperID? {
        sessions[displayID]?.asset.id
    }

    func apply(_ asset: WallpaperAsset, to displayID: DisplayID, composition: DisplayComposition = .init()) async throws {
        guard let screen = displays.screen(for: displayID),
              let connected = displays.display(id: displayID) else {
            throw EngineError.missingDisplay
        }

        installSystemPoster(asset.posterURL ?? asset.mediaURL, on: screen)
        if let existing = sessions[displayID] {
            existing.replace(asset: asset, composition: composition, screen: screen, connected: connected)
        } else {
            let session = DesktopVideoSession(asset: asset, composition: composition, screen: screen, connected: connected)
            sessions[displayID] = session
            session.show()
        }
        if isPausedGlobally { sessions[displayID]?.pause() }

        try await assignments.upsert(
            DisplayAssignment(displayID: displayID, wallpaperID: asset.id, composition: composition, isEnabled: true)
        )
    }

    func applyToAll(_ asset: WallpaperAsset, composition: DisplayComposition = .init()) async throws {
        for display in displays.refresh() {
            try await apply(asset, to: display.displayID, composition: composition)
        }
    }

    func clear(_ displayID: DisplayID) async throws {
        sessions.removeValue(forKey: displayID)?.tearDown()
        try await assignments.clear(displayID: displayID)
    }

    func clearAll() async throws {
        for key in sessions.keys {
            sessions.removeValue(forKey: key)?.tearDown()
        }
        try await assignments.clearAll()
    }

    func setPaused(_ paused: Bool) {
        isPausedGlobally = paused
        for session in sessions.values {
            if paused { session.pause() } else { session.resume() }
        }
    }

    func restore(using library: [WallpaperAsset]) async {
        let snapshot = await assignments.current()
        let byID = Dictionary(uniqueKeysWithValues: library.map { ($0.id, $0) })
        for assignment in snapshot.assignments where assignment.isEnabled {
            guard let wallpaperID = assignment.wallpaperID, let asset = byID[wallpaperID] else { continue }
            try? await apply(asset, to: assignment.displayID, composition: assignment.composition)
        }
    }

    private func reassertAll() {
        for session in sessions.values { session.reassert() }
    }

    private func rebuildGeometry() {
        displays.refresh()
        for (id, session) in sessions {
            guard let screen = displays.screen(for: id),
                  let connected = displays.display(id: id) else { continue }
            session.relayout(screen: screen, connected: connected)
        }
    }

    private func installSystemPoster(_ url: URL, on screen: NSScreen) {
        let options: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .imageScaling: NSNumber(value: Int(NSImageScaling.scaleProportionallyUpOrDown.rawValue)),
            .allowClipping: true
        ]
        try? NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: options)
    }

    enum EngineError: LocalizedError {
        case missingDisplay
        var errorDescription: String? { "That display is no longer connected." }
    }
}

@MainActor
final class DesktopVideoSession {
    private(set) var asset: WallpaperAsset
    private var composition: DisplayComposition
    private let window: NSPanel
    private let root = SessionRootView()
    private var player = AVQueuePlayer()
    private var looper: AVPlayerLooper?

    init(asset: WallpaperAsset, composition: DisplayComposition, screen: NSScreen, connected: ConnectedDisplay) {
        self.asset = asset
        self.composition = composition
        window = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.animationBehavior = .none
        window.contentView = root
        configurePlayer(url: asset.mediaURL)
        relayout(screen: screen, connected: connected)
    }

    func show() {
        window.orderFrontRegardless()
        player.play()
    }

    func replace(asset: WallpaperAsset, composition: DisplayComposition, screen: NSScreen, connected: ConnectedDisplay) {
        self.asset = asset
        self.composition = composition
        configurePlayer(url: asset.mediaURL)
        relayout(screen: screen, connected: connected)
        player.play()
        reassert()
    }

    func relayout(screen: NSScreen, connected: ConnectedDisplay) {
        let frame = screen.frame
        window.setFrame(frame, display: true)
        root.bounds = CGRect(origin: .zero, size: frame.size)
        root.apply(composition: composition, poster: asset.posterURL)
        root.playerLayer.frame = root.bounds
    }

    func reassert() {
        window.orderFrontRegardless()
        window.level = NSWindow.Level(Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)
    }

    func pause() { player.pause() }
    func resume() { player.play() }

    func tearDown() {
        player.pause()
        looper = nil
        root.playerLayer.player = nil
        window.orderOut(nil)
        window.close()
    }

    private func configurePlayer(url: URL) {
        player.pause()
        looper = nil
        player = AVQueuePlayer()
        player.isMuted = true
        player.actionAtItemEnd = .none
        player.automaticallyWaitsToMinimizeStalling = false
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        root.playerLayer.player = player
        root.playerLayer.videoGravity = gravity(for: composition.contentMode)
    }

    private func gravity(for mode: ContentMode) -> AVLayerVideoGravity {
        switch mode {
        case .fill: .resizeAspectFill
        case .fit: .resizeAspect
        case .stretch: .resize
        }
    }
}

private final class SessionRootView: NSView {
    let playerLayer = AVPlayerLayer()
    private let posterLayer = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        posterLayer.contentsGravity = .resizeAspectFill
        layer?.addSublayer(posterLayer)
        playerLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(playerLayer)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        posterLayer.frame = bounds
        playerLayer.frame = bounds
    }

    func apply(composition: DisplayComposition, poster: URL?) {
        if let poster, let image = NSImage(contentsOf: poster) {
            posterLayer.contents = image
        } else {
            posterLayer.contents = nil
        }
        switch composition.contentMode {
        case .fill: playerLayer.videoGravity = .resizeAspectFill
        case .fit: playerLayer.videoGravity = .resizeAspect
        case .stretch: playerLayer.videoGravity = .resize
        }
    }
}
