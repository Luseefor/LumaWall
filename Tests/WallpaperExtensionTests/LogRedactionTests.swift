import Foundation
import XCTest

/// extension.log never records the account name (#68 S15).
final class LogRedactionTests: XCTestCase {
    func testAHomePathLosesTheAccountName() {
        XCTAssertEqual(
            LogRedaction.redact("files: [file:///Users/alice/Library/Containers/x/Data/Documents/videos/ID/Wallpaper.mp4]"),
            "files: [file://~/Library/Containers/x/Data/Documents/videos/ID/Wallpaper.mp4]")
    }

    func testEveryPathInALineIsRedacted() {
        XCTAssertEqual(
            LogRedaction.redact(#"NSFilePath=/Users/bob/a.mov, NSURL=file:///Users/bob/a.mov"#),
            "NSFilePath=~/a.mov, NSURL=file://~/a.mov")
    }

    func testAHomeDirectoryOnItsOwnIsRedacted() {
        XCTAssertEqual(LogRedaction.redact("home is /Users/alice"), "home is ~")
        XCTAssertEqual(LogRedaction.redact(#"path "/Users/alice""#), #"path "~""#)
    }

    func testSharedAndOtherPathsAreKept() {
        XCTAssertEqual(LogRedaction.redact("/Users/Shared/clip.mov"), "/Users/Shared/clip.mov")
        XCTAssertEqual(LogRedaction.redact("/System/Library/CoreServices"), "/System/Library/CoreServices")
        XCTAssertEqual(LogRedaction.redact("[applyPolicy #1] paused → full"), "[applyPolicy #1] paused → full")
    }

    func testOnlyTheExactSharedFolderIsKept() {
        XCTAssertEqual(LogRedaction.redact("/Users/Shared-admin/clip.mov"), "~/clip.mov")
        XCTAssertEqual(LogRedaction.redact("/Users/Shared"), "/Users/Shared")
    }

    func testPercentEncodedAndTildeHomesAreRedacted() {
        XCTAssertEqual(LogRedaction.redact("path=%2FUsers%2Falice%2Fclip.mov"), "path=~%2Fclip.mov")
        XCTAssertEqual(LogRedaction.redact("open ~alice/clip.mov"), "open ~/clip.mov")
        XCTAssertEqual(LogRedaction.redact("open ~/clip.mov"), "open ~/clip.mov")
    }

    func testAHomeOutsideUsersIsRedactedWhenKnown() {
        XCTAssertEqual(LogRedaction.redact("file:///private/var/alice/clip.mov", home: "/private/var/alice"), "file://~/clip.mov")
    }

    func testAHomeOutsideUsersIsRedactedOnlyAsAWholeComponent() {
        let home = "/Volumes/Homes/alice"
        XCTAssertEqual(LogRedaction.redact("/Volumes/Homes/alice-backup/clip.mov", home: home), "/Volumes/Homes/alice-backup/clip.mov")
        XCTAssertEqual(LogRedaction.redact("at /Volumes/Homes/alice", home: home), "at ~")
    }

    func testAPercentEncodedHomeOutsideUsersIsRedacted() {
        XCTAssertEqual(
            LogRedaction.redact("file:///Volumes/Staff%20Homes/alice/clip.mov", home: "/Volumes/Staff Homes/alice"),
            "file://~/clip.mov")
    }

    // MARK: File labels

    func testAppNamedLibraryFilesKeepTheirNames() {
        for name in ["Wallpaper.mp4", "Wallpaper.qhd.mov", "Wallpaper.reduced.mov", "Wallpaper.battery.mov"] {
            XCTAssertEqual(LogRedaction.fileLabel(URL(fileURLWithPath: "/x/videos/ID/\(name)")), name)
        }
    }

    func testACustomNameThatStartsLikeTheAppsIsStillHidden() {
        let url = URL(fileURLWithPath: "/x/videos/5C99B113-4BED-4EB9-9219-24B3E7E6169C/Wallpaper.PrivateShoot.mov")
        XCTAssertEqual(LogRedaction.fileLabel(url), "5C99B113-4BED-4EB9-9219-24B3E7E6169C/video.mov")
    }

    func testAnyOtherFileIsNamedByItsEntry() {
        let url = URL(fileURLWithPath: "/x/videos/5C99B113-4BED-4EB9-9219-24B3E7E6169C/Private Shoot.mov")
        XCTAssertEqual(LogRedaction.fileLabel(url), "5C99B113-4BED-4EB9-9219-24B3E7E6169C/video.mov")
    }

    func testAFileOutsideAnEntryIsNamedByItsExtension() {
        XCTAssertEqual(LogRedaction.fileLabel(URL(fileURLWithPath: "/Users/alice/Movies/Holiday.mp4")), "video.mp4")
    }

    // MARK: Errors

    func testAFileErrorLogsItsDomainAndCodeOnly() {
        let error = NSError(
            domain: NSCocoaErrorDomain, code: 260,
            userInfo: [NSFilePathErrorKey: "/Users/alice/Private/clip.mov", NSLocalizedDescriptionKey: "clip.mov is missing"])
        XCTAssertEqual(LogRedaction.describe(error), "NSCocoaErrorDomain 260")
    }
}
