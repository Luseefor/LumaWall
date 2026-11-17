import AppKit
import XCTest
@testable import LumaWall

@MainActor
final class LoopingVideoViewTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/dev/null")

    func testPreviewStaysPausedUntilVisible() {
        let coordinator = LoopingVideoView.Coordinator(url: url)
        XCTAssertEqual(coordinator.player.rate, 0)
        coordinator.setVisible(true)
        XCTAssertEqual(coordinator.player.rate, 1)
    }

    func testHiddenPreviewPauses() {
        // A library window behind a browser kept decoding every preview.
        let coordinator = LoopingVideoView.Coordinator(url: url)
        coordinator.setVisible(true)
        coordinator.setVisible(false)
        XCTAssertEqual(coordinator.player.rate, 0)
    }

    func testReconfigureKeepsHiddenPreviewPaused() {
        let coordinator = LoopingVideoView.Coordinator(url: url)
        coordinator.reconfigure(url: URL(fileURLWithPath: "/dev/zero"))
        XCTAssertEqual(coordinator.player.rate, 0)
    }

    func testSurfaceWithoutWindowReportsHidden() {
        let surface = PlayerSurface()
        var reported: [Bool] = []
        surface.onVisibilityChange = { reported.append($0) }
        surface.viewDidMoveToWindow()
        XCTAssertEqual(reported, [false])
    }

    func testSurfaceLeavingItsWindowReportsHidden() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120), styleMask: [.borderless], backing: .buffered, defer: true)
        let surface = PlayerSurface()
        var reported: [Bool] = []
        surface.onVisibilityChange = { reported.append($0) }
        window.contentView?.addSubview(surface)
        surface.removeFromSuperview()
        XCTAssertEqual(reported.count, 2)
        XCTAssertEqual(reported.last, false)
    }
}
