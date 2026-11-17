import AppKit
import LumaWallCore
import SwiftUI

extension PowerProfile {
    var label: String {
        switch self {
        case .automatic: "Automatic"
        case .fullQuality: "Full Quality"
        case .batterySaver: "Battery Saver"
        case .staticOnBattery: "Static on Battery"
        }
    }

    var detail: String {
        switch self {
        case .automatic: "Full fidelity on power, adaptive on battery."
        case .fullQuality: "Prefer source frame rate whenever possible."
        case .batterySaver: "Always use the lowest animated tier."
        case .staticOnBattery: "Hold a still frame until you switch back."
        }
    }

    var symbol: String {
        switch self {
        case .automatic: "leaf.fill"
        case .fullQuality: "bolt.fill"
        case .batterySaver: "battery.50"
        case .staticOnBattery: "pause.rectangle.fill"
        }
    }
}
