import AppKit
import SwiftUI
import XCTest

@testable import LumaWall

final class AboutInfoTests: XCTestCase {
    func testAppBundleShipsLicenseNoticesAndPrivacyManifest() throws {
        let bundle = Bundle.main
        XCTAssertNotNil(bundle.url(forResource: "LICENSE", withExtension: nil))
        XCTAssertNotNil(bundle.url(forResource: "NOTICE", withExtension: nil))
        XCTAssertNotNil(bundle.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md"))

        let manifestURL = try XCTUnwrap(bundle.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        let manifest = try loadPrivacyManifest(at: manifestURL)
        assertValidPrivacyManifest(manifest)
    }

    func testExtensionBundleShipsNoticesAndPrivacyManifest() throws {
        let appexURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Extensions/LumaWallWallpaper.appex", isDirectory: true)
        guard let extensionBundle = Bundle(url: appexURL) else {
            XCTFail("Expected embedded wallpaper extension at \(appexURL.path)")
            return
        }
        XCTAssertNotNil(extensionBundle.url(forResource: "NOTICE", withExtension: nil))
        XCTAssertNotNil(extensionBundle.url(forResource: "LICENSE-Phosphene", withExtension: nil))

        let manifestURL = try XCTUnwrap(extensionBundle.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        let manifest = try loadPrivacyManifest(at: manifestURL)
        assertValidPrivacyManifest(manifest)
    }

    func testInfoPlistDeclaresExportComplianceAndLocationUsage() {
        let info = Bundle.main.infoDictionary ?? [:]
        XCTAssertEqual(info["ITSAppUsesNonExemptEncryption"] as? Bool, false)
        let usage = info["NSLocationUsageDescription"] as? String ?? ""
        XCTAssertFalse(usage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func testAboutInfoLoadsBundleMetadataAndNotices() {
        let info = AboutInfo.load(from: .main)
        XCTAssertEqual(info.appName, "LumaWall")
        XCTAssertFalse(info.version.isEmpty)
        XCTAssertFalse(info.build.isEmpty)
        XCTAssertFalse(info.licenseName.isEmpty)
        XCTAssertTrue(info.acknowledgements.contains("Phosphene"))
    }

    func testLicenseNameDetectsApacheAndMIT() {
        let apache = """
                                         Apache License
                                   Version 2.0, January 2004
                                http://www.apache.org/licenses/
            """
        XCTAssertEqual(AboutInfo.licenseName(from: apache), "Apache License 2.0")
        XCTAssertEqual(AboutInfo.licenseName(from: "MIT License\n\nCopyright (c) 2026"), "MIT License")
        XCTAssertEqual(AboutInfo.licenseName(from: nil), "Apache License 2.0")
    }

    func testAboutLinksTargetExpectedGitHubPages() {
        XCTAssertEqual(AboutLinks.privacy.absoluteString, "https://github.com/Luseefor/LumaWall/blob/main/PRIVACY.md")
        XCTAssertEqual(AboutLinks.terms.absoluteString, "https://github.com/Luseefor/LumaWall/blob/main/TERMS.md")
        XCTAssertEqual(AboutLinks.security.absoluteString, "https://github.com/Luseefor/LumaWall/blob/main/SECURITY.md")
        XCTAssertEqual(AboutLinks.releases.absoluteString, "https://github.com/Luseefor/LumaWall/releases")
    }

    @MainActor
    func testAboutViewRendersOffscreen() throws {
        let hosting = NSHostingView(rootView: AboutView(info: .load(from: .main)))
        hosting.appearance = NSAppearance(named: .darkAqua)
        hosting.frame = NSRect(x: 0, y: 0, width: 480, height: 560)
        hosting.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        XCTAssertGreaterThan(rep.pixelsWide, 0)
        XCTAssertGreaterThan(rep.pixelsHigh, 0)
    }

    private func loadPrivacyManifest(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(plist as? [String: Any])
    }

    private func assertValidPrivacyManifest(_ manifest: [String: Any]) {
        XCTAssertEqual(manifest["NSPrivacyTracking"] as? Bool, false)
        XCTAssertEqual((manifest["NSPrivacyTrackingDomains"] as? [Any])?.isEmpty, true)
        XCTAssertEqual((manifest["NSPrivacyCollectedDataTypes"] as? [Any])?.isEmpty, true)

        let apiTypes = manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]] ?? []
        let reasonsByCategory = Dictionary(
            uniqueKeysWithValues: apiTypes.compactMap { entry -> (String, [String])? in
                guard let category = entry["NSPrivacyAccessedAPIType"] as? String,
                    let reasons = entry["NSPrivacyAccessedAPITypeReasons"] as? [String]
                else { return nil }
                return (category, reasons)
            }
        )
        XCTAssertEqual(reasonsByCategory["NSPrivacyAccessedAPICategoryUserDefaults"], ["CA92.1"])
        XCTAssertEqual(reasonsByCategory["NSPrivacyAccessedAPICategoryFileTimestamp"], ["C617.1"])
    }
}
