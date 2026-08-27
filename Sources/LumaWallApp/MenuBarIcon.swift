import AppKit

/// The LumaWall status item glyph: a luminous crescent sweeping around a core
/// dot — the app icon reduced to a crisp monochrome template so it matches
/// every other menu bar icon in light and dark appearances.
enum MenuBarIcon {
    static func image(badge: Bool = false) -> NSImage {
        badge ? badged : plain
    }

    private static let plain = draw(badge: false)
    private static let badged = draw(badge: true)

    private enum Metrics {
        static let canvas: CGFloat = 18
        static let coreRadius: CGFloat = 2.4
        static let crescentOuter: CGFloat = 7.4
        static let crescentInner: CGFloat = 4.9
        static let badgeRadius: CGFloat = 2.2
    }

    private static func draw(badge: Bool) -> NSImage {
        let size = NSSize(width: Metrics.canvas, height: Metrics.canvas)
        let image = NSImage(size: size, flipped: false) { _ in
            let center = NSPoint(x: Metrics.canvas / 2, y: Metrics.canvas / 2)
            NSColor.black.setFill()

            // Core orb, offset slightly up-right like the app icon.
            let coreCenter = NSPoint(x: center.x + 1.1, y: center.y + 0.9)
            NSBezierPath(ovalIn: NSRect(
                x: coreCenter.x - Metrics.coreRadius,
                y: coreCenter.y - Metrics.coreRadius,
                width: Metrics.coreRadius * 2,
                height: Metrics.coreRadius * 2
            )).fill()

            // Crescent: outer arc sweeping the lower-left, closed by an inner
            // arc, producing a filled tapering ribbon.
            let crescent = NSBezierPath()
            crescent.appendArc(
                withCenter: center,
                radius: Metrics.crescentOuter,
                startAngle: 95,
                endAngle: 320,
                clockwise: false
            )
            crescent.appendArc(
                withCenter: NSPoint(x: center.x + 1.0, y: center.y + 0.8),
                radius: Metrics.crescentInner,
                startAngle: 320,
                endAngle: 95,
                clockwise: true
            )
            crescent.close()
            crescent.fill()

            if badge {
                let offset = Metrics.crescentOuter * 0.7071
                NSBezierPath(ovalIn: NSRect(
                    x: center.x + offset - Metrics.badgeRadius,
                    y: center.y + offset - Metrics.badgeRadius,
                    width: Metrics.badgeRadius * 2,
                    height: Metrics.badgeRadius * 2
                )).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

enum PlaybackScope: CaseIterable {
    case everywhere, lockScreen, paused

    var title: String {
        switch self {
        case .everywhere: "Everywhere"
        case .lockScreen: "Lock Screen"
        case .paused: "Paused"
        }
    }

    var symbol: String {
        switch self {
        case .everywhere: "play.fill"
        case .lockScreen: "lock.fill"
        case .paused: "pause.fill"
        }
    }
}
