import LumaWallCore
import Testing

struct CoverageScanPolicyTests {
    @Test func fallbackScansWhenPlaying() {
        #expect(CoverageScanPolicy.fallbackScanNeeded(
            userPausedEverywhere: false, displaysAsleep: false, sessionLocked: false, hasAssignedWallpaper: true))
    }

    @Test func fallbackSkipsWhenCoverageCannotMatter() {
        #expect(!CoverageScanPolicy.fallbackScanNeeded(
            userPausedEverywhere: true, displaysAsleep: false, sessionLocked: false, hasAssignedWallpaper: true))
        #expect(!CoverageScanPolicy.fallbackScanNeeded(
            userPausedEverywhere: false, displaysAsleep: true, sessionLocked: false, hasAssignedWallpaper: true))
        #expect(!CoverageScanPolicy.fallbackScanNeeded(
            userPausedEverywhere: false, displaysAsleep: false, sessionLocked: true, hasAssignedWallpaper: true))
        #expect(!CoverageScanPolicy.fallbackScanNeeded(
            userPausedEverywhere: false, displaysAsleep: false, sessionLocked: false, hasAssignedWallpaper: false))
    }

    @Test func powerChangeClassification() {
        let ac = PowerStatus(isOnBattery: false, percent: 80)
        #expect(CoverageScanPolicy.powerChange(from: ac, to: ac) == .none)
        #expect(CoverageScanPolicy.powerChange(from: ac, to: PowerStatus(isOnBattery: false, percent: 81)) == .percentOnly)
        #expect(CoverageScanPolicy.powerChange(from: ac, to: PowerStatus(isOnBattery: true, percent: 80)) == .sourceSwitched)
    }
}
