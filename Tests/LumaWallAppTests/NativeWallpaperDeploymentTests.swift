import Foundation
import XCTest
@testable import LumaWall

final class NativeWallpaperDeploymentTests: XCTestCase {
    func testUnreadableMetadataThrowsInsteadOfTreatingDeploymentAsMissing() throws {
        let fm = FileManager.default
        let videos = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let id = UUID().uuidString
        let directory = videos.appendingPathComponent(id)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let metadata = directory.appendingPathComponent("metadata.json")
        try Data("{}".utf8).write(to: metadata)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: metadata.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadata.path)
            try? fm.removeItem(at: videos)
        }

        XCTAssertThrowsError(try NativeWallpaperDeployment.entry(id: id, videosFolderURL: videos)) {
            XCTAssertEqual(($0 as NSError).code, CocoaError.fileReadNoPermission.rawValue)
        }
        XCTAssertTrue(fm.fileExists(atPath: metadata.path))
    }

    func testMissingDeploymentCanBeCreated() throws {
        let videos = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertNil(try NativeWallpaperDeployment.entry(id: UUID().uuidString, videosFolderURL: videos))
    }

    func testProtectedContainerUsesOverlayStoragePolicy() throws {
        let fm = FileManager.default
        let documents = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: documents, withIntermediateDirectories: true)
        XCTAssertTrue(WallpaperHostCapabilities.nativeStorageIsAccessible(at: documents))
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: documents.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: documents.path)
            try? fm.removeItem(at: documents)
        }
        XCTAssertFalse(WallpaperHostCapabilities.nativeStorageIsAccessible(at: documents))
    }

    func testMissingContainerDoesNotDisableFirstDeployment() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertTrue(WallpaperHostCapabilities.nativeStorageIsAccessible(at: missing))
    }

    func testPermissionFallbackHandlesUnderlyingSystemPolicyDenialOnly() {
        let denied = NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteUnknown.rawValue,
                              userInfo: [NSUnderlyingErrorKey: denied])
        XCTAssertTrue(WallpaperHostCapabilities.isPermissionError(wrapped))
        XCTAssertFalse(WallpaperHostCapabilities.isPermissionError(
            NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteOutOfSpace.rawValue)))
    }
}
