import Foundation
import XCTest

/// Ramp timing (#14): the timer steps no faster than the 60 Hz the rate
/// change can be seen at, and the unlock ramp-down only keeps the 6 s feel on
/// power.
final class RampMathTests: XCTestCase {
    private func fullSteps(toward target: Double, onBattery: Bool) -> Int {
        RampMath.steps(
            distance: 1,
            fullDuration: RampMath.fullDuration(toward: target, onBattery: onBattery),
            stepInterval: RampMath.stepInterval,
        )
    }

    func testStepsAt60HzWithLeeway() {
        XCTAssertEqual(RampMath.stepInterval, 1.0 / 60.0, accuracy: 1e-9)
        XCTAssertGreaterThan(RampMath.stepLeeway, 0)
        XCTAssertLessThan(RampMath.stepLeeway, RampMath.stepInterval)
    }

    func testLockRevealRampUpStaysTwoSeconds() {
        XCTAssertEqual(RampMath.fullDuration(toward: 1, onBattery: false), 2)
        XCTAssertEqual(RampMath.fullDuration(toward: 1, onBattery: true), 2)
        // Was 240 steps at 120 Hz.
        XCTAssertEqual(fullSteps(toward: 1, onBattery: false), 120)
    }

    func testUnlockRampDownIsShortOnlyOnBattery() {
        XCTAssertEqual(RampMath.fullDuration(toward: 0, onBattery: false), 6)
        XCTAssertEqual(RampMath.fullDuration(toward: 0, onBattery: true), 2)
        // Was 720 steps of decoding at 120 Hz whatever the power source.
        XCTAssertEqual(fullSteps(toward: 0, onBattery: true), 120)
    }

    func testHardPausesSkipTheRampDown() {
        XCTAssertTrue(RampMath.cutsRampDown(thermalState: .critical, activityState: "active"))
        XCTAssertTrue(RampMath.cutsRampDown(thermalState: .nominal, activityState: "suspended"))
        XCTAssertFalse(RampMath.cutsRampDown(thermalState: .serious, activityState: "active"))
        XCTAssertFalse(RampMath.cutsRampDown(thermalState: .nominal, activityState: "active"))
    }

    func testRampEndsOnItsTarget() {
        XCTAssertEqual(RampMath.rate(from: 1, to: 0, progress: 1), 0)
        XCTAssertEqual(RampMath.rate(from: 0.4, to: 1, progress: 0), 0.4)
    }
}
