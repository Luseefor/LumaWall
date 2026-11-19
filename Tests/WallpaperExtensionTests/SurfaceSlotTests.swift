import XCTest

/// Orderings between acquire, invalidate, renderer creation, and preview
/// leases on one surface (#12 review).
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

    // MARK: Acquire and leases

    func testAcquireReopensAClosedSurface() {
        var slot = SurfaceSlot()
        slot.setOpen(false)
        XCTAssertTrue(slot.acquired(byPreview: false, contextIsPreview: false, by: nil).reopened)
        XCTAssertFalse(slot.acquired(byPreview: false, contextIsPreview: false, by: nil).reopened, "already open")
    }

    func testALiveRequestPromotesAPreviewContextForGood() {
        // A live request reusing a preview's key is handed the preview's
        // context. As a preview it would take a lease that freezes the
        // wallpaper, and hold one frame when no copy fits; it plays as live.
        var slot = SurfaceSlot()
        XCTAssertTrue(slot.playsAsPreview(contextIsPreview: true))
        XCTAssertEqual(slot.acquired(byPreview: true, contextIsPreview: true, by: nil), .init(reopened: false, promoted: false))
        XCTAssertEqual(slot.acquired(byPreview: false, contextIsPreview: true, by: nil), .init(reopened: false, promoted: true))
        XCTAssertFalse(slot.playsAsPreview(contextIsPreview: true))
        XCTAssertEqual(slot.acquired(byPreview: true, contextIsPreview: true, by: nil), .init(reopened: false, promoted: false))
        XCTAssertFalse(slot.playsAsPreview(contextIsPreview: true), "a later preview acquire doesn't demote it")
        XCTAssertEqual(slot.acquired(byPreview: false, contextIsPreview: true, by: nil).promoted, false, "promoted once")
    }

    func testALiveContextIsNeverAPreview() {
        var slot = SurfaceSlot()
        XCTAssertFalse(slot.playsAsPreview(contextIsPreview: false))
        XCTAssertFalse(slot.acquired(byPreview: false, contextIsPreview: false, by: nil).promoted)
        XCTAssertFalse(slot.acquired(byPreview: true, contextIsPreview: false, by: nil).promoted)
    }

    // MARK: Invalidate

    func testInvalidateFromTheLatestAcquirerCloses() {
        var slot = SurfaceSlot(acquiredBy: 1)
        XCTAssertEqual(slot.invalidated(by: 1, openConnections: [1]), .close)
        _ = slot.acquired(byPreview: false, contextIsPreview: false, by: 2)
        XCTAssertEqual(slot.invalidated(by: 2, openConnections: [1, 2]), .close)
    }

    func testReconnectCleanupForASurfaceNotYetReacquiredCloses() {
        // Logged: the old connection drops, the new one invalidates the old
        // surfaces it hasn't reacquired.
        let slot = SurfaceSlot(acquiredBy: 1)
        XCTAssertEqual(slot.invalidated(by: 2, openConnections: [2]), .close)
    }

    func testInvalidateFromAnOlderConnectionAfterAReacquireKeepsTheGrace() {
        // The surface was reacquired on another open connection before this
        // invalidate, which may belong to the earlier acquisition. Before
        // #12 it played through the grace; it still does.
        var slot = SurfaceSlot(acquiredBy: 1)
        _ = slot.acquired(byPreview: false, contextIsPreview: false, by: 2)
        XCTAssertEqual(slot.invalidated(by: 1, openConnections: [1, 2]), .graceOnly)
    }

    func testInvalidateWithNoKnownAcquirerCloses() {
        XCTAssertEqual(SurfaceSlot().invalidated(by: 3, openConnections: [3]), .close)
    }

    func testRenewalSupersedesTheEarlierTimer() {
        var book = LeaseBook<String>()
        let first = book.renew("p")
        let second = book.renew("p")
        XCTAssertFalse(book.expire("p", lease: first), "renewed before it ran out")
        XCTAssertTrue(book.expire("p", lease: second))
        XCTAssertFalse(book.expire("p", lease: second), "expires once")
    }

    func testReacquireAfterExpiryStartsANewLease() {
        var book = LeaseBook<String>()
        let first = book.renew("p")
        XCTAssertTrue(book.expire("p", lease: first))
        let second = book.renew("p")
        XCTAssertFalse(book.expire("p", lease: first))
        XCTAssertTrue(book.expire("p", lease: second))
    }

    func testInvalidateOrRemovalEndsTheLease() {
        var book = LeaseBook<String>()
        let lease = book.renew("p")
        let other = book.renew("q")
        book.end("p")
        XCTAssertFalse(book.expire("p", lease: lease))
        XCTAssertTrue(book.expire("q", lease: other), "other surfaces keep theirs")
    }
}
