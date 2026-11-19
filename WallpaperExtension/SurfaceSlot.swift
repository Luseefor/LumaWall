import Foundation

/// Bookkeeping for one surface's context beside its `CAContext` and
/// renderer: whether playback is open, which renderer create owns the slot,
/// and whether a live request has used it. Pure so the acquire, invalidate,
/// create, and lease orderings run as tests; `WallpaperState` keeps one per
/// context and acts on its answers under its lock.
struct SurfaceSlot: Equatable {
    /// False from an invalidate until the next acquire, or once a preview's
    /// lease runs out.
    private(set) var open = true
    /// A desktop or lock-screen request acquired this context.
    private(set) var servedLive = false
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

    struct Acquired: Equatable {
        var reopened: Bool
        /// A live request took over a preview context: its renderer drops
        /// the preview role and takes live policy from now on.
        var promoted: Bool
    }

    /// An acquire reached this context.
    mutating func acquired(byPreview: Bool, contextIsPreview: Bool) -> Acquired {
        let wasPreview = playsAsPreview(contextIsPreview: contextIsPreview)
        if !byPreview { servedLive = true }
        return Acquired(reopened: setOpen(true), promoted: wasPreview && !playsAsPreview(contextIsPreview: contextIsPreview))
    }

    /// A preview context plays and leases as a preview until a live request
    /// uses it. Left a preview, a live wallpaper on it would freeze when the
    /// lease ran out, or hold one frame when no copy fits.
    func playsAsPreview(contextIsPreview: Bool) -> Bool {
        contextIsPreview && !servedLive
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

/// Preview leases by surface. Each renewal supersedes the timer armed
/// before it, so only the latest lease's expiry acts, and ending one
/// disarms whatever timer is still pending.
struct LeaseBook<Key: Hashable> {
    private var current: [Key: Int] = [:]
    private var counter = 0

    /// Start or renew `key`'s lease; arm its timer with the returned id.
    mutating func renew(_ key: Key) -> Int {
        counter += 1
        current[key] = counter
        return counter
    }

    mutating func end(_ key: Key) {
        current[key] = nil
    }

    /// A lease timer fired. True when it is `key`'s current lease, which ends.
    mutating func expire(_ key: Key, lease: Int) -> Bool {
        guard current[key] == lease else { return false }
        current[key] = nil
        return true
    }
}
