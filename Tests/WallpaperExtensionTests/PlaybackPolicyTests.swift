import Foundation
import XCTest

/// The preview tier (#35): a System Settings preview played the Full copy
/// whatever the power state, because the policy fan-out skips previews.
final class PlaybackPolicyTests: XCTestCase {
    private func preview(
        userPaused: Bool = false,
        thermalState: ProcessInfo.ThermalState = .nominal,
        isOnBattery: Bool = false,
        batteryLevel: Int = 100,
        isGameModeActive: Bool = false,
        displayBrightness: Float = 1,
        powerProfile: String = "automatic",
    ) -> PlaybackPolicy {
        PlaybackPolicy.preview(
            userPaused: userPaused,
            thermalState: thermalState,
            isOnBattery: isOnBattery,
            batteryLevel: batteryLevel,
            isGameModeActive: isGameModeActive,
            displayBrightness: displayBrightness,
            powerProfile: powerProfile,
        )
    }

    func testPreviewPlaysOnMainsWithNothingInTheWay() {
        XCTAssertEqual(preview(), .full)
    }

    func testHardPausesStopThePreview() {
        XCTAssertEqual(preview(thermalState: .critical), .paused)
        XCTAssertEqual(preview(displayBrightness: 0), .paused)
        XCTAssertEqual(preview(isOnBattery: true, batteryLevel: 5), .paused)
        XCTAssertEqual(preview(isGameModeActive: true), .paused)
        XCTAssertEqual(preview(userPaused: true), .paused)
    }

    func testPreviewTakesThePowerTiers() {
        XCTAssertEqual(preview(isOnBattery: true), .reduced)
        XCTAssertEqual(preview(powerProfile: "batterySaver"), .minimal)
        XCTAssertEqual(preview(thermalState: .serious), .minimal)
        XCTAssertEqual(preview(isOnBattery: true, powerProfile: "staticOnBattery"), .paused)
    }

    func testDesktopOnlyPausesDoNotReachThePreview() {
        // The same state pauses the desktop through "always pause desktop".
        let desktop = PlaybackPolicy.compute(
            presentationMode: "default", activityState: "active", userPaused: false,
            alwaysPauseDesktop: true, pauseWhenOccluded: true, desktopOccluded: true,
            displayHasFullscreenApp: true, screenSaverIsOurs: false,
            thermalState: .nominal, isOnBattery: false, batteryLevel: 100, isGameModeActive: false,
        )
        XCTAssertEqual(desktop, .paused)
        XCTAssertEqual(preview(), .full)
    }

    // MARK: - Reasons

    private func decide(
        userPaused: Bool = false,
        occluded: Bool = false,
        fullscreen: Bool = false,
        alwaysPauseDesktop: Bool = false,
        presentationMode: String = "default",
        activityState: String = "active",
        thermalState: ProcessInfo.ThermalState = .nominal,
        isOnBattery: Bool = false,
        batteryLevel: Int = 100,
        isGameModeActive: Bool = false,
        isLowPowerModeEnabled: Bool = false,
        displayBrightness: Float = 1,
        powerProfile: String = "automatic",
    ) -> PlaybackPolicy.Decision {
        PlaybackPolicy.decide(
            presentationMode: presentationMode, activityState: activityState, userPaused: userPaused,
            alwaysPauseDesktop: alwaysPauseDesktop, pauseWhenOccluded: true, desktopOccluded: occluded,
            displayHasFullscreenApp: fullscreen, screenSaverIsOurs: false,
            thermalState: thermalState, isOnBattery: isOnBattery, batteryLevel: batteryLevel,
            isGameModeActive: isGameModeActive, isLowPowerModeEnabled: isLowPowerModeEnabled,
            displayBrightness: displayBrightness, powerProfile: powerProfile,
        )
    }

    func testNothingInTheWayHasNoReason() {
        XCTAssertEqual(decide(), PlaybackPolicy.Decision(tier: .full, reason: nil))
    }

    func testEachPauseNamesItsReason() {
        XCTAssertEqual(decide(userPaused: true).reason, .userPause)
        XCTAssertEqual(decide(occluded: true).reason, .covered)
        XCTAssertEqual(decide(fullscreen: true).reason, .fullscreenApp)
        XCTAssertEqual(decide(isGameModeActive: true).reason, .gameMode)
        XCTAssertEqual(decide(displayBrightness: 0).reason, .displayDimmed)
        XCTAssertEqual(decide(thermalState: .critical).reason, .thermal)
        XCTAssertEqual(decide(isOnBattery: true, batteryLevel: 5).reason, .batteryCritical)
        XCTAssertEqual(decide(activityState: "suspended").reason, .suspended)
        XCTAssertEqual(decide(presentationMode: "idle").reason, .screensaver)
        XCTAssertEqual(decide(alwaysPauseDesktop: true).reason, .desktopPaused)
        XCTAssertEqual(decide(isOnBattery: true, powerProfile: "staticOnBattery").reason, .batteryStatic)
        for pause in [decide(userPaused: true), decide(occluded: true), decide(isGameModeActive: true)] {
            XCTAssertEqual(pause.tier, .paused)
        }
    }

    func testLockedDesktopOnlyPlaysWithoutAReason() {
        XCTAssertEqual(decide(alwaysPauseDesktop: true, presentationMode: "locked"), .init(tier: .full, reason: nil))
    }

    func testLighterTiersNameTheirReason() {
        XCTAssertEqual(decide(isOnBattery: true), .init(tier: .reduced, reason: .batteryTier))
        XCTAssertEqual(decide(isOnBattery: true, batteryLevel: 15), .init(tier: .minimal, reason: .batteryTier))
        XCTAssertEqual(decide(powerProfile: "batterySaver"), .init(tier: .minimal, reason: .batteryTier))
        XCTAssertEqual(decide(isLowPowerModeEnabled: true), .init(tier: .minimal, reason: .lowPowerMode))
        XCTAssertEqual(decide(thermalState: .serious), .init(tier: .minimal, reason: .thermal))
        XCTAssertEqual(decide(thermalState: .fair), .init(tier: .reduced, reason: .thermal))
    }

    func testTheReasonBehindTheStrictestTierWins() {
        // On battery (reduced) and covered (paused): the pause is why it stopped.
        XCTAssertEqual(decide(occluded: true, isOnBattery: true), .init(tier: .paused, reason: .covered))
        // Serious heat (minimal) beats plain battery (reduced).
        XCTAssertEqual(decide(thermalState: .serious, isOnBattery: true), .init(tier: .minimal, reason: .thermal))
    }

    func testComputeAgreesWithDecide() {
        XCTAssertEqual(
            PlaybackPolicy.compute(
                presentationMode: "default", activityState: "active", userPaused: false,
                alwaysPauseDesktop: false, pauseWhenOccluded: true, desktopOccluded: true,
                screenSaverIsOurs: false, thermalState: .nominal, isOnBattery: false,
                batteryLevel: 100, isGameModeActive: false),
            .paused)
    }
}
