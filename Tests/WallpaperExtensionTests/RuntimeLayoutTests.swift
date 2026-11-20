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

    func testAClassWithAnotherIvarIsRefused() {
        // Only the verified shape is written into: one ivar after the isa.
        XCTAssertNil(RuntimeLayout.ivarSlot(named: "box", in: FakeShiftedContext.self, bytes: 8))
    }

    func testAWriteThatWouldSpillIntoTheNextFieldHasNoSlot() {
        // A 4-byte `rawValue` followed by another field: an 8-byte pointer
        // fits in the instance but would overwrite `next`.
        XCTAssertNil(RuntimeLayout.ivarSlot(named: "rawValue", in: FakeNarrowSnapshot.self, bytes: 8))
    }

    func testAnInheritedIvarIsRefused() {
        // The superclass's neighbours aren't in the subclass's ivar list.
        XCTAssertNil(RuntimeLayout.ivarSlot(named: "box", in: FakeSubclassedContext.self, bytes: 4))
    }

    func testAnIvarWithAnotherNameIsRefused() {
        XCTAssertNil(RuntimeLayout.ivarSlot(named: "rawValue", in: FakeRemoteContext.self, bytes: 4))
    }

    func testTheLiveWallpaperClassesHaveTheSlotsTheWritesNeed() throws {
        // The same checks as RuntimeHelpers, against this OS's framework.
        let path = "/System/Library/PrivateFrameworks/WallpaperExtensionKit.framework/WallpaperExtensionKit"
        try XCTSkipIf(dlopen(path, RTLD_LAZY) == nil, "no WallpaperExtensionKit here")
        let context: AnyClass = try XCTUnwrap(objc_getClass("WallpaperRemoteContextXPC") as? AnyClass)
        let snapshot: AnyClass = try XCTUnwrap(objc_getClass("WallpaperSnapshotXPC") as? AnyClass)
        XCTAssertNotNil(RuntimeLayout.ivarSlot(named: "box", in: context, bytes: MemoryLayout<UInt32>.size))
        XCTAssertNotNil(RuntimeLayout.ivarSlot(named: "rawValue", in: snapshot, bytes: MemoryLayout<UnsafeRawPointer>.size))
        let caContext: AnyClass = try XCTUnwrap(NSClassFromString("CAContext"))
        XCTAssertTrue(RuntimeLayout.respondsToClassSelector(caContext, "remoteContext"))
        XCTAssertTrue(RuntimeLayout.respondsToClassSelector(caContext, "remoteContextWithOptions:"))
    }

    func testClassSelectorsAreCheckedBeforeUse() {
        XCTAssertTrue(RuntimeLayout.respondsToClassSelector(NSObject.self, "new"))
        XCTAssertFalse(RuntimeLayout.respondsToClassSelector(NSObject.self, "remoteContextWithOptions:"))
    }

    func testInstanceSelectorsAreCheckedBeforeUse() {
        XCTAssertTrue(RuntimeLayout.responds(FakeRemoteContext(), to: ["box", "setBox:"]))
        XCTAssertFalse(RuntimeLayout.responds(FakeRemoteContext(), to: ["box", "setLayer:"]))
    }
}

/// Shaped like WallpaperRemoteContextXPC on macOS 27.2: one 8-byte ivar
/// named `box` after the isa, 16 bytes in all.
private class FakeRemoteContext: NSObject {
    @objc var box: Int = 0
}

private final class FakeShiftedContext: NSObject {
    @objc var first: Int = 0
    @objc var box: Int = 0
}

private final class FakeNarrowSnapshot: NSObject {
    @objc var rawValue: Int32 = 0
    @objc var next: Int32 = 0
}

private final class FakeSubclassedContext: FakeRemoteContext {
    @objc var extra: Int = 0
}
