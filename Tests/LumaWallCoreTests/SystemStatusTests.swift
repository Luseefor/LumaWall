import Foundation
import LumaWallCore
import Testing

/// Read-only system queries: mach CPU sampling, power-source snapshot, login
/// item status. No mutations, no fixtures — each asserts sane bounds on live
/// (but side-effect-free) values.
struct SystemStatusTests {
    @Test func cpuSamplesStayWithinPercentBounds() {
        var sampler = CPUSampler()
        let first = sampler.sample()
        #expect(first.process >= 0 && first.process <= 100)
        #expect(first.system >= 0 && first.system <= 100)
        // First host sample has no baseline, so it reports zero; the second
        // has a delta to work with.
        #expect(first.system == 0)
        let second = sampler.sample()
        #expect(second.process >= 0 && second.process <= 100)
        #expect(second.system >= 0 && second.system <= 100)
    }

    @Test func cpuSampleAfterWorkComputesNonnegativeUsage() {
        // Burn a little CPU so the host-tick delta is very likely nonzero
        // (exercises the usage-computation branch). Bounds hold either way,
        // so the test is deterministic regardless of scheduler timing.
        var sampler = CPUSampler()
        _ = sampler.sample()
        var sink = 0
        let deadline = Date().addingTimeInterval(0.05)
        while Date() < deadline { sink &+= 1 }
        let busy = sampler.sample()
        #expect(busy.process >= 0 && busy.process <= 100)
        #expect(busy.system >= 0 && busy.system <= 100)
        #expect(sink > 0)
    }

    @Test func powerSnapshotHasSanePercent() {
        let status = PowerStatus.current()
        #expect(status.percent >= 0 && status.percent <= 100)
        #expect(status == PowerStatus(isOnBattery: status.isOnBattery, percent: status.percent))
    }

    @Test func launchAtLoginStatusReadsWithoutThrowing() {
        // Read-only ServiceManagement query; must never trap in tests.
        _ = LaunchAtLogin.isEnabled
    }

    @Test func clearingMemoryCacheDoesNotThrow() {
        CacheCleaner.clearMemory()
    }

    @Test func clearDiskRemovesScratchUnderGivenRoot() throws {
        // Fully temp-isolated: only the Scratch dir under our root is touched.
        // The real ~/Library/Caches/LumaWall branch is intentionally untested.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let scratch = root.appendingPathComponent("Scratch", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 16).write(to: scratch.appendingPathComponent("tmp.bin"))
        defer { try? FileManager.default.removeItem(at: root) }

        // The real ~/Library/Caches/LumaWall branch may or may not exist on the
        // test machine, so only bound the count from below; the Scratch half is
        // fully temp-isolated and asserted exactly.
        #expect(try CacheCleaner.clearDisk(preservingLibraryRoot: root) >= 1)
        #expect(!FileManager.default.fileExists(atPath: scratch.path))
    }
}
