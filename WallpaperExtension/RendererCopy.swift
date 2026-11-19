import Foundation

/// Which file a `VideoRenderer` opens on create, switch, tier change, and
/// wake, beside the `RendererLifecycle` on the same queue. It owns the
/// variant selector and a switch held while the displays sleep; the renderer
/// passes the file it reads as `current` and loads tracks through `open`,
/// which returns nil for a file with no video track.
///
/// Every open tries the choice's copy for the display and tier, then its
/// original, so a bad copy can't keep a valid wallpaper off screen. The
/// choice (original and selector) changes only when one of them opens (or
/// is already playing), so a failed switch leaves the old choice in place.
struct RendererCopy {
    typealias Selector = @Sendable (CGSize, PlaybackPolicy) -> URL

    enum Opened<Loaded> {
        /// `open` succeeded; the renderer makes `Loaded` its asset.
        case opened(Loaded)
        /// The file to open is already the current one.
        case unchanged
        /// The displays sleep; `wake` opens the latest held switch.
        case held
        /// Nothing opened; the current file stays.
        case failed
    }

    private typealias Choice = (original: URL, selector: Selector)

    private var active: Choice
    private var held: Choice?

    init(original: URL, selector: @escaping Selector) {
        active = (original, selector)
    }

    /// The first file a new renderer reads: the copy for `tier`, else
    /// `requested`.
    static func opening<Loaded>(
        _ requested: URL,
        selector: @escaping Selector,
        tier: PlaybackPolicy,
        displayPixels: CGSize,
        open: (URL) async -> Loaded?,
    ) async -> Loaded? {
        for url in candidates(requested, selector: selector, tier: tier, displayPixels: displayPixels) {
            if let loaded = await open(url) { return loaded }
        }
        return nil
    }

    /// Switch to choice `url` (its original) picked by `selector`. With
    /// `hold` (the displays sleep or the surface is closed) the switch is
    /// held, and a later one replaces it.
    mutating func switchTo<Loaded>(
        _ url: URL,
        selector: @escaping Selector,
        current: URL,
        tier: PlaybackPolicy,
        displayPixels: CGSize,
        hold: Bool,
        open: (URL) -> Loaded?,
    ) -> Opened<Loaded> {
        if hold {
            held = (url, selector)
            return .held
        }
        return openFirst((url, selector), tier: tier, displayPixels: displayPixels, current: current, open: open)
    }

    /// Move to the active choice's copy for `tier`, or its original. Start
    /// calls this with the tier current then, whatever the lifecycle has
    /// recorded, because a paused tier opens a different copy than it plays.
    mutating func retier<Loaded>(
        current: URL,
        tier: PlaybackPolicy,
        displayPixels: CGSize,
        open: (URL) -> Loaded?,
    ) -> Opened<Loaded> {
        openFirst(active, tier: tier, displayPixels: displayPixels, current: current, open: open)
    }

    /// The displays woke: open the held switch, or the copy for a tier that
    /// changed during sleep. Paused with nothing held keeps the current file
    /// (see `VariantSelection.preloadURL`).
    mutating func wake<Loaded>(
        current: URL,
        tier: PlaybackPolicy,
        displayPixels: CGSize,
        open: (URL) -> Loaded?,
    ) -> Opened<Loaded> {
        if let held {
            self.held = nil
            return openFirst(held, tier: tier, displayPixels: displayPixels, current: current, open: open)
        }
        guard tier != .paused else { return .unchanged }
        return retier(current: current, tier: tier, displayPixels: displayPixels, open: open)
    }

    /// The surface reopened: open the switch held while it was closed. A
    /// tier change alone waits for the loop boundary, so a reopen with
    /// nothing held resumes in place.
    mutating func reopen<Loaded>(
        current: URL,
        tier: PlaybackPolicy,
        displayPixels: CGSize,
        open: (URL) -> Loaded?,
    ) -> Opened<Loaded> {
        guard let held else { return .unchanged }
        self.held = nil
        return openFirst(held, tier: tier, displayPixels: displayPixels, current: current, open: open)
    }

    /// The file to read at a loop boundary instead of `preloaded`, or nil to
    /// keep it. A preload is picked for the tier current when it was made, so
    /// a tier change recorded while the surface was closed or the displays
    /// slept would otherwise play one more loop of the old copy.
    func loopReplacement(preloaded: URL, current: URL, tier: PlaybackPolicy, displayPixels: CGSize) -> URL? {
        let wanted = preloadURL(current: current, tier: tier, displayPixels: displayPixels)
        return wanted == preloaded ? nil : wanted
    }

    func preloadURL(current: URL, tier: PlaybackPolicy, displayPixels: CGSize) -> URL {
        VariantSelection.preloadURL(current: current, tier: tier, displayPixels: displayPixels, selector: active.selector)
    }

    /// The copy for the display and tier, then the original.
    private static func candidates(_ requested: URL, selector: @escaping Selector, tier: PlaybackPolicy, displayPixels: CGSize) -> [URL] {
        let copy = VariantSelection.openingURL(requested: requested, tier: tier, displayPixels: displayPixels, selector: selector)
        return copy == requested ? [requested] : [copy, requested]
    }

    /// Open `choice`'s copy for `tier`, else its original, and make it the
    /// active choice when one opens or is already `current`.
    private mutating func openFirst<Loaded>(
        _ choice: Choice,
        tier: PlaybackPolicy,
        displayPixels: CGSize,
        current: URL,
        open: (URL) -> Loaded?,
    ) -> Opened<Loaded> {
        for url in Self.candidates(choice.original, selector: choice.selector, tier: tier, displayPixels: displayPixels) {
            if url == current {
                active = choice
                return .unchanged
            }
            if let loaded = open(url) {
                active = choice
                return .opened(loaded)
            }
        }
        return .failed
    }
}

extension RendererCopy.Opened: Equatable where Loaded: Equatable {}
