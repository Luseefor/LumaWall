import Foundation
import IOKit.ps
import notify
import os

final class PowerMonitor: Sendable {
    static let shared = PowerMonitor()

    private let state = OSAllocatedUnfairLock(initialState: PowerSample())
    /// Smooths thermal flips so a one-second dip doesn't switch tiers.
    /// Confined to `thermalQueue` with `pendingRelease`.
    nonisolated(unsafe) private var thermalHold = ThermalHold(initial: ProcessInfo.processInfo.thermalState)
    /// Release time already scheduled, so repeated readings don't stack timers.
    nonisolated(unsafe) private var pendingRelease: Date?
    /// Serializes every thermal reading (notifications and release timers).
    /// Without it a late "cooled" timer could publish nominal after a newer
    /// critical notification and resume playback on a hot machine.
    private let thermalQueue = DispatchQueue(label: "app.lumawall.thermal")
    private let continuations = OSAllocatedUnfairLock(initialState: [UUID: AsyncStream<PowerState>.Continuation]())
    /// Runs every battery and brightness read and owns the poll: `poller`
    /// and `pollTimer` are touched only here. Never call `currentState` on it.
    private let pollQueue = DispatchQueue(label: "app.lumawall.power-poll", qos: .utility)
    private nonisolated(unsafe) var poller = PowerPoller()
    private nonisolated(unsafe) var pollTimer: (any DispatchSourceTimer)?
    private static let pollLeeway: DispatchTimeInterval = .seconds(15)
    private let gameModeTokens = OSAllocatedUnfairLock(initialState: [Int32]())
    private let powerSourceToken = OSAllocatedUnfairLock(initialState: NOTIFY_TOKEN_INVALID)

    /// gamepolicyd's state-carrying Darwin notification for Game Mode sessions
    /// (name recovered from the gamepolicyd binary; posted with notify_set_state).
    /// The app host historically used `...currentGameplayState`; watch both so
    /// a wrong guess on either side fails open instead of never pausing.
    private static let gameModeNotifications = [
        "com.apple.gamepolicy.game-mode-session",
        "com.apple.gamepolicy.currentGameplayState",
    ]

    typealias PowerState = PowerSnapshot

    private init() {}

    /// Current power state, re-reading battery and brightness first when the
    /// last reading is older than the poll interval (the poll stops while
    /// nothing plays).
    var currentState: PowerState {
        let sample = state.withLock { $0 }
        guard sample.batteryIsStale(now: Date()) else { return sample.state }
        pollQueue.sync { if readIsStale() { readHardware() } }
        return state.withLock { $0.state }
    }

    /// Re-read battery + brightness now and notify subscribers on change.
    /// The scheduled poll runs every ~30s, so without this a prefs change
    /// (e.g. the user picking Battery Saver right after unplugging) applies
    /// against stale power state and looks like "nothing changes".
    @discardableResult
    func refreshNow() -> PowerState {
        pollQueue.sync { readHardware() }
        return state.withLock { $0.state }
    }

