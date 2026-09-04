import CoreGraphics
import LumaWallCore
import Testing

struct ScreenGeometryTests {
    @Test func quartzAndCocoaRoundTrip() {
        let desktop = CGRect(x: -1920, y: 0, width: 3840, height: 1080)
        let cocoa = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let quartz = ScreenGeometry.quartz(fromCocoa: cocoa, desktop: desktop)
        let back = ScreenGeometry.cocoa(fromQuartz: quartz, desktop: desktop)
        #expect(back.origin.x == cocoa.origin.x)
        #expect(abs(back.origin.y - cocoa.origin.y) < 0.001)
        #expect(back.size == cocoa.size)
    }

    @Test func fullscreenWindowCoversScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        #expect(ScreenGeometry.isCovered(screen: screen, windows: [screen]))
        #expect(!ScreenGeometry.isCovered(screen: screen, windows: [CGRect(x: 40, y: 40, width: 800, height: 600)]))
    }

    @Test func zeroAreaScreenIsNeverCovered() {
        let empty = CGRect(x: 0, y: 0, width: 0, height: 0)
        #expect(!ScreenGeometry.isCovered(screen: empty, windows: [CGRect(x: -100, y: -100, width: 1000, height: 1000)]))
        #expect(ScreenGeometry.coverageRatio(screen: empty, windows: []) == 0)
    }

    @Test func emptyWindowListCoversNothing() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        #expect(!ScreenGeometry.isCovered(screen: screen, windows: []))
        #expect(ScreenGeometry.coverageRatio(screen: screen, windows: []) == 0)
    }

    @Test func occlusionBoundaryMatchesPausePolicy() {
        // Maximized window with menu bar visible (~96.5%): must NOT count, or
        // normal use flaps pause/resume. Genuinely fullscreen (~99.9%): must.
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let maximized = CGRect(x: 0, y: 0, width: 1920, height: 1042)
        let fullscreen = CGRect(x: 0, y: 0, width: 1920, height: 1078)
        let threshold = PlaybackPolicyThresholds.occlusionCovered
        #expect(!ScreenGeometry.isCovered(screen: screen, windows: [maximized], threshold: threshold))
        #expect(ScreenGeometry.isCovered(screen: screen, windows: [fullscreen], threshold: threshold))
        #expect(ScreenGeometry.isCovered(screen: screen, windows: [screen], threshold: threshold))
    }

    @Test func coverageUsesBestWindowNotSum() {
        // Two half-screen windows must not add up to "covered".
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let left = CGRect(x: 0, y: 0, width: 960, height: 1080)
        let right = CGRect(x: 960, y: 0, width: 960, height: 1080)
        #expect(!ScreenGeometry.isCovered(
            screen: screen, windows: [left, right],
            threshold: PlaybackPolicyThresholds.occlusionCovered
        ))
    }
}
