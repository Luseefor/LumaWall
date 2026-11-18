import Foundation

/// Decides when the window list must be fetched and analysed again.
public enum CoverageScanPolicy {
    /// Quiet period that merges a burst of workspace notifications into one scan.
    public static let debounce: TimeInterval = 0.25

    /// Whether the 30 s fallback timer needs a fresh scan. Coverage only
    /// changes playback when someone can see the desktop and a wallpaper plays.
    public static func fallbackScanNeeded(
        userPausedEverywhere: Bool,
        displaysAsleep: Bool,
        sessionLocked: Bool,
        hasAssignedWallpaper: Bool
    ) -> Bool {
        hasAssignedWallpaper && !userPausedEverywhere && !displaysAsleep && !sessionLocked
    }

    public enum PowerChange: Equatable, Sendable {
        case none
        /// Only the charge level moved.
        case percentOnly
        /// AC and battery swapped; automations and the menu-bar rule depend on it.
        case sourceSwitched
    }

    public static func powerChange(from old: PowerStatus, to new: PowerStatus) -> PowerChange {
        if old.isOnBattery != new.isOnBattery { return .sourceSwitched }
        return old.percent != new.percent ? .percentOnly : .none
    }
}

/// Remembers the last IOPS sample and the power source the cached coverage
/// was measured under, so a callback never trusts coverage taken under the
/// other source (the menu-bar rule only applies on battery).
public struct PowerSampleTracker: Sendable, Equatable {
    public private(set) var lastSample: PowerStatus?
    public private(set) var coverageOnBattery: Bool?

    public init() {}

    /// Call whenever a window scan ran, with the source it used.
    public mutating func noteCoverageScan(onBattery: Bool) {
        coverageOnBattery = onBattery
    }

    /// Classifies a new sample against the previous one and the cached coverage.
    public mutating func observe(_ sample: PowerStatus) -> CoverageScanPolicy.PowerChange {
        defer { lastSample = sample }
        guard let last = lastSample else { return .sourceSwitched }
        if coverageOnBattery != sample.isOnBattery { return .sourceSwitched }
        return CoverageScanPolicy.powerChange(from: last, to: sample)
    }
}

/// One cancellable main-actor timer: each `signal()` restarts the quiet
/// period, and the action runs once after the last signal unless cancelled.
@MainActor
public final class CoverageDebouncer {
    private let delay: Duration
    private let action: @MainActor () -> Void
    private var task: Task<Void, Never>?

    public init(delay: Duration, action: @escaping @MainActor () -> Void) {
        self.delay = delay
        self.action = action
    }

    public func signal() {
        task?.cancel()
        task = Task { [delay, action] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            action()
        }
    }

    public func cancel() {
        task?.cancel()
        task = nil
    }
}
