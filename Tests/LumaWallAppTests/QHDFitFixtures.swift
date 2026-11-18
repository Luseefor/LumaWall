import CoreGraphics

/// Compiled into both test bundles (see project.yml). The app's planning
/// test checks it plans the 1440p copy for exactly these rows, and the
/// extension's selection test checks Full Quality plays it for the same
/// rows, so the two sides can't drift apart.
enum QHDFitFixtures {
    struct Row {
        let source: CGSize
        let fps: Double
        let display: CGSize
        let playsQHD: Bool
        /// Copy sizes the app encodes for this source: 1080p, 720p, 1440p.
        let reduced: CGSize
        let minimal: CGSize
        let qhd: CGSize
    }

    private static let uhd = CGSize(width: 3840, height: 2160)
    private static let wide = CGSize(width: 4096, height: 1716)
    private static func row(_ source: CGSize, _ fps: Double, _ display: CGSize, _ playsQHD: Bool) -> Row {
        let isWide = source == wide
        return Row(
            source: source, fps: fps, display: display, playsQHD: playsQHD,
            reduced: isWide ? CGSize(width: 1920, height: 804) : CGSize(width: 1920, height: 1080),
            minimal: isWide ? CGSize(width: 1280, height: 536) : CGSize(width: 1280, height: 720),
            qhd: isWide ? CGSize(width: 2560, height: 1072) : CGSize(width: 2560, height: 1440)
        )
    }

    static let rows: [Row] = [
        row(uhd, 60, CGSize(width: 3840, height: 2160), false),
        row(uhd, 60, CGSize(width: 2560, height: 1440), true),
        row(uhd, 60, CGSize(width: 1920, height: 1080), true),
        // At 30 fps the 1080p battery copy keeps the source rate and wins.
        row(uhd, 30, CGSize(width: 1920, height: 1080), false),
        row(uhd, 30, CGSize(width: 2560, height: 1440), true),
        // A 2.39:1 source's 1440p copy is 2560x1072, too short to fill.
        row(wide, 60, CGSize(width: 2560, height: 1440), false),
        row(uhd, 60, CGSize(width: 1440, height: 2560), false),
    ]
}
