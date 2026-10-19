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

    @Test func cocoaWindowMirrorsAroundPrimaryTop() {
        // Primary 1920x1080 with a taller 2560x1440 sidecar, bottoms aligned:
        // the sidecar extends 360pt above the primary, so the union's maxY
        // (1440) is NOT the mirror line — the primary height (1080) is.
        // A primary-fullscreen window in Quartz coords (y-down from primary
        // top) must map back onto the primary Cocoa frame exactly.
        let primary = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let quartzFullscreen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let mapped = ScreenGeometry.cocoaWindow(fromQuartz: quartzFullscreen, primaryHeight: primary.height)
        #expect(abs(mapped.minX - primary.minX) < 0.001)
        #expect(abs(mapped.minY - primary.minY) < 0.001)
        #expect(abs(mapped.width - primary.width) < 0.001)
        #expect(abs(mapped.height - primary.height) < 0.001)
        // The old union-mirrored conversion shifts it by the 360pt overhang.
        let union = CGRect(x: 0, y: 0, width: 4480, height: 1440)
        let shifted = ScreenGeometry.cocoa(fromQuartz: quartzFullscreen, desktop: union)
        #expect(abs(shifted.minY - primary.minY) > 100)
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
