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
            .rejected("signature matches no wallpaper host (status \(errSecCSReqFailed))"))
    }

    func testRejectsAPeerThatSatisfiesNoRequirement() {
        XCTAssertEqual(
            CallerAdmission.verdict(for: .signed { _ in errSecCSReqFailed }),
            .rejected("signature matches no wallpaper host (status \(errSecCSReqFailed))"))
    }

    func testEveryHostRequirementPinsAnIdentifierAndApplesAnchor() {
        for host in CallerAdmission.hosts {
            XCTAssertTrue(host.requirement.hasPrefix("identifier \"com.apple."), host.name)
            XCTAssertTrue(host.requirement.hasSuffix("\" and anchor apple"), host.name)
        }
    }

    func testAnUnbuildableRequirementDoesNotMatch() {
        XCTAssertNotEqual(CallerAdmission.status(ofRequirement: "not a requirement (") { _ in errSecSuccess }, errSecSuccess)
    }

    func testAFailedGuestLookupLeavesThePeerUnidentified() {
        let peer = CallerAdmission.peer { (errSecCSNoSuchCode, nil) }
        XCTAssertEqual(
            CallerAdmission.verdict(for: peer),
            .rejected("could not derive peer SecCode (status \(errSecCSNoSuchCode))"))
    }

    func testAcceptsTheRunningWallpaperAgentAsALiveGuest() throws {
        // The same guest lookup and validity check a connection gets, by PID
        // instead of audit token. Needs WallpaperAgent running (a logged-in
        // session), so CI runners without one skip it.
        let pids = try runningPIDs(named: "WallpaperAgent")
        let pid = try XCTUnwrap(pids.first)
        let peer = CallerAdmission.peer {
            var code: SecCode?
            let status = SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: pid] as CFDictionary, [], &code)
            return (status, code)
        }
        XCTAssertEqual(CallerAdmission.verdict(for: peer), .accepted("WallpaperAgent"))
    }

    func testRejectsTheTestRunnerAsALiveGuest() {
        let peer = CallerAdmission.peer {
            var code: SecCode?
            return (SecCodeCopySelf([], &code), code)
        }
        // xctest is Apple-signed, so every host requirement fails as a plain
        // mismatch rather than a signature error.
        XCTAssertEqual(
            CallerAdmission.verdict(for: peer),
            .rejected("signature matches no wallpaper host (status \(errSecCSReqFailed))"))
    }

    private func runningPIDs(named name: String) throws -> [Int32] {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-x", name]
        let out = Pipe()
        pgrep.standardOutput = out
        try pgrep.run()
        pgrep.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        // pgrep exits 1 for no match and 2 or more when it couldn't look.
        try XCTSkipIf(pgrep.terminationStatus == 1, "\(name) isn't running here")
        XCTAssertEqual(pgrep.terminationStatus, 0, "pgrep failed")
        return text.split(separator: "\n").compactMap { Int32($0) }
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
            CallerAdmission.status(ofRequirement: text) {
                SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSBasicValidateOnly), $0)
            }
        }
    }
}
