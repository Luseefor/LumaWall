import AppKit
import CoreGraphics
import Foundation

/// One on-screen window as the window server reports it.
public struct OnscreenWindow: Equatable, Sendable {
    public var layer: Int
    public var alpha: CGFloat
    /// Quartz coordinates: y-down from the primary display's top-left.
    public var bounds: CGRect
    /// True when a regular (Dock-visible) app owns the window. False for the
    /// Dock, WindowServer, Screenshot, Control Center and other system agents.
    public var ownerIsRegularApp: Bool

    public init(layer: Int, alpha: CGFloat, bounds: CGRect, ownerIsRegularApp: Bool = true) {
        self.layer = layer
        self.alpha = alpha
        self.bounds = bounds
        self.ownerIsRegularApp = ownerIsRegularApp
    }

    /// Reads the current on-screen window list. Desktop elements are excluded.
    public static func current() -> [OnscreenWindow] {
        guard
            let info = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
            ) as? [[String: Any]]
        else { return [] }
        var regularByPID: [pid_t: Bool] = [:]
        func isRegular(_ pid: pid_t) -> Bool {
            if let known = regularByPID[pid] { return known }
            let regular = NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular
            regularByPID[pid] = regular
            return regular
        }
        return info.compactMap { dict in
            guard let bounds = dict[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
            let pid = (dict[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
            return OnscreenWindow(
                layer: dict[kCGWindowLayer as String] as? Int ?? 0,
                alpha: dict[kCGWindowAlpha as String] as? CGFloat ?? 1,
                bounds: CGRect(
                    x: bounds["X"] ?? 0,
                    y: bounds["Y"] ?? 0,
                    width: bounds["Width"] ?? 0,
                    height: bounds["Height"] ?? 0
                ),
                ownerIsRegularApp: pid.map(isRegular) ?? false
            )
        }
    }
}

/// Decides which displays app windows cover or own fullscreen.
public enum DisplayOcclusion {
    public struct Analysis: Equatable, Sendable {
        public var covered: Set<DisplayID>
        public var fullscreen: Set<DisplayID>
        /// Fraction of each display hidden by app windows, for hysteresis.
        public var coverage: [DisplayID: CGFloat]
    }

    /// `ignoringMenuBar` measures coverage below each display's menu bar.
    /// With a window maximized under the menu bar, the compositor showed
    /// none of the wallpaper's decoded frames, so on battery that counts as
    /// covered. On AC the whole display is measured, as before.
    public static func analyze(
        windows: [OnscreenWindow],
        displays: [ConnectedDisplay],
        ignoringMenuBar: Bool = false
    ) -> Analysis {
        let desktop = displays.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        guard !desktop.isNull else { return Analysis(covered: [], fullscreen: [], coverage: [:]) }
        // Mirror Quartz rects around the PRIMARY display's top (see
        // ScreenGeometry.cocoaWindow): the union's maxY is only correct when
        // no display extends above the primary.
        let primaryHeight = displays.first(where: \.isMain)?.frame.height ?? desktop.maxY
        let rects =
            windows
            .filter(isAppWindow)
            .map { ScreenGeometry.cocoaWindow(fromQuartz: $0.bounds, primaryHeight: primaryHeight) }

        var analysis = Analysis(covered: [], fullscreen: [], coverage: [:])
        for display in displays {
            // Union, not the largest window: side-by-side windows that
            // together hide the wallpaper should pause it too.
            var measured = display.frame
            if ignoringMenuBar {
                // Cocoa coordinates: the menu bar is at the top (maxY).
                measured.size.height = max(0, measured.height - display.menuBarHeight)
            }
            let ratio = ScreenGeometry.unionCoverageRatio(screen: measured, windows: rects)
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

    /// Only app windows can hide the wallpaper. System chrome (the Dock at
    /// layer 20, the menu bar and Screenshot UI at 24 and up) reports
    /// full-panel opaque windows on a bare desktop, and counting those paused
    /// the wallpaper with nothing covering it. Windows from the normal level
    /// up to the Dock always count. Above that, only a regular app's windows
    /// count: GLFW games go fullscreen at the main menu level + 1, and Game
    /// Mode doesn't always catch them. Invisible windows never count.
    static func isAppWindow(_ window: OnscreenWindow) -> Bool {
        guard window.alpha > 0.01, window.layer >= normalLayer else { return false }
        return window.layer < dockLayer || window.ownerIsRegularApp
    }

    private static let normalLayer = Int(CGWindowLevelForKey(.normalWindow))
    private static let dockLayer = Int(CGWindowLevelForKey(.dockWindow))

    private static func ownsFullscreen(_ rect: CGRect, display: CGRect) -> Bool {
        ScreenGeometry.coverageRatio(screen: display, windows: [rect]) >= PlaybackPolicyThresholds.fullscreenCoverage
            && abs(rect.width - display.width) < PlaybackPolicyThresholds.fullscreenWidthTolerance
            && abs(rect.height - display.height) < PlaybackPolicyThresholds.fullscreenHeightTolerance
    }
}
