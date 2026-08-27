import AVFoundation
import AppKit
import LumaWallCore
import QuartzCore

@MainActor
final class OverlayWallpaperEngine {
    private let displays: DisplayCoordinator
    private let assignments: AssignmentStore
    private var sessions: [DisplayID: DesktopVideoSession] = [:]
    private var tiers: [DisplayID: PlaybackTier] = [:]
    private var recoveryWorkItems: [DispatchWorkItem] = []

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
        try activate(asset, on: displayID, composition: composition)
        try await assignments.upsert(
            DisplayAssignment(displayID: displayID, wallpaperID: asset.id, composition: composition, isEnabled: true)
        )
    }

    private func activate(_ asset: WallpaperAsset, on displayID: DisplayID, composition: DisplayComposition) throws {
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
    }

    func applyToAll(_ asset: WallpaperAsset, composition: DisplayComposition = .init()) async throws {
        let connected = displays.refresh()
        guard !connected.isEmpty else { throw EngineError.missingDisplay }
        for display in connected {
            try activate(asset, on: display.displayID, composition: composition)
        }
        try await assignments.upsert(connected.map {
            DisplayAssignment(displayID: $0.displayID, wallpaperID: asset.id, composition: composition, isEnabled: true)
        })
        synchronize(displayIDs: connected.map(\.displayID))
    }

    func applySpanning(_ asset: WallpaperAsset) async throws {
        let connected = displays.refresh()
        guard !connected.isEmpty else { throw EngineError.missingDisplay }
        guard let canvas = SpanningGeometry.canvas(for: connected.map(\.frame)) else {
            throw EngineError.missingDisplay
        }
        let composition = DisplayComposition(contentMode: .fill, spanningCanvas: canvas)
        for display in connected {
            try activate(asset, on: display.displayID, composition: composition)
        }
        try await assignments.upsert(connected.map {
            DisplayAssignment(displayID: $0.displayID, wallpaperID: asset.id, composition: composition, isEnabled: true)
        })
        synchronize(displayIDs: connected.map(\.displayID))
    }

    private func synchronize(displayIDs: [DisplayID]) {
        let clock = CMClockGetHostTimeClock()
        let now = CMClockGetTime(clock)
        let start = CMTimeAdd(now, CMTime(seconds: 0.25, preferredTimescale: 1_000_000_000))
        for id in displayIDs where tiers[id] == .full || tiers[id] == .reduced {
            sessions[id]?.synchronize(atHostTime: start, tier: tiers[id] ?? .full)
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
        guard tiers[displayID] != tier else { return }
        tiers[displayID] = tier
        sessions[displayID]?.apply(tier: tier)
    }

    func restore(using library: [WallpaperAsset]) async {
        let snapshot = await assignments.current()
        let byID = Dictionary(uniqueKeysWithValues: library.map { ($0.id, $0) })
        let connectedByID = Dictionary(uniqueKeysWithValues: displays.refresh().map { ($0.displayID, $0) })
        var restoredAssignments = snapshot.assignments
        var topologyChanged = false

        // A spanning canvas is derived from the screens that are currently part
        // of that wallpaper group. Recalculate it after docking, rotation, or a
        // resolution change while retaining assignments for disconnected screens.
        let spanningWallpaperIDs = Set(restoredAssignments.compactMap { assignment in
            assignment.composition.spanningCanvas == nil ? nil : assignment.wallpaperID
        })
        for wallpaperID in spanningWallpaperIDs {
            let indices = restoredAssignments.indices.filter { index in
                restoredAssignments[index].wallpaperID == wallpaperID
                    && restoredAssignments[index].composition.spanningCanvas != nil
                    && connectedByID[restoredAssignments[index].displayID] != nil
            }
            let frames = indices.compactMap { connectedByID[restoredAssignments[$0].displayID]?.frame }
            guard let canvas = SpanningGeometry.canvas(for: frames) else { continue }
            for index in indices where restoredAssignments[index].composition.spanningCanvas != canvas {
                restoredAssignments[index].composition.spanningCanvas = canvas
                topologyChanged = true
            }
        }
        if topologyChanged {
            try? await assignments.replaceAll(with: restoredAssignments)
        }

        var synchronizedGroups: [WallpaperID: [DisplayID]] = [:]
        for assignment in restoredAssignments where assignment.isEnabled {
            guard let wallpaperID = assignment.wallpaperID, let asset = byID[wallpaperID] else { continue }
            guard connectedByID[assignment.displayID] != nil else { continue }
            synchronizedGroups[wallpaperID, default: []].append(assignment.displayID)
            if let session = sessions[assignment.displayID],
               session.asset.id == wallpaperID,
               session.currentComposition == assignment.composition {
                continue
            }
            try? activate(asset, on: assignment.displayID, composition: assignment.composition)
        }
        for ids in synchronizedGroups.values where ids.count > 1 {
            synchronize(displayIDs: ids)
        }
    }

    func reapplyAssignments() {
        displays.refresh()
        for (id, session) in sessions {
            guard let screen = displays.screen(for: id),
                  let connected = displays.display(id: id) else { continue }
            installSystemPoster(session.asset.posterURL ?? session.asset.mediaURL, on: screen)
            session.relayout(screen: screen, connected: connected)
            session.apply(tier: tiers[id] ?? .full)
            session.reassert()
        }
    }

    private func reassertAll() {
        for session in sessions.values {
            session.reassert()
        }
    }

    private func scheduleSurfaceRecovery() {
        recoveryWorkItems.forEach { $0.cancel() }
        recoveryWorkItems.removeAll(keepingCapacity: true)
        reassertAll()
        // Dock finishes changing Space ownership asynchronously. Keep retries short
        // enough that a surface is never absent for a visible fraction of a second.
        for delay in [0.016, 0.08, 0.20] {
            let work = DispatchWorkItem { [weak self] in self?.reassertAll() }
            recoveryWorkItems.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
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
    private let window: DesktopSurfaceWindow
    private let root = SessionRootView()
    private var player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private var decoderReleaseWorkItem: DispatchWorkItem?
    private var decoderIsLoaded = false
    private var readinessObservation: NSKeyValueObservation?
    private var requestedTier: PlaybackTier = .full
    private var displayPixelSize = CGSize.zero
    var currentComposition: DisplayComposition { composition }

    init(asset: WallpaperAsset, composition: DisplayComposition, screen: NSScreen, connected: ConnectedDisplay) {
        self.asset = asset
        self.composition = composition
        displayPixelSize = connected.pixelSize
        window = DesktopSurfaceWindow(
            contentRect: .zero,
            styleMask: [.borderless],
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
        window.canHide = false
        window.isExcludedFromWindowsMenu = true
        window.sharingType = .none
        window.animationBehavior = .none
        window.contentView = root
        readinessObservation = root.playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
            let isReady = layer.isReadyForDisplay
            Task { @MainActor [weak self] in
                guard let self else { return }
                root.setVideoVisible(isReady && requestedTier.showsMotion)
            }
        }
        root.apply(composition: composition, poster: asset.posterURL, displayFrame: connected.frame)
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
        relayout(screen: screen, connected: connected)
        configurePlayer(url: asset.mediaURL)
        apply(tier: requestedTier)
        reassert()
    }

    func relayout(screen: NSScreen, connected: ConnectedDisplay) {
        displayPixelSize = connected.pixelSize
        let frame = screen.frame
        window.setFrame(frame, display: true)
        root.bounds = CGRect(origin: .zero, size: frame.size)
        root.apply(composition: composition, poster: asset.posterURL, displayFrame: connected.frame)
    }

    func reassert() {
        window.level = NSWindow.Level(Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)
        window.orderFrontRegardless()
        window.displayIfNeeded()
    }

    func apply(tier: PlaybackTier) {
        requestedTier = tier
        decoderReleaseWorkItem?.cancel()
        decoderReleaseWorkItem = nil
        switch tier {
        case .full:
            ensureDecoder()
            configureDecodeBudget(bitRate: 0, maximumResolution: .zero)
            root.setVideoVisible(root.playerLayer.isReadyForDisplay)
            reassert()
            player.rate = 1
            player.play()
        case .reduced:
            ensureDecoder()
            configureDecodeBudget(bitRate: 2_000_000, maximumResolution: reducedResolution)
            root.setVideoVisible(root.playerLayer.isReadyForDisplay)
            reassert()
            player.rate = 1
            player.play()
        case .minimal, .staticFrame:
            player.pause()
            root.setVideoVisible(false)
            reassert()
            scheduleDecoderRelease(after: 2)
        case .paused:
            player.pause()
            root.setVideoVisible(root.playerLayer.isReadyForDisplay)
            reassert()
            scheduleDecoderRelease(after: 10)
        }
    }

    func tearDown() {
        decoderReleaseWorkItem?.cancel()
        readinessObservation?.invalidate()
        player.pause()
        looper = nil
        root.playerLayer.player = nil
        window.orderOut(nil)
        window.close()
        decoderIsLoaded = false
    }

    func synchronize(atHostTime hostTime: CMTime, tier: PlaybackTier) {
        decoderReleaseWorkItem?.cancel()
        ensureDecoder()
        requestedTier = tier
        configureDecodeBudget(
            bitRate: tier == .reduced ? 2_000_000 : 0,
            maximumResolution: tier == .reduced ? reducedResolution : .zero
        )
        root.setVideoVisible(root.playerLayer.isReadyForDisplay)
        reassert()
        player.setRate(1, time: .zero, atHostTime: hostTime)
    }

    private var reducedResolution: CGSize {
        let landscape = displayPixelSize.width >= displayPixelSize.height
        return landscape ? CGSize(width: 1_920, height: 1_080) : CGSize(width: 1_080, height: 1_920)
    }

    private func configureDecodeBudget(bitRate: Double, maximumResolution: CGSize) {
        for item in player.items() {
            item.preferredPeakBitRate = bitRate
            item.preferredMaximumResolution = maximumResolution
        }
    }

    private func configurePlayer(url: URL) {
        decoderReleaseWorkItem?.cancel()
        root.setVideoVisible(false)
        player.pause()
        looper = nil
        player = AVQueuePlayer()
        player.isMuted = true
        player.actionAtItemEnd = .none
        player.automaticallyWaitsToMinimizeStalling = false
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 1
        looper = AVPlayerLooper(player: player, templateItem: item)
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
            root.setVideoVisible(false)
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

private extension PlaybackTier {
    var showsMotion: Bool {
        switch self {
        case .full, .reduced, .paused: true
        case .minimal, .staticFrame: false
        }
    }
}

/// A wallpaper surface must never participate in normal app activation, window
/// cycling, hiding, or focus. Its lifetime is owned by the engine, not AppKit's
/// ordinary document-window lifecycle.
private final class DesktopSurfaceWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class SessionRootView: NSView {
    let playerLayer = AVPlayerLayer()
    private let posterLayer = CALayer()
    private var composition = DisplayComposition()
    private var displayFrame = CGRect.zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.cgColor
        posterLayer.actions = Self.disabledActions
        posterLayer.contentsGravity = .resizeAspectFill
        layer?.addSublayer(posterLayer)
        playerLayer.actions = Self.disabledActions
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.isHidden = true
        layer?.addSublayer(playerLayer)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let frame = mediaFrame
        posterLayer.frame = frame
        playerLayer.frame = frame
        applyTransform()
    }

    func apply(composition: DisplayComposition, poster: URL?, displayFrame: CGRect) {
        self.composition = composition
        self.displayFrame = displayFrame
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

    func setVideoVisible(_ visible: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.isHidden = !visible
        CATransaction.commit()
    }

    private var mediaFrame: CGRect {
        guard let canvas = composition.spanningCanvas else { return bounds }
        return SpanningGeometry.mediaFrame(canvas: canvas, on: displayFrame)
    }

    private func applyTransform() {
        let frame = mediaFrame
        let focal = CGPoint(
            x: min(max(composition.focalPoint.x, 0), 1),
            y: min(max(composition.focalPoint.y, 0), 1)
        )
        let anchor = CGPoint(x: focal.x, y: focal.y)
        let position = CGPoint(
            x: frame.minX + frame.width * focal.x + composition.offset.x,
            y: frame.minY + frame.height * focal.y + composition.offset.y
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

    private static let disabledActions: [String: CAAction] = [
        "bounds": NSNull(),
        "contents": NSNull(),
        "hidden": NSNull(),
        "position": NSNull(),
        "sublayers": NSNull(),
        "transform": NSNull()
    ]
}
