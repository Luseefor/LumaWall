import Foundation
import LumaWallCore
import Testing

/// Read-only system queries: mach CPU sampling, power-source snapshot, login
/// item status. No mutations, no fixtures, each asserts sane bounds on live
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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let scratch = root.appendingPathComponent("Scratch", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 16).write(to: scratch.appendingPathComponent("tmp.bin"))
        defer { try? FileManager.default.removeItem(at: root) }

        let caches = root.appendingPathComponent("NoCaches", isDirectory: true)
        #expect(try CacheCleaner.clearDisk(preservingLibraryRoot: root, cachesURL: caches) == 1)
        #expect(!FileManager.default.fileExists(atPath: scratch.path))
    }

    @Test func clearDiskEmptiesTheCacheFolderGivenToIt() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: base) }
        let cache = base.appendingPathComponent("Caches/LumaWall/posters", isDirectory: true)
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: cache.appendingPathComponent("a.jpg"))
        let root = base.appendingPathComponent("lib", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let removed = try CacheCleaner.clearDisk(
            preservingLibraryRoot: root, cachesURL: base.appendingPathComponent("Caches"))
        #expect(removed == 1)
        #expect(try fm.contentsOfDirectory(atPath: base.appendingPathComponent("Caches/LumaWall").path).isEmpty)
    }

    @Test func clearDiskLeavesSymlinkTargetsAlone() throws {
        // contentsOfDirectory and removeItem followed a cache or Scratch
        // folder swapped for a symlink and emptied its target.
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: base) }
        let victim = base.appendingPathComponent("Documents", isDirectory: true)
        try fm.createDirectory(at: victim, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: victim.appendingPathComponent("thesis.pages"))
        let caches = base.appendingPathComponent("Caches", isDirectory: true)
        let root = base.appendingPathComponent("lib", isDirectory: true)
        try fm.createDirectory(at: caches, withIntermediateDirectories: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: caches.appendingPathComponent("LumaWall"), withDestinationURL: victim)
        try fm.createSymbolicLink(at: root.appendingPathComponent("Scratch"), withDestinationURL: victim)

        _ = try CacheCleaner.clearDisk(preservingLibraryRoot: root, cachesURL: caches)
        #expect(fm.fileExists(atPath: victim.appendingPathComponent("thesis.pages").path))
    }

    @Test func sessionLockReadsTheWindowServerFlag() {
        // The app may launch while the screen is already locked, when no
        // lock notification will arrive. Startup reads this flag instead.
        #expect(SessionLock.isLocked(in: ["CGSSessionScreenIsLocked": true]))
        #expect(SessionLock.isLocked(in: ["CGSSessionScreenIsLocked": 1]))
        #expect(!SessionLock.isLocked(in: ["CGSSessionScreenIsLocked": false]))
        #expect(!SessionLock.isLocked(in: [:]))
        #expect(!SessionLock.isLocked(in: nil))
    }
}
