import Foundation

/// Bookkeeping for one surface's context beside its `CAContext` and
/// renderer: whether playback is open and which renderer create owns the
/// slot. Pure so the acquire, invalidate, and create orderings run as
/// tests; `WallpaperState` keeps one per context and acts on its answers
/// under its lock.
struct SurfaceSlot: Equatable {
    /// False from an invalidate until the next acquire, or once a preview's
    /// lease runs out.
    private(set) var open = true
    /// The token of the renderer create in flight.
    private(set) var pendingCreate: Int?
    private(set) var hasRenderer = false

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
