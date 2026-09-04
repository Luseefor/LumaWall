import CoreGraphics
import LumaWallCore
import Testing

struct SpanningGeometryTests {
    @Test func buildsCanvasAcrossNegativeAndPositiveCoordinates() {
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let main = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let canvas = SpanningGeometry.canvas(for: [left, main])
        #expect(canvas == CGRect(x: -1920, y: 0, width: 4480, height: 1440))
    }

    @Test func positionsSharedCanvasRelativeToEachDisplay() throws {
        let canvas = CGRect(x: -1920, y: 0, width: 4480, height: 1440)
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let main = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        #expect(SpanningGeometry.mediaFrame(canvas: canvas, on: left).origin == .zero)
        #expect(SpanningGeometry.mediaFrame(canvas: canvas, on: main).origin == CGPoint(x: -1920, y: 0))
    }

    @Test func emptyDisplayListHasNoCanvas() {
        #expect(SpanningGeometry.canvas(for: []) == nil)
    }

    @Test func singleDisplayCanvasEqualsItsFrame() {
        // No spanning offset on one display: media fills the frame exactly
        // (guards the "half out of screen" regression for single-monitor).
        let frame = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        #expect(SpanningGeometry.canvas(for: [frame]) == frame)
        #expect(SpanningGeometry.mediaFrame(canvas: frame, on: frame) == CGRect(origin: .zero, size: frame.size))
    }

    @Test func stackedDisplaysSplitCanvasVertically() {
        // Second display above the first: each media frame is the full canvas
        // shifted by the display origin, so each screen shows its own half.
        let bottom = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let top = CGRect(x: 0, y: 1080, width: 1920, height: 1080)
        let canvas = SpanningGeometry.canvas(for: [bottom, top])
        #expect(canvas == CGRect(x: 0, y: 0, width: 1920, height: 2160))
        #expect(SpanningGeometry.mediaFrame(canvas: canvas!, on: bottom)
            == CGRect(x: 0, y: 0, width: 1920, height: 2160))
        #expect(SpanningGeometry.mediaFrame(canvas: canvas!, on: top)
            == CGRect(x: 0, y: -1080, width: 1920, height: 2160))
    }
}
