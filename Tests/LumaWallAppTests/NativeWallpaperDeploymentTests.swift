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

    private let variants = [
        NativeWallpaperDeployment.NativeVideoVariant(filename: "Wallpaper.reduced.mov", fps: 30, resolution: CGSize(width: 1920, height: 1080)),
        NativeWallpaperDeployment.NativeVideoVariant(filename: "Wallpaper.minimal.mov", fps: 30, resolution: CGSize(width: 1280, height: 720)),
    ]

    func testPortraitCopyIsJudgedByWidth() {
        let portrait = [NativeWallpaperDeployment.NativeVideoVariant(filename: "Wallpaper.reduced.mov", fps: 30, resolution: CGSize(width: 1080, height: 1920))]
        XCTAssertNil(NativeWallpaperDeployment.previewVariant(portrait, minPixelWidth: 1920))
        XCTAssertEqual(NativeWallpaperDeployment.previewVariant(portrait, minPixelWidth: 640)?.filename, "Wallpaper.reduced.mov")
    }

    func testPreviewPicksSmallestCopyWideEnough() {
        // Small tiles decoded the 4K original. The 720p copy is plenty.
        XCTAssertEqual(NativeWallpaperDeployment.previewVariant(variants, minPixelWidth: 640)?.filename, "Wallpaper.minimal.mov")
        XCTAssertEqual(NativeWallpaperDeployment.previewVariant(variants, minPixelWidth: 1600)?.filename, "Wallpaper.reduced.mov")
        XCTAssertNil(NativeWallpaperDeployment.previewVariant(variants, minPixelWidth: 2560))
        XCTAssertNil(NativeWallpaperDeployment.previewVariant([], minPixelWidth: 640))
    }

    @MainActor
    func testPreviewURLUsesDeployedCopyAndFallsBack() throws {
        let fm = FileManager.default
        let videos = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: videos) }
        let id = UUID().uuidString
        let dir = videos.appendingPathComponent(id)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let entry = NativeWallpaperDeployment.EntryInfo(
            id: id, name: "x", filename: "Wallpaper.mp4", duration: 5, fps: 30,
            resolution: CGSize(width: 3840, height: 2160), dateAdded: Date(), variants: variants
        )
        try JSONEncoder().encode(entry).write(to: dir.appendingPathComponent("metadata.json"))
        try Data().write(to: dir.appendingPathComponent("Wallpaper.minimal.mov"))
        let original = URL(fileURLWithPath: "/library/original.mp4")

        let small = NativeWallpaperDeployment.previewURL(entryID: id, minPixelWidth: 640, fallback: original, videosFolderURL: videos)
        XCTAssertEqual(small.lastPathComponent, "Wallpaper.minimal.mov")
        // The reduced copy is listed but missing on disk: use the original.
        let large = NativeWallpaperDeployment.previewURL(entryID: id, minPixelWidth: 1600, fallback: original, videosFolderURL: videos)
        XCTAssertEqual(large, original)
        let unknown = NativeWallpaperDeployment.previewURL(entryID: UUID().uuidString, minPixelWidth: 640, fallback: original, videosFolderURL: videos)
        XCTAssertEqual(unknown, original)
    }
}
