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

    /// A source and the copies the app plans for it, with the one Reduced
    /// plays once they all exist. A source with no 1080p copy plays the
    /// 720p one in Reduced.
    struct ReducedRow {
        let source: CGSize
        let fps: Double
        let planned: Set<String>
        let reducedPlays: String?
    }

    private static let reducedName = "Wallpaper.reduced.mov"
    private static let minimalName = "Wallpaper.minimal.mov"
    private static let qhdName = "Wallpaper.qhd.mov"

    static let reducedRows: [ReducedRow] = [
        ReducedRow(source: uhd, fps: 60, planned: [reducedName, minimalName, qhdName], reducedPlays: reducedName),
        ReducedRow(source: uhd, fps: 30, planned: [reducedName, minimalName, qhdName], reducedPlays: reducedName),
        ReducedRow(source: CGSize(width: 2560, height: 1440), fps: 60, planned: [reducedName, minimalName], reducedPlays: reducedName),
        // No 1080p copy is planned at or below 1920 px.
        ReducedRow(source: CGSize(width: 1920, height: 1080), fps: 60, planned: [minimalName], reducedPlays: minimalName),
        ReducedRow(source: CGSize(width: 1600, height: 900), fps: 60, planned: [minimalName], reducedPlays: minimalName),
        ReducedRow(source: CGSize(width: 1600, height: 900), fps: 30, planned: [minimalName], reducedPlays: minimalName),
        ReducedRow(source: CGSize(width: 1280, height: 720), fps: 60, planned: [], reducedPlays: nil),
    ]
}
