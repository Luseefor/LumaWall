import Foundation

/// Bookkeeping for one surface's context beside its `CAContext` and
/// renderer: whether playback is open, which renderer create owns the slot,
/// and which connection acquired it last. Pure so the acquire, invalidate,
/// and create orderings run as tests; `WallpaperState` keeps one per context
/// and acts on its answers under its lock.
struct SurfaceSlot: Equatable {
    /// False from an invalidate until the next acquire.
    private(set) var open = true
    /// The connection that made the latest acquire, when known.
    private(set) var lastAcquirer: Int?
    /// A request of the other role was handed this context without changing
    /// it (the Settings picker reusing the live surface's id). The next
    /// invalidate may be that host's, so it is ambiguous.
    private(set) var sharedWithOtherRole = false
    /// The token of the renderer create in flight.
    private(set) var pendingCreate: Int?
    private(set) var hasRenderer = false

    init(acquiredBy connection: Int? = nil) {
        lastAcquirer = connection
    }

    enum Finish: Equatable {
        /// Install the renderer; tell it to close first when `closed`.
        case install(closed: Bool)
        /// This slot didn't start the create (its context was torn down and
        /// the key recreated): stop the renderer and leave the slot alone.
        case stale
    }

    /// Returns whether it changed.
    @discardableResult
    mutating func setOpen(_ open: Bool) -> Bool {
        guard self.open != open else { return false }
        self.open = open
        return true
    }

    /// An acquire from `connection` reached this context. Returns whether it
    /// reopened. A `replyOnly` reuse (the other role, handed the context
    /// unchanged) reopens playback for its host but is not an acquisition:
    /// its invalidate must not freeze the surface's real owner.
    mutating func acquired(by connection: Int?, replyOnly: Bool) -> Bool {
        if replyOnly {
            sharedWithOtherRole = true
        } else if let connection {
            lastAcquirer = connection
        }
        return setOpen(true)
    }

    enum InvalidateAction: Equatable {
        /// The invalidate belongs to the latest acquisition: stop playback now.
        case close
        /// It may belong to an earlier acquisition that another, still open
        /// connection has since replaced: keep playing through the grace.
        case graceOnly

        /// Whether the invalidate retires the surface's WallpaperID. A
        /// grace-only one keeps it, so the owner's own invalidate during the
        /// grace still finds the surface; teardown retires it otherwise.
        var retiresWallpaperID: Bool { self == .close }
    }

    /// The protocol names only the surface, so the connection decides. An
    /// invalidate from the latest acquirer, or after the latest acquirer's
    /// connection dropped (the agent cleaning up on a new connection), is
    /// unambiguous, unless another role's host shares the surface: then this
    /// invalidate may be that host's and takes the grace.
    mutating func invalidated(by connection: Int, openConnections: Set<Int>) -> InvalidateAction {
        if sharedWithOtherRole {
            sharedWithOtherRole = false
            return .graceOnly
        }
        guard let lastAcquirer, lastAcquirer != connection, openConnections.contains(lastAcquirer) else { return .close }
        return .graceOnly
    }

    /// Claim the slot's one renderer create for `token`.
    mutating func claimCreate(token: Int) -> Bool {
        guard !hasRenderer, pendingCreate == nil else { return false }
        pendingCreate = token
        return true
    }

    mutating func finishCreate(token: Int) -> Finish {
        guard pendingCreate == token else { return .stale }
        pendingCreate = nil
        hasRenderer = true
        return .install(closed: !open)
    }

    mutating func failCreate(token: Int) {
        if pendingCreate == token { pendingCreate = nil }
    }
}
