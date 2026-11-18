import Foundation
import XCTest

final class ThermalHoldTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)

    func testWarmingAppliesAtOnce() {
        var hold = ThermalHold()
        XCTAssertEqual(hold.update(raw: .fair, now: t0), .fair)
        XCTAssertEqual(hold.update(raw: .serious, now: t0 + 1), .serious)
    }

    func testOneSecondCoolDipIsIgnored() {
        // Logged on this Mac: fair, nominal a second later, fair again.
        // Each flip used to switch Full <-> 1080p and restart the video.
        var hold = ThermalHold()
        _ = hold.update(raw: .fair, now: t0)
        XCTAssertEqual(hold.update(raw: .nominal, now: t0 + 1), .fair)
        XCTAssertEqual(hold.update(raw: .fair, now: t0 + 2), .fair)
        XCTAssertEqual(hold.update(raw: .nominal, now: t0 + 3), .fair)
        XCTAssertEqual(hold.update(raw: .nominal, now: t0 + 60), .fair)
    }

    func testCoolingAppliesAfterTheHold() {
        var hold = ThermalHold()
        _ = hold.update(raw: .fair, now: t0)
        _ = hold.update(raw: .nominal, now: t0 + 10)
        XCTAssertEqual(hold.releaseDate, t0 + 10 + ThermalHold.releaseDelay)
        XCTAssertEqual(hold.update(raw: .nominal, now: t0 + 10 + ThermalHold.releaseDelay), .nominal)
        XCTAssertNil(hold.releaseDate)
    }

    func testRewarmingRestartsTheHold() {
        var hold = ThermalHold()
        _ = hold.update(raw: .fair, now: t0)
        _ = hold.update(raw: .nominal, now: t0 + 10)
        _ = hold.update(raw: .fair, now: t0 + 100)
        _ = hold.update(raw: .nominal, now: t0 + 110)
        XCTAssertEqual(hold.update(raw: .nominal, now: t0 + 10 + ThermalHold.releaseDelay), .fair)
        XCTAssertEqual(hold.update(raw: .nominal, now: t0 + 110 + ThermalHold.releaseDelay), .nominal)
    }

    func testCoolingStepsDownThroughTheWarmestRecentTier() {
        // critical -> serious, then nominal just before the hold ends must
        // not jump straight to nominal: serious was seen during the hold.
        var hold = ThermalHold()
        _ = hold.update(raw: .critical, now: t0)
        _ = hold.update(raw: .serious, now: t0 + 1)
        _ = hold.update(raw: .nominal, now: t0 + ThermalHold.releaseDelay)
        XCTAssertEqual(hold.update(raw: .nominal, now: t0 + 1 + ThermalHold.releaseDelay), .serious)
        XCTAssertEqual(hold.update(raw: .nominal, now: t0 + 1 + 2 * ThermalHold.releaseDelay), .nominal)
    }
}