    /// A renderer started or stopped wanting playback. The poll runs while
    /// any renderer plays; the first one to start re-reads power at once,
    /// since nothing was read while all were paused.
    func notePlayback(renderer id: Int, playing isPlaying: Bool) {
        pollQueue.async { [weak self] in
            guard let self else { return }
            apply(poller.playback(id, playing: isPlaying))
            if poller.anyPlaying, readIsStale() { readHardware() }
        }
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
            $0.state.thermalState = ProcessInfo.processInfo.thermalState
            $0.state.isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        pollQueue.sync { readHardware() }

        // Thermal state, event-driven via notification
        NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil, queue: nil,
        ) { [weak self] _ in
            guard let self else { return }
            thermalQueue.async { [weak self] in self?.handleThermalChange() }
        }
        NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil, queue: nil,
        ) { [weak self] _ in
            self?.handleLowPowerModeChange()
        }

        // Battery and brightness are polled while it matters (`PowerPolling`).
        // Brightness needs polling because IODisplay doesn't broadcast a
        // notification when the user drags the slider, and `screensDidSleep`
        // doesn't fire when brightness is held at zero manually.
        //
        // An AC/battery flip is posted, so read at once instead of waiting
        // for the poll or for the reading to go stale: a lock or wake right
        // after unplugging would otherwise open the AC copy and ramp for 6 s.
        var sourceToken = NOTIFY_TOKEN_INVALID
        let sourceStatus = notify_register_dispatch(kIOPSNotifyPowerSource, &sourceToken, pollQueue) { [weak self] _ in
            self?.readHardware()
        }
        if sourceStatus == UInt32(NOTIFY_STATUS_OK) {
            let registered = sourceToken
            powerSourceToken.withLock { $0 = registered }
        } else {
            extensionLog("[PowerMonitor] Power source notify registration failed (status \(sourceStatus))")
        }

        // Game Mode, event-driven via gamepolicyd's state-carrying notification.
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

    /// Read battery (unless `battery` is false) and brightness, then bring
    /// the poll in line with the reading. Every read goes through here, so a
    /// read that finds a hardware pause starts the poll that can lift it.
    /// `pollQueue` only.
    private func readHardware(battery: Bool = true) {
        dispatchPrecondition(condition: .onQueue(pollQueue))
        let reading = battery ? Self.readBattery() : nil
        let brightness = Self.readBuiltInBrightness() ?? 1.0
        let (previous, changed, current) = state.withLock { sample in
            let previous = sample.state
            let changed = sample.merge(battery: reading, brightness: brightness, at: Date())
            return (previous, changed, sample.state)
        }
        if changed {
            if current.isOnBattery != previous.isOnBattery || current.batteryLevel != previous.batteryLevel {
                extensionLog("[PowerMonitor] Battery → level=\(current.batteryLevel) onBattery=\(current.isOnBattery)")
            }
            if current.displayBrightness != previous.displayBrightness {
                extensionLog("[PowerMonitor] Brightness → \(current.displayBrightness)")
            }
            yieldToSubscribers(current)
        }
        apply(poller.reading(batteryLevel: current.batteryLevel, displayBrightness: current.displayBrightness))
    }

    private func readIsStale() -> Bool {
        state.withLock { $0.batteryIsStale(now: Date()) }
    }

    /// Apply `change` under the lock; the new state when it differs.
    private func update(_ change: @Sendable (inout PowerState) -> Void) -> PowerState? {
        state.withLock { sample in
            let previous = sample.state
            change(&sample.state)
            return sample.state == previous ? nil : sample.state
        }
    }

    /// `pollQueue` only.
    private func apply(_ timer: PowerPoller.Timer) {
        switch timer {
        case .keep:
            return
        case .stop:
            pollTimer?.cancel()
            pollTimer = nil
        case .start:
            let source = DispatchSource.makeTimerSource(queue: pollQueue)
            source.schedule(deadline: .now() + PowerPolling.interval, repeating: PowerPolling.interval, leeway: Self.pollLeeway)
            source.setEventHandler { [weak self] in self?.poll() }
            pollTimer = source
            source.resume()
        }
        extensionLog("[PowerMonitor] Power poll → \(poller.mode)")
    }

    private func poll() {
        switch poller.mode {
        case .off: return
        case .brightness: readHardware(battery: false)
        case .all: readHardware()
        }
    }

    /// Runs on `thermalQueue` only.
    private func handleThermalChange() {
        dispatchPrecondition(condition: .onQueue(thermalQueue))
        let raw = ProcessInfo.processInfo.thermalState
        let effective = thermalHold.update(raw: raw, now: Date())
        // A pending fall applies after the hold even if macOS posts nothing
        // more; re-check then, once per release time.
        if let releaseDate = thermalHold.releaseDate, releaseDate != pendingRelease {
            pendingRelease = releaseDate
            let delay = max(0, releaseDate.timeIntervalSinceNow) + 0.5
            thermalQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                if pendingRelease == releaseDate { pendingRelease = nil }
                handleThermalChange()
            }
        }
        guard let current = update({ $0.thermalState = effective }) else { return }
        extensionLog("[PowerMonitor] Thermal → \(current.thermalState.rawValue) (raw \(raw.rawValue))")
        yieldToSubscribers(current)
    }

    private func handleLowPowerModeChange() {
        let enabled = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard let current = update({ $0.isLowPowerModeEnabled = enabled }) else { return }
        extensionLog("[PowerMonitor] Low Power Mode → \(current.isLowPowerModeEnabled)")
        yieldToSubscribers(current)
    }

    /// The power source and lowest battery percentage, or nil when IOKit
    /// returns nothing.
    private static func readBattery() -> (onBattery: Bool, level: Int)? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        // Walk EVERY source: the list mixes battery + AC adapter entries, and
        // the adapter entry carries no capacity and reports AC state. Reading
        // only `sources.first` (the old code) pinned the host to AC/100% on
        // machines where the adapter sorts first. Automatic never saw battery,
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

        return (onBattery, percent)
    }

    /// Returns the built-in backlight brightness in 0.0–1.0, or nil if there is
    /// no backlit display attached (Mac mini, Mac Studio, external-only
    /// setups); callers read that as 1.0 so the policy never demotes to paused.
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
        guard let current = update({ $0.isGameModeActive = isActive }) else { return }
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
