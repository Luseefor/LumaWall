import Foundation
import IOKit.ps

public struct PowerStatus: Sendable, Equatable {
    public var isOnBattery: Bool
    public var percent: Int

    public init(isOnBattery: Bool, percent: Int) {
        self.isOnBattery = isOnBattery
        self.percent = percent
    }

    public static func current() -> PowerStatus {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else {
            return PowerStatus(isOnBattery: false, percent: 100)
        }

        var percent = 100
        var onBattery = false
        for source in list {
            guard let info = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }
            if let value = info[kIOPSCurrentCapacityKey] as? Int {
                percent = min(percent, max(0, value))
            }
            if let state = info[kIOPSPowerSourceStateKey] as? String {
                onBattery = onBattery || state == kIOPSBatteryPowerValue
            }
        }
        return PowerStatus(isOnBattery: onBattery, percent: percent)
    }
}
