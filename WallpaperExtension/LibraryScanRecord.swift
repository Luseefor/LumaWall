import Foundation

/// Orders overlapping library scans. A scan publishes its listing only if no
/// scan that started after it has published, so an older listing can't
/// replace a newer one. Freshness counts from when the published scan
/// started: its listing shows the library as of then.
struct LibraryScanRecord {
    private var lastStarted = 0
    private var lastPublished = 0
    private(set) var publishedStart: Date?

    /// A scan is starting; returns its token.
    mutating func begin() -> Int {
        lastStarted += 1
        return lastStarted
    }

    /// The scan `token`, started at `startedAt`, finished. True when it
    /// should publish its listing.
    mutating func finish(_ token: Int, startedAt: Date) -> Bool {
        guard token > lastPublished else { return false }
        lastPublished = token
        publishedStart = startedAt
        return true
    }

    func isFresh(now: Date, maxAge: TimeInterval) -> Bool {
        guard let publishedStart else { return false }
        let age = now.timeIntervalSince(publishedStart)
        return age >= 0 && age < maxAge
    }
}
