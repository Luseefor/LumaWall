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
    /// so the mirror line is the primary height, not the union's maxY, which
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

    /// Fraction of `screen` hidden by the union of `windows`. Overlaps count
    /// once, so tiled windows that together hide the screen reach 1 even when
    /// no single window does. Exact for rectangles: the screen is split into
    /// cells along every window edge and each covered cell is counted once.
    public static func unionCoverageRatio(screen: CGRect, windows: [CGRect]) -> CGFloat {
        let area = screen.width * screen.height
        guard area > 0 else { return 0 }
        let clipped = windows.compactMap { window -> CGRect? in
            let hit = window.intersection(screen)
            return hit.isNull || hit.isInfinite || hit.isEmpty ? nil : hit
        }
        guard !clipped.isEmpty else { return 0 }
        let xs = Array(Set(clipped.flatMap { [$0.minX, $0.maxX] })).sorted()
        let ys = Array(Set(clipped.flatMap { [$0.minY, $0.maxY] })).sorted()
        var covered: CGFloat = 0
        for (x0, x1) in zip(xs, xs.dropFirst()) {
            let midX = (x0 + x1) / 2
            for (y0, y1) in zip(ys, ys.dropFirst()) {
                let midY = (y0 + y1) / 2
                if clipped.contains(where: { $0.minX < midX && midX < $0.maxX && $0.minY < midY && midY < $0.maxY }) {
                    covered += (x1 - x0) * (y1 - y0)
                }
            }
        }
        return min(1, covered / area)
    }

    public static func isCovered(screen: CGRect, windows: [CGRect], threshold: CGFloat = 0.92) -> Bool {
        coverageRatio(screen: screen, windows: windows) >= threshold
    }
}
