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
}
