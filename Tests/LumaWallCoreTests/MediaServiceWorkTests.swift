import Foundation
import Testing

@testable import LumaWallCore

/// The service's request bookkeeping: a cap on concurrent work,
/// cancellation when a connection goes away, and a deadline that ends the
/// process when a decode hangs past it.
struct MediaServiceWorkTests {
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<2_000 where !condition() { try? await Task.sleep(for: .milliseconds(1)) }
    }

    @Test func refusesWorkPastTheLimit() async {
        let work = MediaServiceWork(limit: 1, deadline: .seconds(60), onOverrun: {})
        let release = Flag()
        let started = work.start { while !release.isSet { try? await Task.sleep(for: .milliseconds(1)) } }
        #expect(started != nil)
        #expect(work.start {} == nil)
        release.set()
        await waitUntil { work.activeCount == 0 }
        #expect(work.start {} != nil)
    }

    @Test func cancelsAConnectionsWork() async {
        let work = MediaServiceWork(limit: 4, deadline: .seconds(60), onOverrun: {})
        let cancelled = Flag()
        let id = work.start {
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(1)) }
            cancelled.set()
        }
        work.cancel([try! #require(id)])
        await waitUntil { cancelled.isSet }
        #expect(cancelled.isSet)
    }

    @Test func workPastItsDeadlineEndsTheService() async {
        // A decode that ignores cancellation would otherwise hold its file
        // and a CPU after the app gave up on it.
        let overrun = Flag()
        let work = MediaServiceWork(limit: 4, deadline: .milliseconds(50), onOverrun: { overrun.set() })
        let release = Flag()
        _ = work.start { while !release.isSet { try? await Task.sleep(for: .milliseconds(1)) } }
        await waitUntil { overrun.isSet }
        #expect(overrun.isSet)
        release.set()
    }

    @Test func receivedWorkKeepsItsOwnDeadlineUntilItFinishes() {
        let overrun = Flag()
        let now = ContinuousClock.now
        var deadlines = MediaRequestDeadlines()
        let finished = UUID()
        let stalled = UUID()
        let later = UUID()
        deadlines.receive(finished, deadline: now + .seconds(110))
        deadlines.receive(stalled, deadline: now + .seconds(111))
        deadlines.receive(later, deadline: now + .seconds(210))
        deadlines.finish(finished)

        deadlines.check(at: now + .seconds(110), onOverrun: { overrun.set() })
        #expect(!overrun.isSet)
        deadlines.check(at: now + .seconds(111), onOverrun: { overrun.set() })
        #expect(overrun.isSet)
    }
}
