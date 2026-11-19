import XCTest

/// Orderings between acquire, invalidate, and renderer creation on one
/// surface (#12 review).
final class SurfaceSlotTests: XCTestCase {

    // MARK: Renderer creation

    func testCreateFinishingAfterCloseAndReopenInstallsOpen() {
        var slot = SurfaceSlot()
        XCTAssertTrue(slot.claimCreate(token: 1))
        slot.setOpen(false)
        slot.setOpen(true)
        XCTAssertEqual(slot.finishCreate(token: 1), .install(closed: false))
    }

    func testCreateFinishingWhileClosedInstallsClosed() {
        // The invalidate landed while the renderer loaded; it must start closed.
        var slot = SurfaceSlot()
        XCTAssertTrue(slot.claimCreate(token: 1))
        slot.setOpen(false)
        XCTAssertEqual(slot.finishCreate(token: 1), .install(closed: true))
    }

    func testCreateForATornDownContextIsStale() {
        // Teardown removed the context while its renderer loaded and a later
        // acquire recreated the key: the old renderer's layers belong to the
        // old root, so it must not land in the new slot.
        var recreated = SurfaceSlot()
        XCTAssertEqual(recreated.finishCreate(token: 1), .stale)
        XCTAssertTrue(recreated.claimCreate(token: 2))
        XCTAssertEqual(recreated.finishCreate(token: 1), .stale)
        XCTAssertEqual(recreated.finishCreate(token: 2), .install(closed: false))
    }

    func testOneCreateAtATime() {
        var slot = SurfaceSlot()
        XCTAssertTrue(slot.claimCreate(token: 1))
        XCTAssertFalse(slot.claimCreate(token: 2))
        slot.failCreate(token: 2)
        XCTAssertFalse(slot.claimCreate(token: 3), "another create's failure doesn't release the claim")
        slot.failCreate(token: 1)
        XCTAssertTrue(slot.claimCreate(token: 3))
        XCTAssertEqual(slot.finishCreate(token: 3), .install(closed: false))
        XCTAssertFalse(slot.claimCreate(token: 4), "the slot has its renderer")
    }

    // MARK: Acquire

    func testAcquireReopensAClosedSurface() {
        var slot = SurfaceSlot()
        slot.setOpen(false)
        XCTAssertTrue(slot.acquired(by: nil, replyOnly: false))
        XCTAssertFalse(slot.acquired(by: nil, replyOnly: false), "already open")
    }

    // MARK: Invalidate

    func testInvalidateFromTheLatestAcquirerCloses() {
        var slot = SurfaceSlot(acquiredBy: 1)
        XCTAssertEqual(slot.invalidated(by: 1, openConnections: [1]), .close)
        _ = slot.acquired(by: 2, replyOnly: false)
        XCTAssertEqual(slot.invalidated(by: 2, openConnections: [1, 2]), .close)
    }

    func testReconnectCleanupForASurfaceNotYetReacquiredCloses() {
        // Logged: the old connection drops, the new one invalidates the old
        // surfaces it hasn't reacquired.
        var slot = SurfaceSlot(acquiredBy: 1)
        XCTAssertEqual(slot.invalidated(by: 2, openConnections: [2]), .close)
    }

    func testInvalidateFromAnOlderConnectionAfterAReacquireKeepsTheGrace() {
        // The surface was reacquired on another open connection before this
        // invalidate, which may belong to the earlier acquisition. Before
        // #12 it played through the grace; it still does.
        var slot = SurfaceSlot(acquiredBy: 1)
        _ = slot.acquired(by: 2, replyOnly: false)
        XCTAssertEqual(slot.invalidated(by: 1, openConnections: [1, 2]), .graceOnly)
    }

    func testAPickerSharingTheLiveSurfaceIsNotItsAcquirer() {
        // The Settings picker is handed the live surface's context without
        // changing it. Its dismissal used to make it the last acquirer, so
        // its invalidate froze the live wallpaper at once.
        var slot = SurfaceSlot(acquiredBy: 1)
        XCTAssertFalse(slot.acquired(by: 2, replyOnly: true), "already open")
        XCTAssertEqual(slot.lastAcquirer, 1)
        XCTAssertEqual(slot.invalidated(by: 2, openConnections: [1, 2]), .graceOnly)
        XCTAssertEqual(slot.invalidated(by: 1, openConnections: [1, 2]), .close)
    }

    func testAPickerOnTheLiveConnectionMakesTheNextInvalidateAmbiguous() {
        // Same connection: the next invalidate may be the picker's or the
        // wallpaper's, so it keeps the grace; the one after it closes.
        var slot = SurfaceSlot(acquiredBy: 1)
        _ = slot.acquired(by: 1, replyOnly: true)
        XCTAssertEqual(slot.invalidated(by: 1, openConnections: [1]), .graceOnly)
        XCTAssertEqual(slot.invalidated(by: 1, openConnections: [1]), .close)
    }

    func testAReplyOnlyReuseReopensForItsHost() {
        var slot = SurfaceSlot(acquiredBy: 1)
        slot.setOpen(false)
        XCTAssertTrue(slot.acquired(by: 2, replyOnly: true))
        XCTAssertEqual(slot.lastAcquirer, 1)
    }

    func testOnlyAClosingInvalidateRetiresTheWallpaperID() {
        // A grace-only invalidate used to drop the id, so the owner's own
        // invalidate during the grace resolved nothing and the surface
        // decoded until teardown.
        var slot = SurfaceSlot(acquiredBy: 1)
        _ = slot.acquired(by: 2, replyOnly: true)
        let ambiguous = slot.invalidated(by: 2, openConnections: [1, 2])
        XCTAssertFalse(ambiguous.retiresWallpaperID)
        let owners = slot.invalidated(by: 1, openConnections: [1, 2])
        XCTAssertEqual(owners, .close)
        XCTAssertTrue(owners.retiresWallpaperID)
    }

    func testInvalidateWithNoKnownAcquirerCloses() {
        var slot = SurfaceSlot()
        XCTAssertEqual(slot.invalidated(by: 3, openConnections: [3]), .close)
    }
}
