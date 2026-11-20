import Foundation
import XCTest
@testable import LumaWall

private typealias Queue = NativeWallpaperDeployment.VariantEncodeQueue

/// Stand-in encoder state. Each encode waits until the test opens its gate
/// (or the queue cancels it), so ordering doesn't depend on timing.
private final class EncodeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var started: [String] = []
    private var finished: [String] = []
    private var open: Set<String> = []
    private var autoOpen = false
    private var running = 0
    private var maxRunningCount = 0
    private var readiness: [String: Queue.Readiness] = [:]
    private var clock = Date(timeIntervalSinceReferenceDate: 0)
    var result: Queue.Outcome = .done
    /// Outcomes for the first encodes, before `result` applies.
    var results: [Queue.Outcome] = []

    var order: [String] { lock.withLock { started } }
    var completed: [String] { lock.withLock { finished } }
    var maxRunning: Int { lock.withLock { maxRunningCount } }
    var now: Date {
        get { lock.withLock { clock } }
        set { lock.withLock { clock = newValue } }
    }

    func openAll() { lock.withLock { autoOpen = true } }
    func open(_ name: String) { lock.withLock { _ = open.insert(name) } }
    func set(_ name: String, _ state: Queue.Readiness) { lock.withLock { readiness[name] = state } }

    func readiness(of job: Queue.Job) -> Queue.Readiness {
        lock.withLock { readiness[job.name] } ?? .ready(rank: job.spec.forFullQuality ? 2 : 1)
    }

    func encode(_ job: Queue.Job) async -> Queue.Outcome {
        lock.withLock {
            started.append(job.name)
            running += 1
            maxRunningCount = max(maxRunningCount, running)
        }
        defer { lock.withLock { running -= 1 } }
        while !lock.withLock({ autoOpen || open.contains(job.name) }) {
            if Task.isCancelled { return .notNow }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return lock.withLock {
            finished.append(job.name)
            return results.isEmpty ? result : results.removeFirst()
        }
    }

    func waitUntilStarted(_ name: String, count: Int = 1) async {
        for _ in 0..<5_000 where order.filter({ $0 == name }).count < count {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }
}

private extension Queue.Job {
    var name: String { entryID + "/" + spec.filename }
}

final class VariantEncodeQueueTests: XCTestCase {
    private let specs = Dictionary(
        uniqueKeysWithValues:
            NativeWallpaperDeployment
            .variantSpecs(sourceSize: CGSize(width: 3840, height: 2160), sourceFPS: 60)
            .map { ($0.filename, $0) })

    private func job(_ entry: String, _ filename: String) -> Queue.Job {
        Queue.Job(entryID: entry, sourceURL: URL(fileURLWithPath: "/tmp/\(entry).mov"), contentHash: "h", spec: specs[filename]!)
    }

    private func queue(_ log: EncodeLog) -> Queue {
        Queue(readiness: { log.readiness(of: $0) }, encode: { await log.encode($0) }, now: { log.now })
    }

    func testEncodesRunOneAtATimeLowestRankFirst() async {
        // Each deploy and restore started its own detached encodes, so
        // several 4K exports could run at once, the 1440p one among the first.
        let log = EncodeLog()
        log.set("b/Wallpaper.minimal.mov", .ready(rank: 0))
        let queue = queue(log)
        await queue.enqueue([job("a", "Wallpaper.reduced.mov")])
        await log.waitUntilStarted("a/Wallpaper.reduced.mov")
        await queue.enqueue([job("a", "Wallpaper.qhd.mov"), job("a", "Wallpaper.minimal.mov")])
        await queue.enqueue([job("b", "Wallpaper.reduced.mov"), job("b", "Wallpaper.minimal.mov")])
        await queue.enqueue([job("b", "Wallpaper.minimal.mov")])
        log.openAll()
        await queue.drained()
        XCTAssertEqual(log.maxRunning, 1)
        XCTAssertEqual(
            log.order,
            [
                "a/Wallpaper.reduced.mov", "b/Wallpaper.minimal.mov", "a/Wallpaper.minimal.mov",
                "b/Wallpaper.reduced.mov", "a/Wallpaper.qhd.mov",
            ])
    }

    func testABatteryCopyPreemptsARunningQHDExport() async {
        // A needed battery copy waited behind a running 4K export.
        let log = EncodeLog()
        let queue = queue(log)
        await queue.enqueue([job("a", "Wallpaper.qhd.mov")])
        await log.waitUntilStarted("a/Wallpaper.qhd.mov")
        await queue.enqueue([job("a", "Wallpaper.minimal.mov")])
        log.open("a/Wallpaper.minimal.mov")
        await log.waitUntilStarted("a/Wallpaper.qhd.mov", count: 2)
        log.openAll()
        await queue.drained()
        XCTAssertEqual(log.order, ["a/Wallpaper.qhd.mov", "a/Wallpaper.minimal.mov", "a/Wallpaper.qhd.mov"])
        XCTAssertEqual(log.completed, ["a/Wallpaper.minimal.mov", "a/Wallpaper.qhd.mov"])
    }

    func testAQHDExportPlaybackNeedsIsNotPreemptedByAnUnusedBatteryCopy() async {
        let log = EncodeLog()
        log.set("a/Wallpaper.qhd.mov", .ready(rank: 0))
        let queue = queue(log)
        await queue.enqueue([job("a", "Wallpaper.qhd.mov")])
        await log.waitUntilStarted("a/Wallpaper.qhd.mov")
        await queue.enqueue([job("a", "Wallpaper.minimal.mov")])
        let preempted = await queue.runningJobWasPreempted
        XCTAssertFalse(preempted)
        log.openAll()
        await queue.drained()
        XCTAssertEqual(log.order, ["a/Wallpaper.qhd.mov", "a/Wallpaper.minimal.mov"])
    }

    func testHeldCopyWaitsForWake() async {
        // A power-blocked 1440p job was discarded, so plugging in did not
        // make it until the next apply or restore.
        let log = EncodeLog()
        log.openAll()
        log.set("a/Wallpaper.qhd.mov", .hold)
        let queue = queue(log)
        await queue.enqueue([job("a", "Wallpaper.qhd.mov")])
        await queue.drained()
        XCTAssertEqual(log.order, [])
        log.set("a/Wallpaper.qhd.mov", .ready(rank: 2))
        await queue.wake()
        await queue.drained()
        XCTAssertEqual(log.order, ["a/Wallpaper.qhd.mov"])
    }

    func testRunningQHDExportStopsWhenNoLongerWanted() async {
        // Unplugging (or losing the display that would play it) left the
        // 1440p export running to the end.
        let log = EncodeLog()
        let queue = queue(log)
        await queue.enqueue([job("a", "Wallpaper.qhd.mov")])
        await log.waitUntilStarted("a/Wallpaper.qhd.mov")
        log.set("a/Wallpaper.qhd.mov", .hold)
        await queue.wake()
        await queue.drained()
        XCTAssertEqual(log.completed, [])
        log.set("a/Wallpaper.qhd.mov", .ready(rank: 2))
        log.openAll()
        await queue.wake()
        await queue.drained()
        XCTAssertEqual(log.completed, ["a/Wallpaper.qhd.mov"])
    }

    func testRunningBatteryCopyStopsOnceDropped() async {
        // Turning native mode off drops every job. A battery copy that keeps
        // encoding would still write into the extension's container.
        let log = EncodeLog()
        let queue = queue(log)
        await queue.enqueue([job("a", "Wallpaper.minimal.mov")])
        await log.waitUntilStarted("a/Wallpaper.minimal.mov")
        log.set("a/Wallpaper.minimal.mov", .drop)
        await queue.wake()
        let preempted = await queue.runningJobWasPreempted
        XCTAssertTrue(preempted)
        log.openAll()
        await queue.drained()
    }

    func testRunningBatteryCopyFinishesWhenOnlyHeld() async {
        let log = EncodeLog()
        let queue = queue(log)
        await queue.enqueue([job("a", "Wallpaper.minimal.mov")])
        await log.waitUntilStarted("a/Wallpaper.minimal.mov")
        log.set("a/Wallpaper.minimal.mov", .hold)
        await queue.wake()
        log.openAll()
        await queue.drained()
        XCTAssertEqual(log.completed, ["a/Wallpaper.minimal.mov"])
    }

    func testDroppedJobsDoNotRun() async {
        let log = EncodeLog()
        log.openAll()
        log.set("a/Wallpaper.minimal.mov", .drop)
        let queue = queue(log)
        await queue.enqueue([job("a", "Wallpaper.minimal.mov")])
        await queue.drained()
        XCTAssertEqual(log.order, [])
    }

    func testFailedCopiesRetryAfter5_10And20MinutesThenStop() async {
        // A failure used to block the copy for the rest of the session.
        let log = EncodeLog()
        log.openAll()
        log.result = .failed
        let queue = queue(log)
        let failing = job("a", "Wallpaper.minimal.mov")
        func attempts(at seconds: TimeInterval) async -> Int {
            log.now = Date(timeIntervalSinceReferenceDate: seconds)
            await queue.enqueue([failing])
            await queue.drained()
            return log.order.count
        }
        XCTAssertEqual(Queue.maxAttempts, 4)
        let schedule: [(TimeInterval, Int)] = [
            (0, 1), (299, 1), (300, 2), (899, 2), (900, 3), (2_099, 3), (2_100, 4), (1_000_000, 4),
        ]
        for (time, expected) in schedule {
            let count = await attempts(at: time)
            XCTAssertEqual(count, expected, "at \(time) s")
        }
    }

    func testNotNowOutcomeParksWithoutCountingAFailure() async {
        let log = EncodeLog()
        log.openAll()
        log.result = .notNow
        let queue = queue(log)
        await queue.enqueue([job("a", "Wallpaper.qhd.mov")])
        await queue.drained()
        XCTAssertEqual(log.order.count, 1)
        log.result = .done
        for _ in 0..<5 { await queue.wake() }
        await queue.drained()
        XCTAssertEqual(log.order.count, 2)
    }

    func testAWakeDuringAnAttemptIsNotLostWhenItStops() async {
        // The pre-export check saw power blocked, AC came back and woke the
        // queue before the job parked, so it stayed parked until another wake.
        let log = EncodeLog()
        log.results = [.notNow]
        let queue = queue(log)
        await queue.enqueue([job("a", "Wallpaper.qhd.mov")])
        await log.waitUntilStarted("a/Wallpaper.qhd.mov")
        await queue.wake()
        log.openAll()
        await queue.drained()
        XCTAssertEqual(log.order, ["a/Wallpaper.qhd.mov", "a/Wallpaper.qhd.mov"])
    }
}
