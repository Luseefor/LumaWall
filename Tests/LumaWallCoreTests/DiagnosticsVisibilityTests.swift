import Foundation
import LumaWallCore
import Testing

struct DiagnosticsVisibilityTests {
    @Test func reportsOnlyWhenAnyViewerStartsOrStops() {
        var visibility = DiagnosticsVisibility()
        let settings = UUID()
        let popover = UUID()
        #expect(!visibility.isVisible)
        #expect(visibility.set(settings, visible: true) == .becameVisible)
        #expect(visibility.set(popover, visible: true) == nil)
        #expect(visibility.set(settings, visible: false) == nil)
        #expect(visibility.isVisible)
        #expect(visibility.set(popover, visible: false) == .becameHidden)
        #expect(!visibility.isVisible)
    }

    @Test func repeatedReportsDoNotDriftTheState() {
        var visibility = DiagnosticsVisibility()
        let viewer = UUID()
        visibility.set(viewer, visible: true)
        #expect(visibility.set(viewer, visible: true) == nil)
        #expect(visibility.set(viewer, visible: false) == .becameHidden)
        #expect(visibility.set(viewer, visible: false) == nil)
        #expect(!visibility.isVisible)
    }
}
