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

    func testQHDCopyIsPlannedOnlyForDisplaysThatPlayIt() {
        // A 4K encode ran even when every display was 4K and would never play it.
        func plansQHD(_ source: CGSize, fps: Double = 60, _ displays: [CGSize]) -> Bool {
            NativeWallpaperDeployment.variantSpecs(sourceSize: source, sourceFPS: fps, displayPixels: displays)
                .contains { $0.filename == "Wallpaper.qhd.mov" }
        }
        let uhd = CGSize(width: 3840, height: 2160)
        XCTAssertFalse(plansQHD(uhd, [uhd]))
        XCTAssertFalse(plansQHD(uhd, []))
        XCTAssertTrue(plansQHD(uhd, [uhd, CGSize(width: 2560, height: 1440)]))
        XCTAssertTrue(plansQHD(uhd, [CGSize(width: 1920, height: 1080)]))
        // At 30 fps the 1080p battery copy keeps the source rate, so a 1080p
        // display plays that one and never the 1440p copy.
        XCTAssertFalse(plansQHD(uhd, fps: 30, [CGSize(width: 1920, height: 1080)]))
        XCTAssertTrue(plansQHD(uhd, fps: 30, [CGSize(width: 2560, height: 1440)]))
        // Aspect fill: a 2.39:1 source's 1440p copy is 2560x1072, too short
        // to fill a 2560x1440 display, and a portrait display needs more height.
        XCTAssertFalse(plansQHD(CGSize(width: 4096, height: 1716), [CGSize(width: 2560, height: 1440)]))
        XCTAssertFalse(plansQHD(uhd, [CGSize(width: 1440, height: 2560)]))
        // Battery copies don't depend on the displays.
        XCTAssertEqual(NativeWallpaperDeployment.variantSpecs(sourceSize: uhd, sourceFPS: 60, displayPixels: [uhd]).map(\.filename),
                       ["Wallpaper.reduced.mov", "Wallpaper.minimal.mov"])
    }

    func testCopyReadinessFollowsPlaybackPowerAndFit() {
        typealias Surface = NativeWallpaperDeployment.Surface
        let source = CGSize(width: 3840, height: 2160)
        let specs = Dictionary(uniqueKeysWithValues: NativeWallpaperDeployment.variantSpecs(sourceSize: source, sourceFPS: 60).map { ($0.filename, $0) })
        func readiness(_ filename: String, _ surfaces: [Surface], power: Bool = true) -> NativeWallpaperDeployment.VariantEncodeQueue.Readiness {
            NativeWallpaperDeployment.copyReadiness(specs[filename]!, sourceSize: source, sourceFPS: 60, surfaces: surfaces, canMakeOptionalCopies: power)
        }
        // Battery Saver plays the 720p copy, so it goes before the 1080p one.
        let saver = [Surface(pixelSize: CGSize(width: 2560, height: 1440), tier: .minimal)]
        XCTAssertEqual(readiness("Wallpaper.minimal.mov", saver), .ready(rank: 0))
        XCTAssertEqual(readiness("Wallpaper.reduced.mov", saver), .ready(rank: 1))
        XCTAssertEqual(readiness("Wallpaper.reduced.mov", [Surface(pixelSize: source, tier: .reduced)]), .ready(rank: 0))
        // The 1440p copy waits for AC, and is dropped once no surface fits it.
        XCTAssertEqual(readiness("Wallpaper.qhd.mov", saver), .ready(rank: 2))
        XCTAssertEqual(readiness("Wallpaper.qhd.mov", saver, power: false), .hold)
        XCTAssertEqual(readiness("Wallpaper.qhd.mov", [Surface(pixelSize: source, tier: .full)]), .drop)
        XCTAssertEqual(readiness("Wallpaper.qhd.mov", []), .drop)
    }

    func testNoBackfillForAQHDCopyNoDisplayPlays() {
        let entry = NativeWallpaperDeployment.EntryInfo(
            id: UUID().uuidString, name: "x", filename: "Wallpaper.mp4", duration: 5, fps: 60,
            resolution: CGSize(width: 3840, height: 2160), dateAdded: Date(), variants: variants
        )
        XCTAssertFalse(NativeWallpaperDeployment.needsVariants(entry, displayPixels: [CGSize(width: 3840, height: 2160)], fileExists: { _ in true }))
        XCTAssertTrue(NativeWallpaperDeployment.needsVariants(entry, displayPixels: [CGSize(width: 2560, height: 1440)], fileExists: { _ in true }))
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

    private let qhdDisplay = [CGSize(width: 2560, height: 1440)]

    func testEntryMissingAnyPlannedCopyNeedsBackfill() {
        let entry = NativeWallpaperDeployment.EntryInfo(
            id: UUID().uuidString, name: "x", filename: "Wallpaper.mp4", duration: 5, fps: 60,
            resolution: CGSize(width: 3840, height: 2160), dateAdded: Date(), variants: variants
        )
        // Has 1080p and 720p, not the 1440p copy added later.
        XCTAssertTrue(NativeWallpaperDeployment.needsVariants(entry, displayPixels: qhdDisplay, fileExists: { _ in true }))
        var complete = entry
        complete.variants = variants + [.init(filename: "Wallpaper.qhd.mov", fps: 60, resolution: CGSize(width: 2560, height: 1440))]
        XCTAssertFalse(NativeWallpaperDeployment.needsVariants(complete, displayPixels: qhdDisplay, fileExists: { _ in true }))
        // A battery copy made at 60 fps before the 30 fps cap: re-encode it.
        var stale = complete
        stale.variants = [.init(filename: "Wallpaper.reduced.mov", fps: 60, resolution: CGSize(width: 1920, height: 1080))] + variants.dropFirst()
            + [.init(filename: "Wallpaper.qhd.mov", fps: 60, resolution: CGSize(width: 2560, height: 1440))]
        XCTAssertTrue(NativeWallpaperDeployment.needsVariants(stale, displayPixels: qhdDisplay, fileExists: { _ in true }))
        // Listed in metadata but deleted from disk: repair it.
        XCTAssertTrue(NativeWallpaperDeployment.needsVariants(complete, displayPixels: qhdDisplay, fileExists: { $0 != "Wallpaper.qhd.mov" }))
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

final class VariantPublicationTests: XCTestCase {
    private var root: URL!
    private var videos: URL { root.appendingPathComponent("videos") }
    private var staging: URL { root.appendingPathComponent("copy-staging") }
    private let id = UUID().uuidString
    private let minimal = NativeWallpaperDeployment.variantSpecs(sourceSize: CGSize(width: 3840, height: 2160), sourceFPS: 30)
        .first { $0.filename == "Wallpaper.minimal.mov" }!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: videos.appendingPathComponent(id), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func deploy(hash: String) throws {
        let entry = NativeWallpaperDeployment.EntryInfo(
            id: id, name: "x", filename: "Wallpaper.mov", duration: 5, fps: 30,
            resolution: CGSize(width: 3840, height: 2160), dateAdded: Date(), contentHash: hash
        )
        try JSONEncoder().encode(entry).write(to: videos.appendingPathComponent(id).appendingPathComponent("metadata.json"))
    }

    private func job(hash: String) -> NativeWallpaperDeployment.VariantEncodeQueue.Job {
        .init(entryID: id, sourceURL: URL(fileURLWithPath: "/tmp/x.mov"), contentHash: hash, spec: minimal)
    }

    private func stage(_ job: NativeWallpaperDeployment.VariantEncodeQueue.Job) throws -> URL {
        let url = NativeWallpaperDeployment.stagedURL(for: job, stagingFolderURL: staging)
        try Data("copy".utf8).write(to: url)
        return url
    }

    private var dest: URL { videos.appendingPathComponent(id).appendingPathComponent(minimal.filename) }
    private let size = CGSize(width: 1280, height: 720)

    func testPublishesACopyForTheCurrentDeployment() throws {
        try deploy(hash: "aaa")
        let staged = try stage(job(hash: "aaa"))
        let result = NativeWallpaperDeployment.publish(staged, job: job(hash: "aaa"), resolution: size, videosFolderURL: videos)
        XCTAssertEqual(result, .published)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        let entry = try NativeWallpaperDeployment.entry(id: id, videosFolderURL: videos)
        XCTAssertEqual(entry?.variants?.map(\.filename), [minimal.filename])
    }

    func testCopyOfAReplacedSourceIsDiscarded() throws {
        // Jobs were keyed by entry and filename only, so a copy planned for
        // the old source could be published into the redeployed entry.
        try deploy(hash: "new")
        let staged = try stage(job(hash: "old"))
        let result = NativeWallpaperDeployment.publish(staged, job: job(hash: "old"), resolution: size, videosFolderURL: videos)
        XCTAssertEqual(result, .stale)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertNil(try NativeWallpaperDeployment.entry(id: id, videosFolderURL: videos)?.variants)
    }

    func testFailedMetadataWriteKeepsTheExportForRetry() throws {
        // A failed metadata write counted as success: the extension never
        // saw the copy and the next request encoded it again.
        try deploy(hash: "aaa")
        let staged = try stage(job(hash: "aaa"))
        let failed = NativeWallpaperDeployment.publish(staged, job: job(hash: "aaa"), resolution: size, videosFolderURL: videos,
                                                       writeMetadata: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
        XCTAssertEqual(failed, .failed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
        let retried = NativeWallpaperDeployment.publish(staged, job: job(hash: "aaa"), resolution: size, videosFolderURL: videos)
        XCTAssertEqual(retried, .published)
    }

    func testStartupCleanupRemovesAbandonedExports() throws {
        // A quit mid-export left a multi-GB temp movie that the extension's
        // recovery scan could pick as the wallpaper.
        try deploy(hash: "aaa")
        let fm = FileManager.default
        let partial = staging.appendingPathComponent("\(id).\(UUID().uuidString).partial.mov")
        let legacyTemp = videos.appendingPathComponent(id).appendingPathComponent("Wallpaper.minimal.mov.\(UUID().uuidString).tmp.mov")
        let current = try stage(job(hash: "aaa"))
        let stale = try stage(job(hash: "old"))
        for url in [partial, legacyTemp] { try Data("x".utf8).write(to: url) }
        NativeWallpaperDeployment.cleanUpAbandonedExports(videosFolderURL: videos, stagingFolderURL: staging)
        XCTAssertFalse(fm.fileExists(atPath: partial.path))
        XCTAssertFalse(fm.fileExists(atPath: legacyTemp.path))
        XCTAssertFalse(fm.fileExists(atPath: stale.path))
        XCTAssertTrue(fm.fileExists(atPath: current.path))
        XCTAssertTrue(fm.fileExists(atPath: videos.appendingPathComponent(id).appendingPathComponent("metadata.json").path))
    }
}
