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
}
