import Foundation
import LumaWallCore
import Testing

struct EnergyLogStoreTests {
    @Test func reportsSoakAveragesAnd24HourGate() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var samples: [EnergySample] = []
        for index in 0..<5 {
            samples.append(
                EnergySample(
                    date: start.addingTimeInterval(Double(index) * 3_600),
                    processCPUPercent: Double(index + 1),
                    systemCPUPercent: 10,
                    processMemoryMB: 100 + Double(index * 10),
                    batteryPercent: 80 - index,
                    isOnBattery: true,
                    decoderCount: 1,
                    powerProfile: "automatic",
                    playbackActive: true
                )
            )
        }
        let short = EnergyLogStore.makeReport(
            samples: samples,
            startedAt: start,
            endedAt: start.addingTimeInterval(4 * 3_600)
        )
        #expect(short.sampleCount == 5)
        #expect(short.averageProcessCPU == 3)
        #expect(short.peakProcessCPU == 5)
        #expect(short.averageMemoryMB == 120)
        #expect(short.batteryDeltaPercent == -4)
        #expect(!short.meets24HourGate)

        let long = EnergyLogStore.makeReport(
            samples: samples,
            startedAt: start,
            endedAt: start.addingTimeInterval(24 * 3_600)
        )
        #expect(long.meets24HourGate)
        #expect(long.proofSummary.contains("24h threshold met"))
    }

    @Test func persistsSamplesAndPrunesOlderThanRetention() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try EnergyLogStore(rootURL: root)
        let now = Date()
        try await store.startSoak(at: now.addingTimeInterval(-2 * 3_600))
        let stale = EnergySample(
            date: now.addingTimeInterval(-25 * 3_600),
            processCPUPercent: 9,
            systemCPUPercent: 20,
            processMemoryMB: 200,
            batteryPercent: 50,
            isOnBattery: false,
            decoderCount: 2,
            powerProfile: "automatic",
            playbackActive: false
        )
        let fresh = EnergySample(
            date: now.addingTimeInterval(-1 * 3_600),
            processCPUPercent: 2,
            systemCPUPercent: 12,
            processMemoryMB: 110,
            batteryPercent: 90,
            isOnBattery: false,
            decoderCount: 1,
            powerProfile: "automatic",
            playbackActive: true
        )
        try await store.record(stale, now: now)
        try await store.record(fresh, now: now)
        let snapshot = await store.current()
        #expect(snapshot.samples.count == 1)
        #expect(snapshot.samples[0].processCPUPercent == 2)
        let report = await store.report(now: now)
        #expect(report?.sampleCount == 1)
        #expect(report?.proofSummary.contains("LumaWall Energy Log") == true)
    }

    @Test func clearSoakResetsWindowButKeepsSamples() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try EnergyLogStore(rootURL: root)
        try await store.startSoak()
        #expect(await store.current().soakStartedAt != nil)
        try await store.clearSoak()
        #expect(await store.current().soakStartedAt == nil)
    }

    @Test func relaunchPrunesStalePersistedSamples() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let first = try EnergyLogStore(rootURL: root)
        try await first.record(EnergySample(
            date: now.addingTimeInterval(-25 * 3_600),
            processCPUPercent: 9, systemCPUPercent: 20, processMemoryMB: 200,
            batteryPercent: 50, isOnBattery: false, decoderCount: 2,
            powerProfile: "automatic", playbackActive: false
        ), now: now)
        try await first.record(EnergySample(
            date: now.addingTimeInterval(-1 * 3_600),
            processCPUPercent: 2, systemCPUPercent: 12, processMemoryMB: 110,
            batteryPercent: 90, isOnBattery: false, decoderCount: 1,
            powerProfile: "automatic", playbackActive: true
        ), now: now)

        // A fresh process loading the persisted file must prune on init, so a
        // relaunch never resurrects out-of-retention samples.
        try await first.flush()
        let second = try EnergyLogStore(rootURL: root)
        let snapshot = await second.current()
        #expect(snapshot.samples.count == 1)
        #expect(snapshot.samples[0].processCPUPercent == 2)
    }

    private func sample(at date: Date, cpu: Double) -> EnergySample {
        EnergySample(
            date: date, processCPUPercent: cpu, systemCPUPercent: 10, processMemoryMB: 100,
            batteryPercent: 80, isOnBattery: false, decoderCount: 1,
            powerProfile: "automatic", playbackActive: true
        )
    }

    private func logFile(in root: URL) -> URL { root.appendingPathComponent("EnergyLog.json") }

    @Test func samplesAreBatchedUntilTheFlushIntervalPasses() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let start = Date()
        let clock = ContinuousClock.now
        let store = try EnergyLogStore(rootURL: root, now: start, instant: clock)
        // Fifteen one-minute samples, all before the 15-minute boundary.
        for minute in 0..<15 {
            let at = start.addingTimeInterval(Double(minute) * 60)
            try await store.record(sample(at: at, cpu: Double(minute)), now: at, instant: clock.advanced(by: .seconds(minute * 60)))
        }
        #expect(!FileManager.default.fileExists(atPath: logFile(in: root).path))
        #expect(await store.current().samples.count == 15)

        // The first record at or past the boundary writes the whole batch once.
        let boundary = start.addingTimeInterval(15 * 60)
        try await store.record(sample(at: boundary, cpu: 15), now: boundary, instant: clock.advanced(by: .seconds(15 * 60)))
        let written = try Data(contentsOf: logFile(in: root))
        let first = try EnergyLogStore(rootURL: root, now: boundary)
        #expect(await first.current().samples.count == 16)

        // Then it stays quiet for another interval.
        let later = boundary.addingTimeInterval(60)
        try await store.record(sample(at: later, cpu: 16), now: later, instant: clock.advanced(by: .seconds(16 * 60)))
        #expect(try Data(contentsOf: logFile(in: root)) == written)
    }

    @Test func wallClockJumpsDoNotMoveTheWriteBoundary() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let start = Date()
        let clock = ContinuousClock.now
        let store = try EnergyLogStore(rootURL: root, now: start, instant: clock)
        // The date jumps forward a day but only a minute really passed: no write.
        let jumpedForward = start.addingTimeInterval(24 * 3_600)
        try await store.record(sample(at: jumpedForward, cpu: 1), now: jumpedForward, instant: clock.advanced(by: .seconds(60)))
        #expect(!FileManager.default.fileExists(atPath: logFile(in: root).path))
        // The date steps back an hour but 15 real minutes passed: write.
        let steppedBack = start.addingTimeInterval(-3_600)
        try await store.record(sample(at: steppedBack, cpu: 2), now: steppedBack, instant: clock.advanced(by: .seconds(15 * 60)))
        #expect(FileManager.default.fileExists(atPath: logFile(in: root).path))
    }

    @Test func failedWriteKeepsSamplesPendingAndRetriesOnTheNextRecord() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        let start = Date()
        let clock = ContinuousClock.now
        let store = try EnergyLogStore(rootURL: root, now: start, instant: clock)
        try await store.record(sample(at: start, cpu: 1), now: start, instant: clock.advanced(by: .seconds(60)))
        // A read-only directory makes the atomic write fail.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        let due = start.addingTimeInterval(15 * 60)
        await #expect(throws: (any Error).self) {
            try await store.record(sample(at: due, cpu: 2), now: due, instant: clock.advanced(by: .seconds(15 * 60)))
        }
        #expect(!FileManager.default.fileExists(atPath: logFile(in: root).path))

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        let next = due.addingTimeInterval(60)
        try await store.record(sample(at: next, cpu: 3), now: next, instant: clock.advanced(by: .seconds(16 * 60)))
        let reloaded = try EnergyLogStore(rootURL: root, now: next)
        #expect(await reloaded.current().samples.map(\.processCPUPercent) == [1, 2, 3])
    }

    @Test func soakStartAndClearWriteImmediately() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let store = try EnergyLogStore(rootURL: root, now: now)
        try await store.record(sample(at: now, cpu: 1), now: now)
        let started = Date(timeIntervalSince1970: (now.timeIntervalSince1970 - 60).rounded(.down))
        try await store.startSoak(at: started)
        let afterStart = try EnergyLogStore(rootURL: root, now: now)
        #expect(await afterStart.current().soakStartedAt == started)
        // The pending sample goes out with the same write.
        #expect(await afterStart.current().samples.count == 1)

        try await store.clearSoak()
        let afterClear = try EnergyLogStore(rootURL: root, now: now)
        #expect(await afterClear.current().soakStartedAt == nil)
    }

    @Test func flushWritesPendingSamplesOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let store = try EnergyLogStore(rootURL: root, now: now)
        try await store.record(sample(at: now, cpu: 3), now: now)
        #expect(!FileManager.default.fileExists(atPath: logFile(in: root).path))
        try await store.flush()
        let reloaded = try EnergyLogStore(rootURL: root, now: now)
        #expect(await reloaded.current().samples.map(\.processCPUPercent) == [3])

        // Nothing pending: flush leaves the file alone.
        let written = try Data(contentsOf: logFile(in: root))
        try await store.flush()
        #expect(try Data(contentsOf: logFile(in: root)) == written)
    }

    @Test func legacyFileWithoutAnyBatchingMetadataStillLoads() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let now = Date()
        let legacy = EnergyLogSnapshot(samples: [sample(at: now.addingTimeInterval(-60), cpu: 7)], soakStartedAt: nil)
        try StoreIO.writeJSON(legacy, to: logFile(in: root))
        let store = try EnergyLogStore(rootURL: root, now: now)
        #expect(await store.current().samples.map(\.processCPUPercent) == [7])
    }
}
