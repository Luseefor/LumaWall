import AppKit
import CoreGraphics
import Darwin
import LumaWallCore

/// Pings the wallpaper extension and falls back displays it stopped
/// serving (ADR 0003). The rules are in `ExtensionHealth`; this class
/// supplies the clock, the events, the ping and the answer file.
@MainActor
final class NativeHealthMonitor {
    struct Session {
        var sessionLocked: Bool
        var displaysAsleep: Bool
    }

    /// Displays the app plays natively, by CoreGraphics ID.
    private let watchedDisplays: () -> [UInt32: DisplayID]
    private let session: () -> Session
    private let onUnserved: (Set<DisplayID>) -> Void
    private let documentsURL: URL
    private let defaults: UserDefaults

    private var health = ExtensionHealth(now: 0)
    private var timer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var screenSaverRunning = false
    private var wasProbing = false
    private var seenRestarts = 0
    private(set) var isRunning = false

    init(
        documentsURL: URL = WallpaperHostCapabilities.extensionDocumentsURL,
        watchedDisplays: @escaping () -> [UInt32: DisplayID],
        defaults: UserDefaults = .standard,
        session: @escaping () -> Session,
        onUnserved: @escaping (Set<DisplayID>) -> Void
    ) {
        self.documentsURL = documentsURL
        self.defaults = defaults
        self.watchedDisplays = watchedDisplays
        self.session = session
        self.onUnserved = onUnserved
    }

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// The build whose extension answered a ping. After an update the old
    /// extension can keep running for a while without answering, so only
    /// the same build counts.
    private static let answeredKey = "lumawall.extensionHealthAnsweredBuild"
    private static var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "" }
    private var answeredBefore: Bool { defaults.string(forKey: Self.answeredKey) == Self.build }

    /// Runs while native mode is the host. Starting begins with a grace period.
    func setRunning(_ running: Bool) {
        guard running != isRunning else { return }
        isRunning = running
        if running {
            health = ExtensionHealth(now: Self.now, heardBefore: answeredBefore)
            seenRestarts = LiveSystemWallpaperFiles.storeChangeCount
            // Starting already waits out a grace; don't add another.
            wasProbing = true
            observe()
            schedule(after: ExtensionHealth.grace)
        } else {
            timer?.invalidate()
            timer = nil
            for (center, token) in observers { center.removeObserver(token) }
            observers.removeAll()
        }
    }

    /// Wake, a display change, a Space switch: macOS may drop and re-acquire
    /// surfaces on its own for a while.
    func disturb() {
        health.disturb(at: Self.now)
    }

    private func observe() {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        let disturbing: [(NotificationCenter, Notification.Name)] = [
            (workspace, NSWorkspace.didWakeNotification),
            (workspace, NSWorkspace.screensDidWakeNotification),
            (workspace, NSWorkspace.activeSpaceDidChangeNotification),
            (NotificationCenter.default, NSApplication.didChangeScreenParametersNotification),
            (distributed, Notification.Name("com.apple.screenIsUnlocked")),
        ]
        for (center, name) in disturbing {
            observers.append(
                (
                    center,
                    center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.disturb() }
                    }
                ))
        }
        for (name, running) in [("com.apple.screensaver.didstart", true), ("com.apple.screensaver.didstop", false)] {
            observers.append(
                (
                    distributed,
                    distributed.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated {
                            self?.screenSaverRunning = running
                            self?.disturb()
                        }
                    }
                ))
        }
    }

    private func schedule(after delay: TimeInterval, _ action: @escaping @MainActor (NativeHealthMonitor) -> Void = { $0.tick() }) {
        timer?.invalidate()
        let timer = Timer(timeInterval: max(delay, 1), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isRunning else { return }
                action(self)
            }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Current conditions, after noting any agent restart and any return
    /// from a state where probing isn't allowed.
    private func conditions(watching watched: [UInt32: DisplayID]) -> ExtensionHealth.Conditions {
        let now = Self.now
        if LiveSystemWallpaperFiles.storeChangeCount != seenRestarts {
            seenRestarts = LiveSystemWallpaperFiles.storeChangeCount
            health.disturb(at: now)
        }
        let session = session()
        let conditions = ExtensionHealth.Conditions(
            nativeActive: !watched.isEmpty, sessionLocked: session.sessionLocked,
            displaysAsleep: session.displaysAsleep, screenSaverRunning: screenSaverRunning)
        if conditions.allowsProbing, !wasProbing { health.disturb(at: now) }
        wasProbing = conditions.allowsProbing
        return conditions
    }

    private func tick() {
        let now = Self.now
        let conditions = conditions(watching: awakeWatched())
        guard health.canProbe(conditions, at: now) else {
            let wait = max(health.quietUntil - now, 0)
            schedule(after: min(max(wait, ExtensionHealth.suspectInterval), ExtensionHealth.healthyInterval))
            return
        }
        health.probeSent(at: now, previous: readReply())
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName("app.lumawall.personal.healthPing" as CFString),
            nil, nil, true)
        schedule(after: ExtensionHealth.replyWait) { $0.finishProbe() }
    }

    private func finishProbe() {
        let watched = awakeWatched()
        // A store write, lock or sleep since the ping cancels it.
        if !conditions(watching: watched).allowsProbing { health.disturb(at: Self.now) }
        let heard = health.hasHeardReply
        let unserved = health.probeFinished(reply: readReply(), watching: Set(watched.keys), at: Self.now)
        if health.hasHeardReply, !heard, !answeredBefore { defaults.set(Self.build, forKey: Self.answeredKey) }
        report(unserved, watched: watched)
        schedule(after: health.nextProbeDelay - ExtensionHealth.replyWait)
    }

    /// Hands displays to Safe mode, except where another Space shows a
    /// wallpaper that isn't LumaWall's: the extension doesn't run there, so
    /// a miss proves nothing. An unreadable store proves nothing either.
    private func report(_ unserved: Set<UInt32>, watched: [UInt32: DisplayID]) {
        guard !unserved.isEmpty, let others = WallpaperStoreProbe.displaysShowingOthers() else { return }
        let failed = unserved.filter { cg in
            NativeWallpaperAssignmentService.stableUUID(for: cg).map { !others.contains($0) } ?? false
        }
        guard !failed.isEmpty else { return }
        let ids = failed.map(String.init).sorted().joined(separator: ", ")
        nativeHostLog.error("health: extension stopped serving display(s) [\(ids, privacy: .public)]")
        onUnserved(Set(failed.compactMap { watched[$0] }))
    }

    /// Watched displays that are online, awake and not mirroring another.
    private func awakeWatched() -> [UInt32: DisplayID] {
        watchedDisplays().filter { cg, _ in
            CGDisplayIsOnline(cg) != 0 && CGDisplayIsAsleep(cg) == 0 && CGDisplayMirrorsDisplay(cg) == kCGNullDirectDisplay
        }
    }

    /// The answer file. The extension can write its container, so it is
    /// read without following a link, only when it's a small regular file,
    /// and without blocking on a FIFO.
    private func readReply() -> ExtensionHealth.Reply? {
        let path = documentsURL.appendingPathComponent(ExtensionHealth.Reply.fileName).path
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
            info.st_size <= ExtensionHealth.Reply.maxFileSize,
            let data = try? handle.read(upToCount: ExtensionHealth.Reply.maxFileSize + 1)
        else { return nil }
        return ExtensionHealth.Reply.decode(data)
    }
}
