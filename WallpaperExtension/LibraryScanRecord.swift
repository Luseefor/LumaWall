import Foundation

/// Orders overlapping library scans. A scan publishes its listing only if no
/// scan that started after it has published, so an older listing can't
/// replace a newer one.
struct LibraryScanRecord {
    private var lastStarted = 0
    private var lastPublished = 0

    /// A scan is starting; returns its token.
    mutating func begin() -> Int {
        lastStarted += 1
        return lastStarted
    }

    /// The scan `token` finished. True when it should publish its listing.
    mutating func finish(_ token: Int) -> Bool {
        guard token > lastPublished else { return false }
        lastPublished = token
        return true
    }
}
