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
