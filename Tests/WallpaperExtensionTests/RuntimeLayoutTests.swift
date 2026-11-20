import Foundation
import XCTest

/// Writes into private WallpaperExtensionKit objects go through a slot
/// that was checked against the live class, never a fixed offset (#68 S14).
final class RuntimeLayoutTests: XCTestCase {
    func testFindsANamedIvarThatFitsTheValue() throws {
        let slot = try XCTUnwrap(RuntimeLayout.ivarSlot(named: "box", in: FakeRemoteContext.self, bytes: 4))
        XCTAssertGreaterThanOrEqual(slot, class_getInstanceSize(NSObject.self))
    }

    func testAMissingIvarHasNoSlot() {
        // The old code fell back to offset 8 here.
        XCTAssertNil(RuntimeLayout.ivarSlot(named: "box", in: NSObject.self, bytes: 4))
    }

    func testAValueTooLargeForTheInstanceHasNoSlot() {
        XCTAssertNil(RuntimeLayout.ivarSlot(named: "box", in: FakeRemoteContext.self, bytes: 64))
    }

    func testClassSelectorsAreCheckedBeforeUse() {
        XCTAssertTrue(RuntimeLayout.respondsToClassSelector(NSObject.self, "new"))
        XCTAssertFalse(RuntimeLayout.respondsToClassSelector(NSObject.self, "remoteContextWithOptions:"))
    }
}

/// Shaped like WallpaperRemoteContextXPC on macOS 27.2: one 8-byte ivar
/// named `box` after the isa, 16 bytes in all.
private final class FakeRemoteContext: NSObject {
    @objc var box: Int = 0
}
