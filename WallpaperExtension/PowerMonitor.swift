import Foundation
import IOKit.ps
import notify
import os

final class PowerMonitor: Sendable {
    static let shared = PowerMonitor()

    private let state = OSAllocatedUnfairLock(initialState: PowerState())
    private let continuations = OSAllocatedUnfairLock(initialState: [UUID: AsyncStream<PowerState>.Continuation]())
    private nonisolated(unsafe) var _batteryScheduler: NSBackgroundActivityScheduler?
    private let gameModeTokens = OSAllocatedUnfairLock(initialState: [Int32]())

    /// gamepolicyd's state-carrying Darwin notification for Game Mode sessions
    /// (name recovered from the gamepolicyd binary; posted with notify_set_state).
    /// The app host historically used `...currentGameplayState`; watch both so
    /// a wrong guess on either side fails open instead of never pausing.
    private static let gameModeNotifications = [
        "com.apple.gamepolicy.game-mode-session",
        "com.apple.gamepolicy.currentGameplayState",
    ]

    struct PowerState: Equatable {
        var thermalState: ProcessInfo.ThermalState = .nominal
        var isOnBattery = false
        var batteryLevel: Int = 100
        var isGameModeActive: Bool = false
        var isLowPowerModeEnabled = false
        /// Backlight brightness of the built-in display, 0.0–1.0. Defaults to 1.0
        /// when the value can't be read (external displays, headless, etc.).
        var displayBrightness: Float = 1.0
    }

    private init() {}

    /// Current power state snapshot.
    var currentState: PowerState {
        state.withLock { $0 }
    }

    /// Re-read battery + brightness now and notify subscribers on change.
    /// The scheduled poll runs every ~30s, so without this a prefs change
    /// (e.g. the user picking Battery Saver right after unplugging) applies
    /// against stale power state and looks like "nothing changes".
    func refreshNow() {
        updateBatteryState()
        updateBrightnessState()
    }

    /// AsyncStream that yields whenever any component of power state changes.
    /// Yields the current value immediately upon subscription.
    func stateChanges() -> AsyncStream<PowerState> {
        let (stream, continuation) = AsyncStream.makeStream(of: PowerState.self)
        let id = UUID()
        continuations.withLock { $0[id] = continuation }

        continuation.onTermination = { [weak self] _ in
            self?.continuations.withLock { $0[id] = nil }
        }

        continuation.yield(currentState)
        return stream
    }

    /// Start monitoring power state. Call once at extension startup.
    func startMonitoring() {
        state.withLock {
            $0.thermalState = ProcessInfo.processInfo.thermalState
            $0.isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        updateBatteryState()
        updateBrightnessState()

        // Thermal state — event-driven via notification
        NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil, queue: nil,
        ) { [weak self] _ in
            self?.handleThermalChange()
        }
        NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil, queue: nil,
        ) { [weak self] _ in
            self?.handleLowPowerModeChange()
        }

        // Battery + brightness — OS-managed periodic check.
        // Brightness needs polling because IODisplay doesn't broadcast a
        // notification when the user drags the slider, and `screensDidSleep`
        // doesn't fire when brightness is held at zero manually.
        let scheduler = NSBackgroundActivityScheduler(
            identifier: "app.lumawall.personal.powerCheck",
        )
        scheduler.interval = 30
        scheduler.tolerance = 15
        scheduler.repeats = true
        scheduler.qualityOfService = .utility
        nonisolated(unsafe) let capturedScheduler = scheduler
        scheduler.schedule { [weak self] completion in
            guard let self else {
                completion(.finished)
                return
            }
            if capturedScheduler.shouldDefer {
                completion(.deferred)
                return
            }
            updateBatteryState()
            updateBrightnessState()
            completion(.finished)
        }
        _batteryScheduler = scheduler

        // Game Mode — event-driven via gamepolicyd's state-carrying notification.
        // Reaches the sandboxed extension: com.apple.* notify names aren't filtered.
        for name in Self.gameModeNotifications {
            var token = NOTIFY_TOKEN_INVALID
            let status = notify_register_dispatch(
                name, &token,
                DispatchQueue.global(qos: .utility),
            ) { [weak self] token in
                self?.updateGameModeState(token: token)
            }
            if status == UInt32(NOTIFY_STATUS_OK) {
                let registered = token
                gameModeTokens.withLock { $0.append(registered) }
                updateGameModeState(token: registered)
            } else {
                extensionLog("[PowerMonitor] Game Mode notify registration failed for \(name) (status \(status))")
            }
        }

