import Foundation
import XCTest

@testable import LumaWall

final class LogRedactionTests: XCTestCase {
    func testThePublicPartOfAnErrorNamesNoFile() {
        // Errors were logged `.public` whole, file paths included.
        let error = CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: "/Users/someone/Movies/Holiday.mov"])
        let code = LogRedaction.code(of: error)
        XCTAssertEqual(code, "domain=NSCocoaErrorDomain code=257")
        XCTAssertFalse(code.contains("Holiday"))
    }
}
