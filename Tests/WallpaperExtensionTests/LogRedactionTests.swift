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
}
