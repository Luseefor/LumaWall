import CoreGraphics
import Foundation

/// One on-screen window as the window server reports it.
public struct OnscreenWindow: Equatable, Sendable {
    public var layer: Int
    public var alpha: CGFloat
    /// Quartz coordinates: y-down from the primary display's top-left.
    public var bounds: CGRect

    public init(layer: Int, alpha: CGFloat, bounds: CGRect) {
        self.layer = layer
        self.alpha = alpha
        self.bounds = bounds
    }

    /// Reads the current on-screen window list. Desktop elements are excluded.
    public static func current() -> [OnscreenWindow] {
        guard let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return [] }
        return info.compactMap { dict in
            guard let bounds = dict[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
            return OnscreenWindow(
                layer: dict[kCGWindowLayer as String] as? Int ?? 0,
                alpha: dict[kCGWindowAlpha as String] as? CGFloat ?? 1,
                bounds: CGRect(
                    x: bounds["X"] ?? 0,
                    y: bounds["Y"] ?? 0,
                    width: bounds["Width"] ?? 0,
                    height: bounds["Height"] ?? 0
                )
            )
        }
    }
}

/// Decides which displays app windows cover or own fullscreen.
public enum DisplayOcclusion {
    public struct Analysis: Equatable, Sendable {
        public var covered: Set<DisplayID>
        public var fullscreen: Set<DisplayID>
        /// Max single-window coverage ratio per display, for hysteresis.
        public var coverage: [DisplayID: CGFloat]
    }

    public static func analyze(windows: [OnscreenWindow], displays: [ConnectedDisplay]) -> Analysis {
        let desktop = displays.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        guard !desktop.isNull else { return Analysis(covered: [], fullscreen: [], coverage: [:]) }
        // Mirror Quartz rects around the PRIMARY display's top (see
        // ScreenGeometry.cocoaWindow): the union's maxY is only correct when
        // no display extends above the primary.
        let primaryHeight = displays.first(where: \.isMain)?.frame.height ?? desktop.maxY
        let rects = windows
            .filter(isAppWindow)
            .map { ScreenGeometry.cocoaWindow(fromQuartz: $0.bounds, primaryHeight: primaryHeight) }

        var analysis = Analysis(covered: [], fullscreen: [], coverage: [:])
        for display in displays {
            let ratio = ScreenGeometry.coverageRatio(screen: display.frame, windows: rects)
            analysis.coverage[display.displayID] = ratio
            // Require near-total occlusion before auto-pausing (see
            // PlaybackPolicyThresholds). Lower values flap pause/resume on
            // maximized windows with menu bar/dock visible (~96% coverage).
            if ratio >= PlaybackPolicyThresholds.occlusionCovered {
                analysis.covered.insert(display.displayID)
            }
            if rects.contains(where: { ownsFullscreen($0, display: display.frame) }) {
                analysis.fullscreen.insert(display.displayID)
            }
        }
        return analysis
    }

    /// Only app windows can hide the wallpaper. System chrome above them (the
    /// Dock at layer 20, the menu bar and Screenshot UI at 24 and up) reports
    /// full-panel opaque windows on a bare desktop, and counting those paused
    /// the wallpaper with nothing covering it. Invisible windows don't count.
    static func isAppWindow(_ window: OnscreenWindow) -> Bool {
        window.layer >= normalLayer && window.layer < dockLayer && window.alpha > 0.01
    }

    private static let normalLayer = Int(CGWindowLevelForKey(.normalWindow))
    private static let dockLayer = Int(CGWindowLevelForKey(.dockWindow))

    private static func ownsFullscreen(_ rect: CGRect, display: CGRect) -> Bool {
        ScreenGeometry.coverageRatio(screen: display, windows: [rect]) >= PlaybackPolicyThresholds.fullscreenCoverage
            && abs(rect.width - display.width) < PlaybackPolicyThresholds.fullscreenWidthTolerance
            && abs(rect.height - display.height) < PlaybackPolicyThresholds.fullscreenHeightTolerance
    }
}
