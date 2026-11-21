import LumaWallCore
import SwiftUI
import XCTest

@testable import LumaWall

@MainActor
final class PlaybackStatusViewTests: XCTestCase {
    private let statuses: [DisplayPlaybackStatus] = [
        DisplayPlaybackStatus(displayID: 1, state: .playing, copy: .full, frameRate: 60),
        DisplayPlaybackStatus(displayID: 1, state: .playing, reason: .batteryTier, copy: .p1080, frameRate: 30),
        DisplayPlaybackStatus(displayID: 1, state: .paused, reason: .covered, copy: .full, frameRate: 60),
        DisplayPlaybackStatus(displayID: 1, state: .paused, reason: .userPause, engine: .overlay),
    ]

    private var sheet: some View {
        let statuses = self.statuses
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(statuses.enumerated()), id: \.offset) { PlaybackStatusLine(status: $0.element, displayName: "Studio Display") }
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
        .background(Color(white: 0.12))
        .environment(\.colorScheme, .dark)
    }

    /// Renders offscreen; set LUMAWALL_RENDER_DIR to keep the PNG.
    func testStatusLinesRenderOffscreen() throws {
        let renderer = ImageRenderer(content: sheet)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        XCTAssertGreaterThan(image.size.height, 40)
        if let dir = ProcessInfo.processInfo.environment["LUMAWALL_RENDER_DIR"],
            let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:])
        {
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("playback-status.png"))
        }
    }
}
