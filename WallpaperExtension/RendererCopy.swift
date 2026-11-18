import Foundation

/// Which file a `VideoRenderer` opens on create, switch, tier change, and
/// wake, beside the `RendererLifecycle` on the same queue. It owns the
/// variant selector and a switch held while the displays sleep; the renderer
/// passes the file it reads as `current` and loads tracks through `open`,
/// which returns nil for a file with no video track.
///
/// A new choice opens its copy for the display and tier and falls back to
/// its original, so a bad copy can't keep a valid wallpaper off screen. The
/// selector changes only when one of them opens (or is already playing), so
/// a failed switch leaves the old choice's selector with the old file.
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

    private var selector: Selector?
    private var held: (url: URL, selector: Selector)?

    init(selector: Selector?) {
        self.selector = selector
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

    /// Switch to choice `url` (its original) picked by `selector`. While the
    /// displays sleep the switch is held, and a later one replaces it.
    mutating func switchTo<Loaded>(
        _ url: URL,
        selector: @escaping Selector,
        current: URL,
        tier: PlaybackPolicy,
        displayPixels: CGSize,
        asleep: Bool,
        open: (URL) -> Loaded?,
    ) -> Opened<Loaded> {
        if asleep {
            held = (url, selector)
            return .held
        }
        let urls = Self.candidates(url, selector: selector, tier: tier, displayPixels: displayPixels)
        return openFirst(urls, adopting: selector, current: current, open: open)
    }

    /// Move to the current choice's copy for `tier`. If it won't open, the
    /// current file keeps playing.
    mutating func retier<Loaded>(
        current: URL,
        tier: PlaybackPolicy,
        displayPixels: CGSize,
        open: (URL) -> Loaded?,
    ) -> Opened<Loaded> {
        guard let selector else { return .unchanged }
        let url = VariantSelection.openingURL(requested: current, tier: tier, displayPixels: displayPixels, selector: selector)
        return openFirst([url], adopting: selector, current: current, open: open)
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
            let urls = Self.candidates(held.url, selector: held.selector, tier: tier, displayPixels: displayPixels)
            return openFirst(urls, adopting: held.selector, current: current, open: open)
        }
        guard tier != .paused else { return .unchanged }
        return retier(current: current, tier: tier, displayPixels: displayPixels, open: open)
    }

    func preloadURL(current: URL, tier: PlaybackPolicy, displayPixels: CGSize) -> URL {
        VariantSelection.preloadURL(current: current, tier: tier, displayPixels: displayPixels, selector: selector)
    }

    /// The copy for the display and tier, then the original.
    private static func candidates(_ requested: URL, selector: @escaping Selector, tier: PlaybackPolicy, displayPixels: CGSize) -> [URL] {
        let copy = VariantSelection.openingURL(requested: requested, tier: tier, displayPixels: displayPixels, selector: selector)
        return copy == requested ? [requested] : [copy, requested]
    }

    private mutating func openFirst<Loaded>(
        _ urls: [URL],
        adopting selector: @escaping Selector,
        current: URL,
        open: (URL) -> Loaded?,
    ) -> Opened<Loaded> {
        for url in urls {
            if url == current {
                self.selector = selector
                return .unchanged
            }
            if let loaded = open(url) {
                self.selector = selector
                return .opened(loaded)
            }
        }
        return .failed
    }
}

extension RendererCopy.Opened: Equatable where Loaded: Equatable {}
