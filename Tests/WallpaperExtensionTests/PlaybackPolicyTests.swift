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
}
