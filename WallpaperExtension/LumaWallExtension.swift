import AppKit
import ExtensionFoundation
import Foundation
import os

@main
final class LumaWallExtension: NSObject, AppExtension {
    override required init() {
        super.init()

        let frameworkPath = "/System/Library/PrivateFrameworks/WallpaperExtensionKit.framework/WallpaperExtensionKit"
        if let handle = dlopen(frameworkPath, RTLD_LAZY) {
            // Keep the handle open. The framework must stay loaded for vtable/C-function-pointer validity.
            _ = handle
            extensionLog("INIT (PID: \(ProcessInfo.processInfo.processIdentifier)). WallpaperExtensionKit loaded")
            verifyRuntimeLayout()
            VideoLibrary.shared.scan()
            observeLibraryChanges()
            observeCacheControls()
            observeHealthPings()
            // Push current view models shortly after launch: the extension is only
            // ever spawned by a host connection, and the host's disk cache may
            // predate library changes made while no extension process was alive to
            // push them (issue #27). The delay lets the spawning connection's
            // accept() register its proxy first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                Task { await SettingsPush.push() }
            }
            observeDisplaySleepWake()
            // After the observers, so a wake posted from here on still lands.
            Self.catchUpDisplaySleep()
            observeScreenLockState()
            WallpaperPrefs.shared.observeChanges()
            WallpaperXPCHandler.startGeometryAudit()
            PowerMonitor.shared.startMonitoring()
            Task {
                for await _ in PowerMonitor.shared.stateChanges() {
                    // A signal, not a value: the queued read applies the latest
                    // snapshot. On the queue `updateBody` runs on, so a
                    // notification that waits behind a lock or unlock can't
                    // reapply a sample older than the one that update read.
                    guard Self.powerSignal.withLock({ $0.notified() }) else { continue }
                    Lifecycle.queue.async { Self.applyLatestPower() }
                }
            }
        } else {
            let err = String(cString: dlerror())
            extensionLog("INIT (PID: \(ProcessInfo.processInfo.processIdentifier)), dlopen failed: \(err)")
        }
    }

    /// Startup self-check: confirm the private WallpaperExtensionKit classes the
    /// extension bridges to are present after dlopen. This doesn't fail the
    /// launch. The per-call guards already fail closed, but it surfaces an
    /// unsupported OS/runtime layout in one clear log line up front instead of
    /// as scattered downstream failures, which is the documented manual
    /// compatibility check for OS upgrades.
    private func verifyRuntimeLayout() {
        let critical = [
            "WallpaperRemoteContextXPC",
            "WallpaperSnapshotXPC",
            "WallpaperCreationRequestXPC",
            "WallpaperSettingsViewModelsXPC",
            "WallpaperIDXPC",
        ]
        var missing = critical.filter { objc_getClass($0) == nil }
        // The ivars and selectors the raw writes in RuntimeHelpers rely on.
        let slots = [("WallpaperRemoteContextXPC", "box", 4), ("WallpaperSnapshotXPC", "rawValue", 8)]
        for (name, ivar, bytes) in slots {
            if let cls = objc_getClass(name) as? AnyClass, RuntimeLayout.ivarSlot(named: ivar, in: cls, bytes: bytes) == nil {
                missing.append("\(name).\(ivar)")
            }
        }
        for selector in ["remoteContext", "remoteContextWithOptions:"]
        where !RuntimeLayout.respondsToClassSelector(CAContext.self, selector) {
            missing.append("CAContext.\(selector)")
        }
        if missing.isEmpty {
            extensionLog(
                "  [SelfCheck] Runtime layout OK: \(critical.count) classes, the XPC ivar layout and CAContext's class methods; instance methods are checked per acquire"
            )
        } else {
            extensionLog(
                "  [SelfCheck] UNSUPPORTED RUNTIME, missing: \(missing.joined(separator: ", ")). Rendering/snapshots may be degraded.")
        }
    }

    /// Observe display sleep/wake to stop rendering when no display is awake
    /// and resume on wake with correct policy.
    private func observeDisplaySleepWake() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil, queue: .main,
        ) { _ in
            // Set before notifying: a renderer starting now reads it instead.
            WallpaperState.shared.noteDisplaySleepNotification(asleep: true)
            WallpaperState.shared.forEachRenderer { renderer in
                renderer.displayDidSleep()
            }
            extensionLog("[Extension] Displays asleep, paused all renderers")
        }
        center.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil, queue: .main,
        ) { _ in
            WallpaperState.shared.noteDisplaySleepNotification(asleep: false)
            // The Mac may have been unplugged while the displays slept. Only
            // the power source: brightness catches up off the main thread.
            PowerMonitor.shared.readPowerSource()
            // Recompute first: renderers still asleep only record the new tiers,
            // so the wake below resumes on fresh policy instead of briefly
            // playing on the one from before sleep. Wake also reaches the
            // previews the recompute skips.
            Self.recomputeAndApplyPolicy()
            WallpaperState.shared.forEachRenderer { renderer in
                renderer.displayDidWake()
            }
            ShuffleController.shared.noteWake()
            extensionLog("[Extension] Displays awake, recomputed policy (locked: \(WallpaperState.shared.isScreenLocked))")

            // Recompute again after a short delay to catch any pending
            // WallpaperAgent presentation mode updates that arrive after wake.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                Self.recomputeAndApplyPolicy()
            }
        }
    }

    /// Close the sleep gate when the displays report asleep but no
    /// `screensDidSleep` arrived: a process launched during display sleep
    /// never gets one (#34). Run at launch and before each acquire builds a
    /// renderer, so no first frame starts decoding in the dark.
    /// A wake notified while the displays are sampled wins (`SleepGate`).
    static func catchUpDisplaySleep() {
        let state = WallpaperState.shared
        let epoch = state.displaySleepEpoch
        let displays = DisplaySleep.onlineDisplays()
        guard state.catchUpDisplaySleep(sampledAt: epoch, displays: displays) else { return }
        extensionLog("[Extension] All \(displays.count) online display(s) report asleep with no sleep notification, paused all renderers")
    }

    /// Track screen lock state via distributed notifications from loginwindow.
    /// This lets us know the lock screen is showing even before the WallpaperAgent
    /// sends a presentation mode update, fixing the race where a video paused
    /// on the desktop doesn't resume on the lock screen after lid open. Any
    /// process can post these names, so each hint is checked against the
    /// login session first (`ScreenLockHint`).
    private func observeScreenLockState() {
        let sessionLocked = ScreenLockHint.sessionIsLocked()
        Self.lockHints.withLock { $0 = LockHintTracker(sessionLocked: sessionLocked) }
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(
            forName: .init("com.apple.screenIsLocked"),
            object: nil, queue: .main,
        ) { _ in
            Self.applyLockHint(locked: true, retries: 1)
        }
        dnc.addObserver(
            forName: .init("com.apple.screenIsUnlocked"),
            object: nil, queue: .main,
        ) { _ in
            Self.applyLockHint(locked: false, retries: 1)
        }
    }

    /// Confirmed lock hints so far, plus locks the Agent reported. Locked:
    /// hints arrive on the main queue, Agent updates on the lifecycle queue.
    private static let lockHints = OSAllocatedUnfairLock(initialState: LockHintTracker(sessionLocked: nil))

    /// The Agent reported the lock screen (`WallpaperXPCHandler.update`).
    static func noteAgentLocked() {
        lockHints.withLock { $0.noteAgentLocked() }
    }

    /// Main queue. The session flag can trail loginwindow's notification, so
    /// a hint the session doesn't confirm yet is checked again a second later
    /// before it's dropped. A confirmed hint recomputes policy itself: a
    /// retry can land after the wake's own recomputes.
    private static func applyLockHint(locked: Bool, retries: Int) {
        let session = ScreenLockHint.sessionIsLocked()
        guard ScreenLockHint.shouldApply(claimsLocked: locked, sessionLocked: session) else {
            if retries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    applyLockHint(locked: locked, retries: retries - 1)
                }
            } else {
                extensionLog(
                    "[Extension] Ignored screen \(locked ? "lock" : "unlock") hint: session says locked=\(session.map(String.init) ?? "unknown")"
                )
            }
            return
        }
        let woke = lockHints.withLock { $0.confirm(locked: locked) }
        WallpaperState.shared.isScreenLocked = locked
        recomputeAndApplyPolicy()
        if woke {
            ShuffleController.shared.noteWake()
        }
        extensionLog("[Extension] Screen \(locked ? "locked" : "unlocked"), recomputed policy")
    }

    /// Power notifications waiting to be applied (`PowerSignal`). Notified
    /// from the subscriber task, taken and applied on `Lifecycle.queue`.
    private static let powerSignal = OSAllocatedUnfairLock(initialState: PowerSignal())

    /// `Lifecycle.queue` only.
    private static func applyLatestPower() {
        let power = powerSignal.withLock { $0.take(latest: PowerMonitor.shared.latestState) }
        let state = WallpaperState.shared
        WallpaperPrefs.shared.applyPolicies(
            presentationMode: state.presentationMode,
            activityState: state.activityState,
            powerState: power,
        )
    }

    /// Recompute playback policy from current state and apply to all renderers.
    static func recomputeAndApplyPolicy() {
        let state = WallpaperState.shared
        WallpaperPrefs.shared.applyPolicies(
            presentationMode: effectivePresentationMode(state),
            activityState: state.activityState,
            powerState: PowerMonitor.shared.currentState,
        )
    }

    /// The tier `recomputeAndApplyPolicy` would give a renderer on
    /// `displayID` now, so it opens the right copy before its first frame and
    /// on a switch. Previews take the preview tier, which ignores the
    /// desktop rules.
    static func policyForRenderer(displayID: UInt32?, isPreview: Bool) -> PlaybackPolicy {
        guard !isPreview else {
            return WallpaperPrefs.shared.previewPolicy(powerState: PowerMonitor.shared.currentState)
        }
        let state = WallpaperState.shared
        return WallpaperPrefs.shared.policy(
            for: displayID,
            presentationMode: effectivePresentationMode(state),
            activityState: state.activityState,
            powerState: PowerMonitor.shared.currentState,
        )
    }

    /// When we know the screen is locked but the WallpaperAgent hasn't
    /// updated the presentation mode yet (e.g., right after display wake),
    /// use "locked" to prevent stale desktop-mode policy from blocking lock
    /// screen playback.
    private static func effectivePresentationMode(_ state: WallpaperState) -> String {
        state.isScreenLocked && state.presentationMode != "locked" ? "locked" : state.presentationMode
    }

    /// Listen for Darwin notifications from the main app when it adds/removes videos.
    private func observeLibraryChanges() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, _, _, _, _ in
                VideoLibrary.shared.scan()
                extensionLog("[Extension] Library changed notification received, re-scanned")
                // A copy may have been published for a held preview.
                WallpaperState.shared.forPreviewRenderers { $0.libraryDidChange() }
                SettingsPush.libraryDidChange()
            },
            "app.lumawall.personal.libraryChanged" as CFString,
            nil,
            .deliverImmediately,
        )
    }

    private func observeCacheControls() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            center, observer,
            { _, _, _, _, _ in clearWallpaperSnapshotCache() },
            "app.lumawall.personal.clearCaches" as CFString,
            nil, .deliverImmediately,
        )
    }

    /// The app's check that this extension still serves its displays (ADR 0003).
    private func observeHealthPings() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            center, observer,
            { _, _, _, _, _ in
                guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                else { return }
                HealthReply.answer(documents: documents) { WallpaperState.shared.liveDisplayIDs() }
            },
            HealthAnswers.pingName as CFString,
            nil, .deliverImmediately,
        )
    }

    var configuration: some AppExtensionConfiguration {
        WallpaperExtensionConfig()
    }
}