        let thermal = ProcessInfo.processInfo.thermalState.rawValue
        extensionLog("[PowerMonitor] Started (thermal: \(thermal))")
    }

    // MARK: - Private

    private func handleThermalChange() {
        let previous = state.withLock { $0 }
        state.withLock { $0.thermalState = ProcessInfo.processInfo.thermalState }
        let current = state.withLock { $0 }
        guard previous != current else { return }
        extensionLog("[PowerMonitor] Thermal → \(current.thermalState.rawValue)")
        yieldToSubscribers(current)
    }

    private func handleLowPowerModeChange() {
        let previous = state.withLock { $0 }
        state.withLock { $0.isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled }
        let current = state.withLock { $0 }
        guard previous != current else { return }
        extensionLog("[PowerMonitor] Low Power Mode → \(current.isLowPowerModeEnabled)")
        yieldToSubscribers(current)
    }

    private func updateBatteryState() {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else { return }

        // Walk EVERY source: the list mixes battery + AC adapter entries, and
        // the adapter entry carries no capacity and reports AC state. Reading
        // only `sources.first` (the old code) pinned the host to AC/100% on
        // machines where the adapter sorts first — Automatic never saw battery,
        // and every profile evaluated against stale AC power ("does nothing").
        var percent = 100
        var onBattery = false
        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any]
            else { continue }
            if let value = desc[kIOPSCurrentCapacityKey] as? Int {
                percent = min(percent, max(0, value))
            }
            if let state = desc[kIOPSPowerSourceStateKey] as? String {
                onBattery = onBattery || state == kIOPSBatteryPowerValue
            }
        }

        let resolved = (onBattery: onBattery, percent: percent)
        let previous = state.withLock { $0 }
        state.withLock { s in
            s.isOnBattery = resolved.onBattery
            s.batteryLevel = resolved.percent
        }
        let current = state.withLock { $0 }
        guard previous != current else { return }
        extensionLog("[PowerMonitor] Battery → level=\(current.batteryLevel) onBattery=\(current.isOnBattery)")
        yieldToSubscribers(current)
    }

    /// Read the built-in display backlight via IORegistry. On systems without a
    /// backlight (Mac mini, Mac Studio, external-only setups) this returns 1.0
    /// so the policy never demotes to paused.
    private func updateBrightnessState() {
        let brightness = Self.readBuiltInBrightness() ?? 1.0
        let previous = state.withLock { $0 }
        state.withLock { $0.displayBrightness = brightness }
        let current = state.withLock { $0 }
        guard previous != current else { return }
        extensionLog("[PowerMonitor] Brightness → \(brightness)")
        yieldToSubscribers(current)
    }

    /// Returns the built-in backlight brightness in 0.0–1.0, or nil if there is
    /// no backlit display attached.
    private static func readBuiltInBrightness() -> Float? {
        let matching = unsafe IOServiceMatching("AppleBacklightDisplay")
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iter) }

        var brightness: Float?
        while case let service = IOIteratorNext(iter), service != IO_OBJECT_NULL {
            defer { IOObjectRelease(service) }
            guard let propsRef = unsafe IORegistryEntryCreateCFProperty(
                service,
                "IODisplayParameters" as CFString,
                kCFAllocatorDefault,
                0,
            ) else { continue }
            guard let params = unsafe propsRef.takeRetainedValue() as? [String: Any],
                  let brightnessParam = params["brightness"] as? [String: Any],
                  let value = brightnessParam["value"] as? Int,
                  let min = brightnessParam["min"] as? Int,
                  let max = brightnessParam["max"] as? Int,
                  max > min
            else { continue }
            brightness = Float(value - min) / Float(max - min)
            break
        }
        return brightness
    }

    /// A Game Mode session is active while the notification's state is non-zero.
    private func updateGameModeState(token: Int32) {
        var sessionState: UInt64 = 0
        guard notify_get_state(token, &sessionState) == UInt32(NOTIFY_STATUS_OK) else { return }
        let isActive = sessionState != 0
        let previous = state.withLock { $0 }
        state.withLock { $0.isGameModeActive = isActive }
        let current = state.withLock { $0 }
        guard previous != current else { return }
        extensionLog("[PowerMonitor] Game Mode → \(isActive ? "active" : "inactive"), shouldPause via policy")
        yieldToSubscribers(current)
    }

    private func yieldToSubscribers(_ state: PowerState) {
        // Snapshot under lock, yield outside: continuations may re-enter
        // PowerMonitor synchronously, and yielding while holding the lock
        // risks deadlock + stalls all publishers on a slow subscriber.
        let live = continuations.withLock { Array($0.values) }
        for continuation in live {
            continuation.yield(state)
        }
    }
}

extension PlaybackPolicy {
    /// Convenience overload that unpacks a `PowerMonitor.PowerState`.
    static func compute(
        presentationMode: String,
        activityState: String,
        userPaused: Bool,
        alwaysPauseDesktop: Bool,
        pauseWhenOccluded: Bool,
        desktopOccluded: Bool,
        displayHasFullscreenApp: Bool = false,
        screenSaverIsOurs: Bool,
        powerState: PowerMonitor.PowerState,
        powerProfile: String = "automatic",
    ) -> PlaybackPolicy {
        compute(
            presentationMode: presentationMode,
            activityState: activityState,
            userPaused: userPaused,
            alwaysPauseDesktop: alwaysPauseDesktop,
            pauseWhenOccluded: pauseWhenOccluded,
            desktopOccluded: desktopOccluded,
            displayHasFullscreenApp: displayHasFullscreenApp,
            screenSaverIsOurs: screenSaverIsOurs,
            thermalState: powerState.thermalState,
            isOnBattery: powerState.isOnBattery,
            batteryLevel: powerState.batteryLevel,
            isGameModeActive: powerState.isGameModeActive,
            isLowPowerModeEnabled: powerState.isLowPowerModeEnabled,
            displayBrightness: powerState.displayBrightness,
            powerProfile: powerProfile,
        )
    }
}
