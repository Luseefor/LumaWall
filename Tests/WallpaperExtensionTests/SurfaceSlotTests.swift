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

    // MARK: Acquire replies

    func testAReuseWhileTheCreateSeedsWaitsForIt() {
        // A preview sharing the desktop's key, or a same-role reuse after
        // the renderer is installed but before the gradient is flushed: both
        // reply only once the create's layer can show something.
        var gate = ReplyGate<String, String>()
        XCTAssertEqual(gate.open("desktop", token: 1, reply: "create"), [])
        XCTAssertTrue(gate.hold("preview", for: "desktop"))
        XCTAssertTrue(gate.hold("reuse", for: "desktop"))
        XCTAssertEqual(gate.ready("desktop", token: 1), ["create", "preview", "reuse"])
        XCTAssertFalse(gate.hold("later", for: "desktop"), "a ready surface replies at once")
        XCTAssertEqual(gate.ready("desktop", token: 1), [], "each reply goes out once")
    }

    func testAReuseOfASurfaceWithNoCreateRepliesAtOnce() {
        var gate = ReplyGate<String, String>()
        XCTAssertFalse(gate.hold("reuse", for: "desktop"))
        _ = gate.open("other", token: 1, reply: "create")
        XCTAssertFalse(gate.hold("reuse", for: "desktop"), "another surface's create doesn't hold this one")
    }

    func testAStaleCreateDoesntReleaseItsReplacementsReplies() {
        // Teardown removed context A; B is creating under the same key when
        // A's create finishes. B's replies wait for B's seed.
        var gate = ReplyGate<String, String>()
        _ = gate.open("desktop", token: 1, reply: "A")
        XCTAssertTrue(gate.hold("reuse A", for: "desktop"))
        XCTAssertEqual(gate.close("desktop"), ["A", "reuse A"], "teardown answers A's replies")
        XCTAssertEqual(gate.open("desktop", token: 2, reply: "B"), [])
        XCTAssertTrue(gate.hold("reuse B", for: "desktop"))
        XCTAssertEqual(gate.ready("desktop", token: 1), [])
        XCTAssertTrue(gate.hold("reuse B later", for: "desktop"), "B is still seeding")
        XCTAssertEqual(gate.ready("desktop", token: 2), ["B", "reuse B", "reuse B later"])
    }

    func testACreateOverAnUnclosedOneHandsBackItsReplies() {
        // The context went away without passing through teardown: the new
        // create takes the key, and the old replies are answered (as failed,
        // their context is gone) rather than left hanging.
        var gate = ReplyGate<String, String>()
        _ = gate.open("desktop", token: 1, reply: "A")
        XCTAssertTrue(gate.hold("reuse A", for: "desktop"))
        XCTAssertEqual(gate.open("desktop", token: 2, reply: "B"), ["A", "reuse A"])
        XCTAssertEqual(gate.ready("desktop", token: 1), [])
        XCTAssertEqual(gate.ready("desktop", token: 2), ["B"])
    }

    func testTeardownAfterTheSeedHasNothingToAnswer() {
        var gate = ReplyGate<String, String>()
        _ = gate.open("desktop", token: 1, reply: "create")
        XCTAssertEqual(gate.ready("desktop", token: 1), ["create"])
        XCTAssertEqual(gate.close("desktop"), [])
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

    // MARK: Grace end

    func testPickerDismissalLeavesTheLiveContextPastTheGrace() {
        // The picker's invalidate armed the 15 s teardown, which destroyed
        // the CAContext the desktop still hosted.
        var slot = SurfaceSlot(acquiredBy: 1)
        _ = slot.acquired(by: 2, replyOnly: true)
        XCTAssertEqual(slot.invalidated(by: 2, openConnections: [1, 2]), .graceOnly)
        XCTAssertFalse(slot.tearsDownAtGraceEnd, "the desktop still hosts it")
        XCTAssertEqual(slot.invalidated(by: 1, openConnections: [1, 2]), .close)
        XCTAssertTrue(slot.tearsDownAtGraceEnd)
    }

    func testPickerDismissalOnTheLiveConnectionLeavesTheLiveContext() {
        var slot = SurfaceSlot(acquiredBy: 1)
        _ = slot.acquired(by: 1, replyOnly: true)
        _ = slot.invalidated(by: 1, openConnections: [1])
        XCTAssertFalse(slot.tearsDownAtGraceEnd)
    }

    func testAStaleInvalidateLeavesTheReacquiredContext() {
        var slot = SurfaceSlot(acquiredBy: 1)
        _ = slot.acquired(by: 2, replyOnly: false)
        _ = slot.invalidated(by: 1, openConnections: [1, 2])
        XCTAssertFalse(slot.tearsDownAtGraceEnd, "connection 2 hosts it")
    }

    func testTheOwnersInvalidateKeepsPlayingForAPickerStillSharing() {
        // The owner leaves first; the picker on connection 2 still hosts the
        // context, and its own invalidate then closes it.
        var slot = SurfaceSlot(acquiredBy: 1)
        _ = slot.acquired(by: 2, replyOnly: true)
        XCTAssertEqual(slot.invalidated(by: 1, openConnections: [1, 2]), .graceOnly)
        XCTAssertFalse(slot.tearsDownAtGraceEnd)
        XCTAssertEqual(slot.invalidated(by: 2, openConnections: [1, 2]), .close)
        XCTAssertTrue(slot.tearsDownAtGraceEnd)
    }

    func testPickerDismissalLeavesTheDesktopHostingAPickerMadeContext() {
        // The picker created the context, then the desktop was handed it on
        // another connection. The picker's dismissal closed it at once and
        // teardown destroyed what the desktop hosted.
        var slot = SurfaceSlot(acquiredBy: 1, ownerIsPreview: true)
        _ = slot.acquired(by: 2, replyOnly: true)
        XCTAssertEqual(slot.invalidated(by: 1, openConnections: [1, 2]), .graceOnly)
        XCTAssertTrue(slot.open)
        XCTAssertFalse(slot.tearsDownAtGraceEnd)
    }

    func testAPickerJoiningDuringTheOwnersGraceClosesWhenItLeaves() {
        // The desktop left, the picker reopened the surface during the
        // grace and cancelled teardown. With the picker gone too nobody
        // hosts it, so it must close rather than decode on.
        var slot = SurfaceSlot(acquiredBy: 1)
        XCTAssertEqual(slot.invalidated(by: 1, openConnections: [1, 2]), .close)
        XCTAssertTrue(slot.acquired(by: 2, replyOnly: true), "reopened for the picker")
        XCTAssertEqual(slot.invalidated(by: 2, openConnections: [1, 2]), .close)
        XCTAssertTrue(slot.tearsDownAtGraceEnd)
    }

    func testASharerWhoseConnectionDroppedDoesNotKeepTheSurface() {
        var slot = SurfaceSlot(acquiredBy: 1)
        _ = slot.acquired(by: 2, replyOnly: true)
        XCTAssertEqual(slot.invalidated(by: 1, openConnections: [1]), .close)
    }

    func testPickerDismissalDuringTheDesktopsReconnectLeavesItPlaying() {
        // The agent can keep its desktop host across a reconnect. The
        // picker's invalidate between the drop and the reacquire took the
        // desktop for gone and stopped what it still showed.
        var slot = SurfaceSlot(acquiredBy: 1)
        _ = slot.acquired(by: 2, replyOnly: true)
        XCTAssertEqual(slot.invalidated(by: 2, openConnections: [2]), .graceOnly)
        XCTAssertTrue(slot.open)
        XCTAssertEqual(slot.invalidated(by: 3, openConnections: [2, 3]), .close, "the reconnect cleanup still closes it")
    }

    func testASharerQuittingAfterTheOwnerLeftClosesTheSurface() {
        // The desktop left while the picker shared; Settings then quit
        // without an invalidate, so nothing closed the surface.
        var slot = SurfaceSlot(acquiredBy: 1)
        _ = slot.acquired(by: 2, replyOnly: true)
        XCTAssertEqual(slot.invalidated(by: 1, openConnections: [1, 2]), .graceOnly)
        XCTAssertFalse(slot.connectionsChanged(openConnections: [1, 2]))
        XCTAssertTrue(slot.connectionsChanged(openConnections: [1]))
        XCTAssertTrue(slot.tearsDownAtGraceEnd)
        XCTAssertFalse(slot.connectionsChanged(openConnections: [1]), "closed once")
    }

    func testAConnectionDropAloneDoesNotCloseTheOwnersSurface() {
        var slot = SurfaceSlot(acquiredBy: 1)
        _ = slot.acquired(by: 2, replyOnly: true)
        XCTAssertFalse(slot.connectionsChanged(openConnections: [2]))
        XCTAssertFalse(slot.connectionsChanged(openConnections: []))
        XCTAssertTrue(slot.open, "the reconnect cleanup or a reacquire decides")
    }

    func testPickerDismissalWhileTheDesktopReconnectsKeepsAPickerMadeContext() {
        // The picker made the context on 1 and the desktop shares it on 2.
        // 2 drops while the desktop keeps showing the context; the picker's
        // dismissal then took the desktop for gone and tore it down.
        var slot = SurfaceSlot(acquiredBy: 1, ownerIsPreview: true)
        _ = slot.acquired(by: 2, replyOnly: true)
        XCTAssertFalse(slot.connectionsChanged(openConnections: [1]))
        XCTAssertEqual(slot.invalidated(by: 1, openConnections: [1]), .graceOnly)
        XCTAssertTrue(slot.open)
        XCTAssertFalse(slot.tearsDownAtGraceEnd)
        // The desktop reacquires on 3, replacing its old connection, then leaves.
        _ = slot.acquired(by: 3, replyOnly: true)
        XCTAssertEqual(slot.invalidated(by: 3, openConnections: [1, 3]), .close)
    }

    func testTheAgentsCleanupReleasesADesktopThatDidNotReconnect() {
        // Same as above, but the agent's new connection invalidates the
        // surface instead of reacquiring it: the desktop is gone.
        var slot = SurfaceSlot(acquiredBy: 1, ownerIsPreview: true)
        _ = slot.acquired(by: 2, replyOnly: true)
        XCTAssertEqual(slot.invalidated(by: 1, openConnections: [1]), .graceOnly)
        XCTAssertEqual(slot.invalidated(by: 3, openConnections: [1, 3]), .close)
    }

    func testAPickerThatQuitsWithoutAnInvalidateClosesItsContext() {
        // The picker made a decoding context and Settings quit without an
        // invalidate: nothing closed it, and it decoded forever.
        var slot = SurfaceSlot(acquiredBy: 1, ownerIsPreview: true)
        XCTAssertTrue(slot.connectionsChanged(openConnections: []))
        XCTAssertTrue(slot.tearsDownAtGraceEnd)
    }

    func testAPickerThatQuitsLeavesItsContextToADesktopSharingIt() {
        var slot = SurfaceSlot(acquiredBy: 1, ownerIsPreview: true)
        _ = slot.acquired(by: 2, replyOnly: true)
        XCTAssertFalse(slot.connectionsChanged(openConnections: [2]))
        XCTAssertTrue(slot.open)
        XCTAssertEqual(slot.invalidated(by: 2, openConnections: [2]), .close)
    }

    func testAReopenedSurfaceIsNotTornDown() {
        var slot = SurfaceSlot(acquiredBy: 1)
        XCTAssertEqual(slot.invalidated(by: 1, openConnections: [1]), .close)
        _ = slot.acquired(by: 1, replyOnly: false)
        XCTAssertFalse(slot.tearsDownAtGraceEnd)
    }

    // MARK: Preview rules

    func testAPickerSharingTheLiveSurfaceLeavesItLive() {
        // #35: the picker handed the live context must not change its
        // playback or lifetime; dismissing it leaves the wallpaper playing.
        var slot = SurfaceSlot(acquiredBy: 1)
        _ = slot.acquired(by: 2, replyOnly: true)
        XCTAssertFalse(slot.holdsPreviewFrame(contextIsPreview: false))
        XCTAssertEqual(slot.invalidated(by: 2, openConnections: [1, 2]), .graceOnly)
        XCTAssertTrue(slot.open, "still playing")
        XCTAssertFalse(slot.tearsDownAtGraceEnd)
        XCTAssertFalse(slot.holdsPreviewFrame(contextIsPreview: false))
    }

    func testALiveRequestHandedAPreviewContextStopsTheFrameHold() {
        // A preview's renderer holds one frame when no copy fits. A live
        // host handed that context must not see the hold, now or later.
        var slot = SurfaceSlot(acquiredBy: 1)
        XCTAssertTrue(slot.holdsPreviewFrame(contextIsPreview: true))
        _ = slot.acquired(by: 1, replyOnly: false)
        XCTAssertTrue(slot.holdsPreviewFrame(contextIsPreview: true), "another preview acquire")
        _ = slot.acquired(by: 2, replyOnly: true)
        XCTAssertFalse(slot.holdsPreviewFrame(contextIsPreview: true))
        _ = slot.invalidated(by: 2, openConnections: [1, 2])
        _ = slot.acquired(by: 1, replyOnly: false)
        XCTAssertFalse(slot.holdsPreviewFrame(contextIsPreview: true), "for good")
    }

    func testInvalidateWithNoKnownAcquirerCloses() {
        var slot = SurfaceSlot()
        XCTAssertEqual(slot.invalidated(by: 3, openConnections: [3]), .close)
    }
}
