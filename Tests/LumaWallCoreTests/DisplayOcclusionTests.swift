import CoreGraphics
import LumaWallCore
import Testing

struct DisplayOcclusionTests {
    private let panel = ConnectedDisplay(
        displayID: DisplayID(rawValue: "built-in"),
        name: "Built-in",
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        pixelSize: CGSize(width: 3024, height: 1964),
        scale: 2,
        refreshRate: 120,
        isMain: true,
        cgDisplayID: 1
    )

    private var fullPanel: CGRect { CGRect(x: 0, y: 0, width: 1512, height: 982) }

    @Test func dockAndScreenshotOverlaysDoNotPauseABareDesktop() {
        // Recorded on a bare desktop: the Dock (layer 20) and the Screenshot
        // UI (layer 24) each report an opaque full-panel window. Counting them
        // marked the display fullscreen and froze the native wallpaper.
        let windows = [
            OnscreenWindow(layer: 20, alpha: 1, bounds: fullPanel, ownerIsRegularApp: false),
            OnscreenWindow(layer: 24, alpha: 1, bounds: fullPanel, ownerIsRegularApp: false),
        ]
        let analysis = DisplayOcclusion.analyze(windows: windows, displays: [panel])
        #expect(analysis.fullscreen.isEmpty)
        #expect(analysis.covered.isEmpty)
        #expect(analysis.coverage[panel.displayID] == 0)
    }

    @Test func fullscreenAppWindowStillPauses() {
        let windows = [OnscreenWindow(layer: 0, alpha: 1, bounds: fullPanel)]
        let analysis = DisplayOcclusion.analyze(windows: windows, displays: [panel])
        #expect(analysis.fullscreen == [panel.displayID])
        #expect(analysis.covered == [panel.displayID])
    }

    @Test func gameAboveTheMenuBarLevelStillPauses() {
        // GLFW puts fullscreen windows at NSMainMenuWindowLevel + 1 (25).
        // Game Mode can miss these games, so the window itself must count.
        let windows = [OnscreenWindow(layer: 25, alpha: 1, bounds: fullPanel, ownerIsRegularApp: true)]
        let analysis = DisplayOcclusion.analyze(windows: windows, displays: [panel])
        #expect(analysis.fullscreen == [panel.displayID])
    }

    @Test func transparentAppWindowIsIgnored() {
        let windows = [OnscreenWindow(layer: 0, alpha: 0, bounds: fullPanel)]
        let analysis = DisplayOcclusion.analyze(windows: windows, displays: [panel])
        #expect(analysis.fullscreen.isEmpty)
        #expect(analysis.covered.isEmpty)
    }

    @Test func maximizedWindowIsNeitherCoveredNorFullscreen() {
        // Menu bar visible: 38pt short of the panel.
        let maximized = CGRect(x: 0, y: 38, width: 1512, height: 944)
        let windows = [OnscreenWindow(layer: 0, alpha: 1, bounds: maximized)]
        let analysis = DisplayOcclusion.analyze(windows: windows, displays: [panel])
        #expect(analysis.fullscreen.isEmpty)
        #expect(analysis.covered.isEmpty)
    }

    @Test func noDisplaysYieldsEmptyAnalysis() {
        let windows = [OnscreenWindow(layer: 0, alpha: 1, bounds: fullPanel)]
        let analysis = DisplayOcclusion.analyze(windows: windows, displays: [])
        #expect(analysis.fullscreen.isEmpty)
        #expect(analysis.coverage.isEmpty)
    }

    @Test func sideBySideWindowsTogetherCoverTheDisplay() {
        // Two tiled halves hide the whole wallpaper. Neither one alone
        // reaches the covered threshold, so per-window coverage kept the
        // hidden wallpaper decoding.
        let left = CGRect(x: 0, y: 0, width: 756, height: 982)
        let right = CGRect(x: 756, y: 0, width: 756, height: 982)
        let windows = [OnscreenWindow(layer: 0, alpha: 1, bounds: left), OnscreenWindow(layer: 0, alpha: 1, bounds: right)]
        let analysis = DisplayOcclusion.analyze(windows: windows, displays: [panel])
        #expect(analysis.covered == [panel.displayID])
        // Fullscreen still means one window owning the display.
        #expect(analysis.fullscreen.isEmpty)
    }

    @Test func overlappingWindowsAreNotDoubleCounted() {
        let a = CGRect(x: 0, y: 0, width: 900, height: 982)
        let b = CGRect(x: 500, y: 0, width: 900, height: 982)
        let windows = [OnscreenWindow(layer: 0, alpha: 1, bounds: a), OnscreenWindow(layer: 0, alpha: 1, bounds: b)]
        let analysis = DisplayOcclusion.analyze(windows: windows, displays: [panel])
        let ratio = analysis.coverage[panel.displayID] ?? 0
        #expect(abs(ratio - 1400.0 / 1512.0) < 0.001)
        #expect(analysis.covered.isEmpty)
    }
}
