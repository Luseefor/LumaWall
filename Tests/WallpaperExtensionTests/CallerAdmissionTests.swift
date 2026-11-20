import Security
import XCTest

/// Only Apple's wallpaper hosts may drive the extension over XPC (#68 S2).
final class CallerAdmissionTests: XCTestCase {
    func testRejectsAPeerWhoseIdentityCantBeRead() {
        XCTAssertEqual(
            CallerAdmission.verdict(for: .unidentified("no audit token")),
            .rejected("no audit token"))
    }

    func testAcceptsTheRealWallpaperAgent() throws {
        let peer = try staticPeer("/System/Library/CoreServices/WallpaperAgent.app")
        XCTAssertEqual(CallerAdmission.verdict(for: peer), .accepted("WallpaperAgent"))
    }

    func testAcceptsTheSystemSettingsWallpaperPane() throws {
        let peer = try staticPeer("/System/Library/ExtensionKit/Extensions/Wallpaper.appex")
        XCTAssertEqual(CallerAdmission.verdict(for: peer), .accepted("Wallpaper settings"))
    }

    func testAcceptsSystemSettings() throws {
        let peer = try staticPeer("/System/Applications/System Settings.app")
        XCTAssertEqual(CallerAdmission.verdict(for: peer), .accepted("System Settings"))
    }

    func testRejectsAnotherAppleSignedApp() throws {
        // Calculator passes `anchor apple`, which used to be enough.
        let peer = try staticPeer("/System/Applications/Calculator.app")
        XCTAssertEqual(
            CallerAdmission.verdict(for: peer),
            .rejected("signature matches no wallpaper host"))
    }

    func testRejectsAPeerThatSatisfiesNoRequirement() {
        XCTAssertEqual(
            CallerAdmission.verdict(for: .signed { _ in false }),
            .rejected("signature matches no wallpaper host"))
    }

    func testEveryHostRequirementPinsAnIdentifierAndApplesAnchor() {
        for host in CallerAdmission.hosts {
            XCTAssertTrue(host.requirement.hasPrefix("identifier \"com.apple."), host.name)
            XCTAssertTrue(host.requirement.hasSuffix("\" and anchor apple"), host.name)
        }
    }

    func testAnUnbuildableRequirementDoesNotMatch() {
        XCTAssertFalse(CallerAdmission.satisfies(requirement: "not a requirement (") { _ in errSecSuccess })
    }

    /// A peer backed by the code signature of a bundle on disk, checked the
    /// same way the extension checks a live connection.
    private func staticPeer(_ path: String) throws -> CallerPeer {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path), "\(path) isn't on this OS")
        var code: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code)
        guard status == errSecSuccess, let code else {
            throw XCTSkip("can't read the signature of \(path) (\(status))")
        }
        return .signed { text in
            CallerAdmission.satisfies(requirement: text) {
                SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSBasicValidateOnly), $0)
            }
        }
    }
}
