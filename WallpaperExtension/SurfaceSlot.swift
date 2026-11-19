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
    /// Connections whose request of the other role was handed this context
    /// without changing it (the Settings picker reusing the live surface's
    /// id). That host's invalidate comes on its own connection.
    private(set) var sharers: Set<Int> = []
    /// A request of the other role was ever handed this context. On a
    /// preview context that request was live, so it plays as live for good.
    private(set) var everShared = false
    /// The latest acquirer left: its invalidate, or the agent's cleanup after
    /// its connection dropped. An acquire clears it.
    private(set) var ownerLeft = false
    /// The token of the renderer create in flight.
    private(set) var pendingCreate: Int?
    private(set) var hasRenderer = false

    /// The role of the request that created the context; sharers are the
    /// other role.
    let ownerIsPreview: Bool

    init(acquiredBy connection: Int? = nil, ownerIsPreview: Bool = false) {
        lastAcquirer = connection
        self.ownerIsPreview = ownerIsPreview
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
    /// unchanged) is not an acquisition: its invalidate must not freeze the
    /// surface's real owner. It reopens playback for its host unless
    /// `reopens` is false: a preview handed a closed live surface keeps its
    /// held frame rather than restart full-size decoding for a tile.
    mutating func acquired(by connection: Int?, replyOnly: Bool, reopens: Bool = true) -> Bool {
        if replyOnly {
            everShared = true
            // A live request reacquiring on a new connection replaces the
            // desktop's old one, which may have dropped without a word.
            if let connection {
                if ownerIsPreview { sharers = [connection] } else { sharers.insert(connection) }
            }
        } else if let connection {
            lastAcquirer = connection
            ownerLeft = false
        } else {
            ownerLeft = false
        }
        return reopens && setOpen(true)
    }

    enum InvalidateAction: Equatable {
        /// The invalidate belongs to the latest acquisition: stop playback now.
        case close
        /// It belongs to an earlier acquisition another open connection has
        /// since replaced, or another host still shows the surface: keep
        /// playing, and keep the context past the grace.
        case graceOnly

        /// Whether the invalidate retires the surface's WallpaperID. A
        /// grace-only one keeps it, so the owner's own invalidate during the
        /// grace still finds the surface; teardown retires it otherwise.
        var retiresWallpaperID: Bool { self == .close }
    }

    /// The protocol names only the surface, so the connection decides which
    /// host left: a sharer's connection, the latest acquirer's, or another
    /// one. Another connection is the agent cleaning up after a reconnect
    /// when a host's connection has dropped (that host left), and otherwise
    /// an older connection a reacquire replaced, which changes nothing. On a
    /// connection that is both the acquirer's and a sharer's, the first
    /// invalidate counts as the sharer's. The surface closes, and the slot
    /// with it, once no host is left (`hosted`).
    mutating func invalidated(by connection: Int, openConnections: Set<Int>) -> InvalidateAction {
        if sharers.remove(connection) != nil {
            // That sharer left.
        } else if lastAcquirer == nil || lastAcquirer == connection {
            ownerLeft = true
        } else {
            let ownerDropped = lastAcquirer.map { !openConnections.contains($0) } ?? false
            let droppedSharers = sharers.subtracting(openConnections)
            guard ownerDropped || !droppedSharers.isEmpty else { return .graceOnly }
            if ownerDropped { ownerLeft = true }
            sharers.subtract(droppedSharers)
        }
        return closeIfUnhosted(openConnections: openConnections) ? .close : .graceOnly
    }

    /// A connection closed. A preview host on it (the Settings app quitting
    /// without an invalidate) is gone, and the surface closes when it was
    /// the last host. An already closed surface that loses its last host
    /// this way is reported too, so its teardown (which the sharer's acquire
    /// cancelled) is armed again. Returns whether it closed or lost its last
    /// host.
    mutating func connectionsChanged(openConnections: Set<Int>) -> Bool {
        // Sharers of a live context are previews; a live sharer may reconnect.
        let dropped = ownerIsPreview ? [] : sharers.subtracting(openConnections)
        sharers.subtract(dropped)
        guard open || !dropped.isEmpty else { return false }
        return closeIfUnhosted(openConnections: openConnections)
    }

    /// Whether any host may still show the surface. A preview host counts
    /// while its connection is open. A live host counts until its own
    /// invalidate, the agent's cleanup, or a reacquire replaces it, even
    /// with its connection dropped: the agent can keep the desktop showing
    /// the context across a reconnect.
    private func hosted(openConnections: Set<Int>) -> Bool {
        let ownerHosts = lastAcquirer.map { !ownerLeft && (!ownerIsPreview || openConnections.contains($0)) } ?? false
        let sharersHost = ownerIsPreview ? !sharers.isEmpty : !sharers.isDisjoint(with: openConnections)
        return ownerHosts || sharersHost
    }

    private mutating func closeIfUnhosted(openConnections: Set<Int>) -> Bool {
        guard !hosted(openConnections: openConnections) else { return false }
        open = false
        return true
    }

    /// Whether the renderer holds one frame when no copy fits its viewport.
    /// Only a preview context does, and only until a live request is handed
    /// it: a desktop showing that context must never freeze on that rule.
    /// (It keeps the preview tier, whose pauses the live rules all share.)
    /// A preview sharing a live context never changes it.
    func holdsPreviewFrame(contextIsPreview: Bool) -> Bool {
        contextIsPreview && !everShared
    }

    /// The grace after an invalidate ran out with no reacquire. Only a closed
    /// surface is torn down: one still open was kept playing by an ambiguous
    /// invalidate, and its owner may still host the context.
    var tearsDownAtGraceEnd: Bool { !open }

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

/// Acquire replies waiting for a surface's layer to show something. A
/// renderer create that replies once its layer is seeded opens the gate for
/// its token with its own reply; acquires that reuse the surface meanwhile,
/// of either role, wait behind it. Waiters belong to the token, so a create
/// whose context was torn down can't release the replies of the create that
/// replaced it, and teardown answers them at once. Touched only on
/// `Lifecycle.queue`.
struct ReplyGate<Key: Hashable, Waiter> {
    private var pending: [Key: (token: Int, waiters: [Waiter])] = [:]

    /// `token`'s create replies with `reply` once its layer can show
    /// something. Returns the waiters of an earlier create on `key` whose
    /// context went away without `close`.
    mutating func open(_ key: Key, token: Int, reply: Waiter) -> [Waiter] {
        let displaced = pending[key]?.waiters ?? []
        pending[key] = (token, [reply])
        return displaced
    }

    /// Hold `waiter` behind the create seeding `key`. False when none is,
    /// so the caller replies now.
    mutating func hold(_ waiter: Waiter, for key: Key) -> Bool {
        guard pending[key] != nil else { return false }
        pending[key]?.waiters.append(waiter)
        return true
    }

    /// `token`'s layer can show something: its reply and the held ones, in
    /// order. Empty when another create owns the key.
    mutating func ready(_ key: Key, token: Int) -> [Waiter] {
        guard pending[key]?.token == token else { return [] }
        return pending.removeValue(forKey: key)?.waiters ?? []
    }

    /// The surface was torn down: every reply still waiting on it.
    mutating func close(_ key: Key) -> [Waiter] {
        pending.removeValue(forKey: key)?.waiters ?? []
    }
}
