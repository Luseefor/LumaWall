import Foundation

/// Tracks which diagnostics views are currently on screen.
///
/// Each view reports its own state under a stable id, so a repeated report
/// can't drift a counter: showing the same view twice still counts once.
public struct DiagnosticsVisibility: Equatable, Sendable {
    public enum Change: Equatable, Sendable {
        case becameVisible
        case becameHidden
    }

    private var viewers: Set<UUID> = []

    public init() {}

    public var isVisible: Bool { !viewers.isEmpty }

    /// Records `viewer` as shown or hidden. Returns a change only when the
    /// "any view visible" state flips.
    @discardableResult
    public mutating func set(_ viewer: UUID, visible: Bool) -> Change? {
        let wasVisible = isVisible
        if visible {
            viewers.insert(viewer)
        } else {
            viewers.remove(viewer)
        }
        switch (wasVisible, isVisible) {
        case (false, true): return .becameVisible
        case (true, false): return .becameHidden
        default: return nil
        }
    }
}
