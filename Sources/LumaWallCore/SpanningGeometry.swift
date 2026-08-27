import CoreGraphics

public enum SpanningGeometry {
    public static func canvas(for displayFrames: [CGRect]) -> CGRect? {
        guard !displayFrames.isEmpty else { return nil }
        let canvas = displayFrames.reduce(CGRect.null) { $0.union($1) }
        guard !canvas.isNull, canvas.width > 0, canvas.height > 0 else { return nil }
        return canvas
    }

    public static func mediaFrame(canvas: CGRect, on displayFrame: CGRect) -> CGRect {
        CGRect(
            x: canvas.minX - displayFrame.minX,
            y: canvas.minY - displayFrame.minY,
            width: canvas.width,
            height: canvas.height
        )
    }
}
