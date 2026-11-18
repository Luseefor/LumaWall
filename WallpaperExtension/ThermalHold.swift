import Foundation

/// Smooths the thermal state playback policy sees. A rise applies at once, so
/// heat protection is never delayed. A fall applies only after the lower state
/// has held for `releaseDelay`: macOS can flip between nominal and fair every
/// second, and each flip switched Full <-> 1080p and restarted the video.
struct ThermalHold {
    static let releaseDelay: TimeInterval = 120

    private(set) var effective: ProcessInfo.ThermalState = .nominal
    private var coolingSince: Date?

    init(initial: ProcessInfo.ThermalState = .nominal) {
        effective = initial
    }

    /// When a pending fall will apply if nothing changes, or nil.
    var releaseDate: Date? {
        coolingSince.map { $0.addingTimeInterval(Self.releaseDelay) }
    }

    /// Feeds a raw reading and returns the state policy should use.
    mutating func update(raw: ProcessInfo.ThermalState, now: Date) -> ProcessInfo.ThermalState {
        if raw.rawValue >= effective.rawValue {
            effective = raw
            coolingSince = nil
            return effective
        }
        let since = coolingSince ?? now
        if now.timeIntervalSince(since) >= Self.releaseDelay {
            effective = raw
            coolingSince = nil
        } else {
            coolingSince = since
        }
        return effective
    }
}
