import AppKit
import CoreGraphics
import Foundation

public struct ConnectedDisplay: Identifiable, Equatable, Hashable, Sendable {
    public func hash(into hasher: inout Hasher) { hasher.combine(displayID) }
    public var id: DisplayID { displayID }
    public let displayID: DisplayID
    public let name: String
    public let frame: CGRect
    public let pixelSize: CGSize
    public let scale: CGFloat
    public let refreshRate: Double
    public let isMain: Bool
    public let cgDisplayID: CGDirectDisplayID

    public init(
        displayID: DisplayID,
        name: String,
        frame: CGRect,
        pixelSize: CGSize,
        scale: CGFloat,
        refreshRate: Double,
        isMain: Bool,
        cgDisplayID: CGDirectDisplayID
    ) {
        self.displayID = displayID
        self.name = name
        self.frame = frame
        self.pixelSize = pixelSize
        self.scale = scale
        self.refreshRate = refreshRate
        self.isMain = isMain
        self.cgDisplayID = cgDisplayID
    }
}

@MainActor
public final class DisplayCoordinator {
    public private(set) var displays: [ConnectedDisplay] = []

    public init() {
        refresh()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    @discardableResult
    public func refresh() -> [ConnectedDisplay] {
        displays = NSScreen.screens.compactMap { Self.describe($0) }
        return displays
    }

    public func display(id: DisplayID) -> ConnectedDisplay? {
        displays.first { $0.displayID == id }
    }

    public func mainDisplay() -> ConnectedDisplay? {
        displays.first(where: \.isMain) ?? displays.first
    }

    public func screen(for id: DisplayID) -> NSScreen? {
        NSScreen.screens.first { Self.stableID(for: $0) == id }
    }

    public static func stableID(for screen: NSScreen) -> DisplayID {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        let cgID = CGDirectDisplayID(number?.uint32Value ?? 0)
        if let uuid = CGDisplayCreateUUIDFromDisplayID(cgID)?.takeRetainedValue() {
            let string = CFUUIDCreateString(nil, uuid) as String
            return DisplayID(rawValue: string)
        }
        return DisplayID(rawValue: "screen-\(cgID)")
    }

    private static func describe(_ screen: NSScreen) -> ConnectedDisplay? {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        let cgID = CGDirectDisplayID(number?.uint32Value ?? 0)
        guard cgID != 0 else { return nil }
        let frame = screen.frame
        let scale = screen.backingScaleFactor
        return ConnectedDisplay(
            displayID: stableID(for: screen),
            name: screen.localizedName,
            frame: frame,
            pixelSize: CGSize(width: frame.width * scale, height: frame.height * scale),
            scale: scale,
            refreshRate: screen.maximumFramesPerSecond.doubleValue,
            isMain: screen == NSScreen.main,
            cgDisplayID: cgID
        )
    }
}

private extension Int {
    var doubleValue: Double { Double(self) }
}
