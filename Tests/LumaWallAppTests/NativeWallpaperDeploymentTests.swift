import AVFoundation
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

    func testCopiesPlannedPerSourceSize() {
        let names = { (size: CGSize) in NativeWallpaperDeployment.variantSpecs(sourceSize: size, sourceFPS: 30).map(\.filename) }
        // 4K sources also get a 1440p copy at full frame rate for 1440p monitors.
        XCTAssertEqual(Set(names(CGSize(width: 3840, height: 2160))), ["Wallpaper.reduced.mov", "Wallpaper.minimal.mov", "Wallpaper.qhd.mov"])
        XCTAssertEqual(Set(names(CGSize(width: 2560, height: 1440))), ["Wallpaper.reduced.mov", "Wallpaper.minimal.mov"])
        XCTAssertEqual(names(CGSize(width: 1920, height: 1080)), ["Wallpaper.minimal.mov"])
        XCTAssertEqual(names(CGSize(width: 1280, height: 720)), [])
    }

    func testQHDCopyKeepsTheSourceAspect() {
        let qhd = NativeWallpaperDeployment.variantSpecs(sourceSize: CGSize(width: 4096, height: 2304), sourceFPS: 60).first { $0.filename == "Wallpaper.qhd.mov" }
        XCTAssertEqual(qhd?.fitting, CGSize(width: 2560, height: 1440))
        let portrait = NativeWallpaperDeployment.variantSpecs(sourceSize: CGSize(width: 2160, height: 3840), sourceFPS: 60).first { $0.filename == "Wallpaper.qhd.mov" }
        XCTAssertEqual(portrait?.fitting, CGSize(width: 1440, height: 2560))
    }

    func testBatteryCopiesAreCappedAt30FPS() {
        // 60 fps battery copies decoded and redrew twice as often as needed.
        func rates(_ fps: Double) -> [String: Double] {
            Dictionary(uniqueKeysWithValues: NativeWallpaperDeployment
                .variantSpecs(sourceSize: CGSize(width: 3840, height: 2160), sourceFPS: fps)
                .map { ($0.filename, $0.fps) })
        }
        XCTAssertEqual(rates(60), ["Wallpaper.reduced.mov": 30, "Wallpaper.minimal.mov": 30, "Wallpaper.qhd.mov": 60])
        // Whole divisors keep frames evenly spaced: 59.94 halves to 29.97.
        XCTAssertEqual(rates(59.94)["Wallpaper.minimal.mov"] ?? 0, 29.97, accuracy: 0.001)
        XCTAssertEqual(rates(120)["Wallpaper.reduced.mov"], 30)
        XCTAssertEqual(rates(24)["Wallpaper.reduced.mov"], 24)
        XCTAssertEqual(rates(30)["Wallpaper.minimal.mov"], 30)
    }

    func testConcurrentCopiesAreMergedNotOverwritten() {
        // Two workers each wrote the list they started with, so the last
        // writer dropped the other's copy from metadata.json.
        let reduced = NativeWallpaperDeployment.NativeVideoVariant(filename: "Wallpaper.reduced.mov", fps: 60, resolution: CGSize(width: 1920, height: 1080))
        let minimal = NativeWallpaperDeployment.NativeVideoVariant(filename: "Wallpaper.minimal.mov", fps: 60, resolution: CGSize(width: 1280, height: 720))
        let merged = NativeWallpaperDeployment.merging([minimal], with: [reduced])
        XCTAssertEqual(Set(merged.map(\.filename)), ["Wallpaper.reduced.mov", "Wallpaper.minimal.mov"])
        let replaced = NativeWallpaperDeployment.merging([reduced], with: [NativeWallpaperDeployment.NativeVideoVariant(filename: "Wallpaper.reduced.mov", fps: 30, resolution: reduced.resolution)])
        XCTAssertEqual(replaced.count, 1)
        XCTAssertEqual(replaced.first?.fps, 30)
    }

    func testEntryMissingAnyPlannedCopyNeedsBackfill() {
        let entry = NativeWallpaperDeployment.EntryInfo(
            id: UUID().uuidString, name: "x", filename: "Wallpaper.mp4", duration: 5, fps: 60,
            resolution: CGSize(width: 3840, height: 2160), dateAdded: Date(), variants: variants
        )
        // Has 1080p and 720p, not the 1440p copy added later.
        XCTAssertTrue(NativeWallpaperDeployment.needsVariants(entry, fileExists: { _ in true }))
        var complete = entry
        complete.variants = variants + [.init(filename: "Wallpaper.qhd.mov", fps: 60, resolution: CGSize(width: 2560, height: 1440))]
        XCTAssertFalse(NativeWallpaperDeployment.needsVariants(complete, fileExists: { _ in true }))
        // A battery copy made at 60 fps before the 30 fps cap: re-encode it.
        var stale = complete
        stale.variants = [.init(filename: "Wallpaper.reduced.mov", fps: 60, resolution: CGSize(width: 1920, height: 1080))] + variants.dropFirst()
            + [.init(filename: "Wallpaper.qhd.mov", fps: 60, resolution: CGSize(width: 2560, height: 1440))]
        XCTAssertTrue(NativeWallpaperDeployment.needsVariants(stale, fileExists: { _ in true }))
        // Listed in metadata but deleted from disk: repair it.
        XCTAssertTrue(NativeWallpaperDeployment.needsVariants(complete, fileExists: { $0 != "Wallpaper.qhd.mov" }))
    }

    func testCopyFrameDurationKeepsTheSourceCadence() {
        let duration = NativeWallpaperDeployment.copyFrameDuration(nominalFPS:)
        // NTSC rates stay exact; rounding 59.94 to 60 repeats a frame every ~17 s.
        XCTAssertEqual(duration(59.94), CMTime(value: 1001, timescale: 60_000))
        XCTAssertEqual(duration(29.97), CMTime(value: 1001, timescale: 30_000))
        XCTAssertEqual(duration(23.976), CMTime(value: 1001, timescale: 24_000))
        XCTAssertEqual(duration(60), CMTime(value: 1, timescale: 60))
        // Irregular sources (29.75 nominal, 204 frames in 6.79 s) round to the
        // nearest whole rate; the shortest frame gap gave one extra frame.
        XCTAssertEqual(duration(29.75), CMTime(value: 1, timescale: 30))
    }
}
