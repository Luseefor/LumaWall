import AVFoundation
import AppKit
import LumaWallCore
import QuartzCore

@MainActor
final class WallpaperEngine {
    private let displays: DisplayCoordinator
    private let assignments: AssignmentStore
    private var sessions: [DisplayID: DesktopVideoSession] = [:]
    private var tiers: [DisplayID: PlaybackTier] = [:]

    init(displays: DisplayCoordinator, assignments: AssignmentStore) {
        self.displays = displays
        self.assignments = assignments
        NotificationCenter.default.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.scheduleSurfaceRecovery() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.rebuildGeometry() }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.scheduleSurfaceRecovery() }
        }
        workspace.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == "com.apple.finder" || app?.bundleIdentifier == "com.apple.dock" else { return }
            Task { @MainActor in self?.scheduleSurfaceRecovery() }
        }
    }

    var activeDisplayIDs: Set<DisplayID> { Set(sessions.keys) }

    func wallpaperID(on displayID: DisplayID) -> WallpaperID? {
        sessions[displayID]?.asset.id
    }

    func composition(on displayID: DisplayID) -> DisplayComposition {
        sessions[displayID]?.currentComposition ?? .init()
    }

    func tier(on displayID: DisplayID) -> PlaybackTier {
        tiers[displayID] ?? .full
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
        apply(tier: tiers[displayID] ?? .full, to: displayID)

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
        tiers.removeValue(forKey: displayID)
        try await assignments.clear(displayID: displayID)
    }

    func clearAll() async throws {
        for key in sessions.keys {
            sessions.removeValue(forKey: key)?.tearDown()
        }
        tiers.removeAll()
        try await assignments.clearAll()
    }

    func apply(tier: PlaybackTier, to displayID: DisplayID) {
        tiers[displayID] = tier
        sessions[displayID]?.apply(tier: tier)
    }

    func restore(using library: [WallpaperAsset]) async {
        let snapshot = await assignments.current()
        let byID = Dictionary(uniqueKeysWithValues: library.map { ($0.id, $0) })
        for assignment in snapshot.assignments where assignment.isEnabled {
            guard let wallpaperID = assignment.wallpaperID, let asset = byID[wallpaperID] else { continue }
            if sessions[assignment.displayID]?.asset.id == wallpaperID { continue }
            try? await apply(asset, to: assignment.displayID, composition: assignment.composition)
        }
    }

    private func reassertAll() {
        for (id, session) in sessions {
            let tier = tiers[id] ?? .full
            if tier == .staticFrame || tier == .minimal { continue }
            session.reassert()
        }
    }

    private func scheduleSurfaceRecovery() {
        reassertAll()
        for delay in [0.08, 0.35] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.reassertAll()
            }
        }
    }

    private func rebuildGeometry() {
        let connectedIDs = Set(displays.refresh().map(\.displayID))
        for id in sessions.keys where !connectedIDs.contains(id) {
            sessions.removeValue(forKey: id)?.tearDown()
            tiers.removeValue(forKey: id)
        }
        for (id, session) in sessions {
            guard let screen = displays.screen(for: id),
                  let connected = displays.display(id: id) else { continue }
            session.relayout(screen: screen, connected: connected)
            session.apply(tier: tiers[id] ?? .full)
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
    private var decoderReleaseWorkItem: DispatchWorkItem?
    private var decoderIsLoaded = false
    var currentComposition: DisplayComposition { composition }

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

    func apply(tier: PlaybackTier) {
        decoderReleaseWorkItem?.cancel()
        decoderReleaseWorkItem = nil
        switch tier {
        case .full:
            ensureDecoder()
            setBitRate(0)
            root.playerLayer.isHidden = false
            window.orderFrontRegardless()
            player.rate = 1
            player.play()
        case .reduced:
            ensureDecoder()
            setBitRate(2_000_000)
            root.playerLayer.isHidden = false
            window.orderFrontRegardless()
            player.rate = 1
            player.play()
        case .minimal, .staticFrame:
            player.pause()
            root.playerLayer.isHidden = true
            window.orderOut(nil)
            scheduleDecoderRelease(after: 12)
        case .paused:
            player.pause()
            root.playerLayer.isHidden = false
            scheduleDecoderRelease(after: 30)
        }
    }

    func tearDown() {
        decoderReleaseWorkItem?.cancel()
        player.pause()
        looper = nil
        root.playerLayer.player = nil
        window.orderOut(nil)
        window.close()
        decoderIsLoaded = false
    }

    private func setBitRate(_ bits: Double) {
        player.currentItem?.preferredPeakBitRate = bits
    }

    private func configurePlayer(url: URL) {
        decoderReleaseWorkItem?.cancel()
        player.pause()
        looper = nil
        player = AVQueuePlayer()
        player.isMuted = true
        player.actionAtItemEnd = .none
        player.automaticallyWaitsToMinimizeStalling = false
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        root.playerLayer.player = player
        root.playerLayer.videoGravity = gravity(for: composition.contentMode)
        decoderIsLoaded = true
    }

    private func ensureDecoder() {
        guard !decoderIsLoaded else { return }
        configurePlayer(url: asset.mediaURL)
    }

    private func scheduleDecoderRelease(after delay: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            player.pause()
            looper = nil
            root.playerLayer.player = nil
            root.playerLayer.isHidden = true
            player = AVQueuePlayer()
            player.isMuted = true
            decoderIsLoaded = false
        }
        decoderReleaseWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
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
    private var composition = DisplayComposition()

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
        applyTransform()
    }

    func apply(composition: DisplayComposition, poster: URL?) {
        self.composition = composition
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
        applyTransform()
    }

    private func applyTransform() {
        let focal = CGPoint(
            x: min(max(composition.focalPoint.x, 0), 1),
            y: min(max(composition.focalPoint.y, 0), 1)
        )
        let anchor = CGPoint(x: focal.x, y: focal.y)
        let position = CGPoint(
            x: bounds.width * focal.x + composition.offset.x,
            y: bounds.height * focal.y + composition.offset.y
        )
        let radians = CGFloat(composition.rotationDegrees * .pi / 180)
        let scale = CGFloat(min(max(composition.scale, 0.25), 4))
        var transform = CGAffineTransform(rotationAngle: radians)
        transform = transform.scaledBy(x: scale, y: scale)
        for layer in [posterLayer, playerLayer] {
            layer.anchorPoint = anchor
            layer.position = position
            layer.setAffineTransform(transform)
        }
    }
}
