import Foundation
import XCTest

/// "Add Video" and "Manage Library" open the companion app itself, found
/// next to the extension and checked by signature, instead of a URL scheme
/// another app could claim (#68 S12).
final class CompanionLaunchTests: XCTestCase {
    func testTheCompanionIsTheAppThatContainsTheExtension() {
        let appex = URL(fileURLWithPath: "/Applications/LumaWall.app/Contents/Extensions/LumaWallWallpaper.appex")
        XCTAssertEqual(CompanionLaunch.containingApp(of: appex)?.path, "/Applications/LumaWall.app")
    }

    func testAnExtensionOutsideAnAppHasNoCompanion() {
        XCTAssertNil(CompanionLaunch.containingApp(of: URL(fileURLWithPath: "/tmp/LumaWallWallpaper.appex")))
        XCTAssertNil(
            CompanionLaunch.containingApp(of: URL(fileURLWithPath: "/Applications/LumaWall.app/Contents/PlugIns/X.appex")))
    }

    func testTheRequirementPinsTheIdentifierAndTeam() {
        XCTAssertEqual(
            CompanionLaunch.requirement(identifier: "app.lumawall.personal", teamID: "ABCDE12345"),
            #"identifier "app.lumawall.personal" and anchor apple generic and certificate leaf[subject.OU] = "ABCDE12345""#)
    }

    func testNoRequirementWithoutATeam() {
        // An ad hoc signed extension has no team to match the app against.
        XCTAssertNil(CompanionLaunch.requirement(identifier: "app.lumawall.personal", teamID: nil))
        XCTAssertNil(CompanionLaunch.requirement(identifier: "app.lumawall.personal", teamID: ""))
        XCTAssertNil(CompanionLaunch.requirement(identifier: "app.lumawall.personal", teamID: #"X" or anchor apple"#))
    }

    func testAnAppFromAnotherTeamIsRefused() throws {
        let calculator = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: calculator.path))
        let requirement = try XCTUnwrap(CompanionLaunch.requirement(identifier: "com.apple.calculator", teamID: "ABCDE12345"))
        XCTAssertFalse(CompanionLaunch.isSigned(calculator, satisfying: requirement))
    }

    func testAMissingAppIsRefused() throws {
        let requirement = try XCTUnwrap(CompanionLaunch.requirement(identifier: "app.lumawall.personal", teamID: "ABCDE12345"))
        XCTAssertFalse(CompanionLaunch.isSigned(URL(fileURLWithPath: "/nonexistent/LumaWall.app"), satisfying: requirement))
    }

    func testTheCompanionIdentifierComesFromTheExtensions() {
        XCTAssertEqual(CompanionLaunch.companionIdentifier(forExtension: "app.lumawall.personal.wallpaper"), "app.lumawall.personal")
        XCTAssertNil(CompanionLaunch.companionIdentifier(forExtension: "app.lumawall.personal"))
    }

    func testOnlyTheLibraryActionsLaunchTheCompanion() {
        XCTAssertTrue(CompanionLaunch.launchesCompanion("add-video"))
        XCTAssertTrue(CompanionLaunch.launchesCompanion("manage-library"))
        XCTAssertFalse(CompanionLaunch.launchesCompanion("lumawall://add-video"))
        XCTAssertFalse(CompanionLaunch.launchesCompanion("open-anything"))
    }
}
