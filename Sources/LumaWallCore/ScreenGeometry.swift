import CoreGraphics
import Foundation

public enum ScreenGeometry {
    public static func quartz(fromCocoa rect: CGRect, desktop: CGRect) -> CGRect {
        CGRect(
            x: rect.minX,
            y: desktop.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    public static func cocoa(fromQuartz rect: CGRect, desktop: CGRect) -> CGRect {
        CGRect(
            x: rect.minX,
            y: desktop.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// Cocoa rect for a window-server (Quartz, y-down) rect, mirrored around
    /// the PRIMARY display's top. Quartz coordinates run y-down from the
    /// primary's top-left while Cocoa frames run y-up from its bottom-left,
    /// so the mirror line is the primary height — NOT the union's maxY, which
    /// only coincides when no display extends above the primary (a taller
    /// sidecar or a stacked layout shifts every converted rect and coverage
    /// math misfires).
    public static func cocoaWindow(fromQuartz rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        cocoa(fromQuartz: rect, desktop: CGRect(x: 0, y: 0, width: 1, height: primaryHeight))
    }

    public static func coverageRatio(screen: CGRect, windows: [CGRect]) -> CGFloat {
        let area = screen.width * screen.height
        guard area > 0 else { return 0 }
        var best: CGFloat = 0
        for window in windows {
            let hit = window.intersection(screen)
            guard !hit.isNull, !hit.isInfinite else { continue }
            best = max(best, (hit.width * hit.height) / area)
        }
        return best
    }

    public static func isCovered(screen: CGRect, windows: [CGRect], threshold: CGFloat = 0.92) -> Bool {
        coverageRatio(screen: screen, windows: windows) >= threshold
    }
}
