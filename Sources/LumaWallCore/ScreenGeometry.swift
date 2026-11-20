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
    /// no single window does. Sweeps vertical slabs between window edges and
    /// merges the covered y-intervals in each: O(n² log n), a few thousand
    /// steps for a typical desktop, so it is safe on the main thread.
    public static func unionCoverageRatio(screen: CGRect, windows: [CGRect]) -> CGFloat {
        let area = screen.width * screen.height
        guard area > 0 else { return 0 }
        let clipped = windows.compactMap { window -> CGRect? in
            let hit = window.intersection(screen)
            return hit.isNull || hit.isInfinite || hit.isEmpty ? nil : hit
        }
        guard !clipped.isEmpty else { return 0 }
        let xs = Array(Set(clipped.flatMap { [$0.minX, $0.maxX] })).sorted()
        var covered: CGFloat = 0
        for (x0, x1) in zip(xs, xs.dropFirst()) {
            let midX = (x0 + x1) / 2
            let spans =
                clipped
                .filter { $0.minX < midX && midX < $0.maxX }
                .map { (low: $0.minY, high: $0.maxY) }
                .sorted { $0.low < $1.low }
            var length: CGFloat = 0
            var run: (low: CGFloat, high: CGFloat)?
            for span in spans {
                if let current = run, span.low <= current.high {
                    run = (current.low, max(current.high, span.high))
                } else {
                    if let current = run { length += current.high - current.low }
                    run = span
                }
            }
            if let current = run { length += current.high - current.low }
            covered += (x1 - x0) * length
        }
        return min(1, covered / area)
    }

    public static func isCovered(screen: CGRect, windows: [CGRect], threshold: CGFloat = 0.92) -> Bool {
        coverageRatio(screen: screen, windows: windows) >= threshold
    }
}
