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
}
