import AVFoundation
import CryptoKit
import Foundation
import LumaWallCore
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
            XCTAssertEqual(($0 as? POSIXError)?.code, .EACCES)
        }
        XCTAssertTrue(fm.fileExists(atPath: metadata.path))
    }

    func testASnapshotCacheClearLeavesTheRequestFileTheExtensionChecks() throws {
        // The extension ignores clearCaches unless this file is there and fresh
        // (WallpaperExtension/NotificationGuards.swift, CacheClearRequest).
        let documents = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: documents) }

        NativeWallpaperDeployment.requestSnapshotCacheClear(documentsURL: documents, post: {})

        let request = documents.appendingPathComponent("clear-caches.request")
        let modified = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: request.path)[.modificationDate] as? Date)
        XCTAssertLessThan(abs(modified.timeIntervalSinceNow), 5)
    }

    func testTruncatedMetadataReadsAsMissingSoItCanBeRedeployed() throws {
        // A decode failure threw before staging, so applying the wallpaper
        // again could never replace the broken entry.
        let fm = FileManager.default
        let videos = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: videos) }
        let id = UUID().uuidString
        try fm.createDirectory(at: videos.appendingPathComponent(id), withIntermediateDirectories: true)
        try Data("{\"id\":\"\(id)\",\"na".utf8).write(to: videos.appendingPathComponent(id).appendingPathComponent("metadata.json"))
        XCTAssertNil(try NativeWallpaperDeployment.entry(id: id, videosFolderURL: videos))
    }

    func testOutOfRangeFrameRateInMetadataReadsAsMissing() throws {
        // A frame rate past Int's range trapped when reapply converted it.
        let fm = FileManager.default
        let videos = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: videos) }
        func read(fps: String) throws -> NativeWallpaperDeployment.EntryInfo? {
            let id = UUID().uuidString
            let dir = videos.appendingPathComponent(id)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let json = """
                {"id":"\(id)","name":"x","filename":"Wallpaper.mov","duration":5,"fps":\(fps),\
                "resolution":[3840,2160],"dateAdded":0}
                """
            try Data(json.utf8).write(to: dir.appendingPathComponent("metadata.json"))
            return try NativeWallpaperDeployment.entry(id: id, videosFolderURL: videos)
        }
        XCTAssertEqual(try read(fps: "29.97")?.fps, 29.97)
        XCTAssertEqual(try read(fps: "0")?.fps, 0)
        XCTAssertNil(try read(fps: "1e300"))
        XCTAssertNil(try read(fps: "-30"))
        XCTAssertNil(try read(fps: "1001"))
    }

    func testNonFiniteOrHugeFrameRatePlansNoCopies() {
        let uhd = CGSize(width: 3840, height: 2160)
        for fps in [Double.nan, .infinity, -.infinity, 1e300, -1, 1_001] {
            XCTAssertEqual(NativeWallpaperDeployment.variantSpecs(sourceSize: uhd, sourceFPS: fps, displayPixels: [uhd]), [], "\(fps)")
            XCTAssertEqual(NativeWallpaperDeployment.variantSpecs(sourceSize: uhd, sourceFPS: fps), [], "\(fps)")
        }
        let specs = NativeWallpaperDeployment.variantSpecs(sourceSize: uhd, sourceFPS: 60)
        XCTAssertNil(NativeWallpaperDeployment.fullQualityPick(among: specs, sourceSize: uhd, sourceFPS: .nan, display: uhd))
    }

    func testDefaultDeployStagingIsOnTheVideosVolumeAndFresh() throws {
        let fm = FileManager.default
        let videos = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: videos, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: videos) }
        let first = try NativeWallpaperDeployment.makeStagingFolder(appropriateFor: videos)
        let second = try NativeWallpaperDeployment.makeStagingFolder(appropriateFor: videos)
        defer { for url in [first, second] { try? fm.removeItem(at: url) } }
        XCTAssertNotEqual(first, second)
        var a = stat()
        var b = stat()
        XCTAssertEqual(stat(first.path, &a), 0)
        XCTAssertEqual(stat(videos.path, &b), 0)
        XCTAssertEqual(a.st_dev, b.st_dev)
        XCTAssertFalse(first.path.hasPrefix(videos.path))
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
        let wrapped = NSError(
            domain: NSCocoaErrorDomain, code: CocoaError.fileWriteUnknown.rawValue,
            userInfo: [NSUnderlyingErrorKey: denied])
        XCTAssertTrue(WallpaperHostCapabilities.isPermissionError(wrapped))
        XCTAssertFalse(
            WallpaperHostCapabilities.isPermissionError(
                NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteOutOfSpace.rawValue)))
    }

    private let variants = [
        NativeWallpaperDeployment.NativeVideoVariant(
            filename: "Wallpaper.reduced.mov", fps: 30, resolution: CGSize(width: 1920, height: 1080)),
        NativeWallpaperDeployment.NativeVideoVariant(
            filename: "Wallpaper.minimal.mov", fps: 30, resolution: CGSize(width: 1280, height: 720)),
    ]

    func testPortraitCopyIsJudgedByWidth() {
        let portrait = [
            NativeWallpaperDeployment.NativeVideoVariant(
                filename: "Wallpaper.reduced.mov", fps: 30, resolution: CGSize(width: 1080, height: 1920))
        ]
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
        let unknown = NativeWallpaperDeployment.previewURL(
            entryID: UUID().uuidString, minPixelWidth: 640, fallback: original, videosFolderURL: videos)
        XCTAssertEqual(unknown, original)
    }

    func testDecodedEntryMustMatchItsFolderAndUseSafeNames() throws {
        // IDs and filenames from metadata.json were trusted as written, and
        // the extension's container is writable by the extension.
        let fm = FileManager.default
        let videos = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: videos) }
        func write(_ entry: NativeWallpaperDeployment.EntryInfo, in id: String) throws {
            let dir = videos.appendingPathComponent(id)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try JSONEncoder().encode(entry).write(to: dir.appendingPathComponent("metadata.json"))
        }
        func entry(id: String, filename: String, variants: [NativeWallpaperDeployment.NativeVideoVariant]? = nil)
            -> NativeWallpaperDeployment.EntryInfo
        {
            .init(
                id: id, name: "x", filename: filename, duration: 5, fps: 30,
                resolution: CGSize(width: 3840, height: 2160), dateAdded: Date(), variants: variants)
        }
        let borrowed = UUID().uuidString
        try write(entry(id: UUID().uuidString, filename: "Wallpaper.mov"), in: borrowed)
        XCTAssertNil(try NativeWallpaperDeployment.entry(id: borrowed, videosFolderURL: videos))

        let escaping = UUID().uuidString
        try write(entry(id: escaping, filename: "../../Documents/thesis.pages"), in: escaping)
        XCTAssertNil(try NativeWallpaperDeployment.entry(id: escaping, videosFolderURL: videos))

        let mixed = UUID().uuidString
        let bad = NativeWallpaperDeployment.NativeVideoVariant(
            filename: "../other/Wallpaper.minimal.mov", fps: 30, resolution: CGSize(width: 640, height: 360))
        try write(entry(id: mixed, filename: "Wallpaper.mov", variants: [bad, variants[1]]), in: mixed)
        XCTAssertEqual(try NativeWallpaperDeployment.entry(id: mixed, videosFolderURL: videos)?.variants, [variants[1]])
    }

    func testMetadataIsNotReadThroughASymlink() throws {
        // The extension can swap metadata.json, or the entry folder, for a
        // symlink; reading through it let the extension pick what the app
        // trusts as this entry's metadata.
        let fm = FileManager.default
        let videos = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outside = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? fm.removeItem(at: videos)
            try? fm.removeItem(at: outside)
        }
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        func planted(_ id: String) throws -> URL {
            let entry = NativeWallpaperDeployment.EntryInfo(
                id: id, name: "x", filename: "Wallpaper.mov", duration: 5, fps: 30,
                resolution: CGSize(width: 1920, height: 1080), dateAdded: Date(), contentHash: "planted")
            let url = outside.appendingPathComponent("\(id).json")
            try JSONEncoder().encode(entry).write(to: url)
            return url
        }

        let linkedFile = UUID().uuidString
        try fm.createDirectory(at: videos.appendingPathComponent(linkedFile), withIntermediateDirectories: true)
        try fm.createSymbolicLink(
            at: videos.appendingPathComponent(linkedFile).appendingPathComponent("metadata.json"),
            withDestinationURL: try planted(linkedFile))
        XCTAssertNil(try NativeWallpaperDeployment.entry(id: linkedFile, videosFolderURL: videos))

        let linkedFolder = UUID().uuidString
        let folder = outside.appendingPathComponent("folder")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try fm.moveItem(at: try planted(linkedFolder), to: folder.appendingPathComponent("metadata.json"))
        try fm.createSymbolicLink(at: videos.appendingPathComponent(linkedFolder), withDestinationURL: folder)
        XCTAssertNil(try NativeWallpaperDeployment.entry(id: linkedFolder, videosFolderURL: videos))
    }

    @MainActor
    func testPreviewIgnoresACopyThatIsASymlink() throws {
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
        let outside = videos.appendingPathComponent("outside.mov")
        try Data().write(to: outside)
        try fm.createSymbolicLink(at: dir.appendingPathComponent("Wallpaper.minimal.mov"), withDestinationURL: outside)

        XCTAssertNil(NativeWallpaperDeployment.thumbnailPreviewURL(entryID: id, minPixelWidth: 640, videosFolderURL: videos))
    }

    func testSmallPreviewShowsPosterWhenNoCopyIsWideEnough() {
        // A wallpaper never deployed natively has no copies. Hover tiles and the
        // popover decoded the 4K original for a ~300 pt view.
        let plan = NativeWallpaperDeployment.previewPlan([], minPixelWidth: 640, allowsOriginal: false)
        XCTAssertEqual(plan, .poster)
        XCTAssertEqual(NativeWallpaperDeployment.previewPlan(variants, minPixelWidth: 2560, allowsOriginal: false), .poster)
    }

    func testPreviewPlanKeepsOriginalForHeroAndSheet() {
        XCTAssertEqual(NativeWallpaperDeployment.previewPlan([], minPixelWidth: 1920, allowsOriginal: true), .original)
        XCTAssertEqual(
            NativeWallpaperDeployment.previewPlan(variants, minPixelWidth: 640, allowsOriginal: false),
            .copy(variants[1])
        )
    }

    @MainActor
    func testThumbnailPreviewURLIsNilWithoutAWideEnoughCopyOnDisk() throws {
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

        let copy = NativeWallpaperDeployment.thumbnailPreviewURL(entryID: id, minPixelWidth: 640, videosFolderURL: videos)
        XCTAssertEqual(copy?.lastPathComponent, "Wallpaper.minimal.mov")
        // Listed but missing on disk, and not deployed at all: show the poster.
        XCTAssertNil(NativeWallpaperDeployment.thumbnailPreviewURL(entryID: id, minPixelWidth: 1600, videosFolderURL: videos))
        XCTAssertNil(NativeWallpaperDeployment.thumbnailPreviewURL(entryID: UUID().uuidString, minPixelWidth: 640, videosFolderURL: videos))
    }

    func testCopiesPlannedPerSourceSize() {
        let names = { (size: CGSize) in NativeWallpaperDeployment.variantSpecs(sourceSize: size, sourceFPS: 30).map(\.filename) }
        // 4K sources also get a 1440p copy at full frame rate for 1440p monitors.
        XCTAssertEqual(
            Set(names(CGSize(width: 3840, height: 2160))), ["Wallpaper.reduced.mov", "Wallpaper.minimal.mov", "Wallpaper.qhd.mov"])
        XCTAssertEqual(Set(names(CGSize(width: 2560, height: 1440))), ["Wallpaper.reduced.mov", "Wallpaper.minimal.mov"])
        XCTAssertEqual(names(CGSize(width: 1920, height: 1080)), ["Wallpaper.minimal.mov"])
        XCTAssertEqual(names(CGSize(width: 1280, height: 720)), [])
    }

    func testQHDCopyIsPlannedOnlyForDisplaysThatPlayIt() {
        // A 4K encode ran even when every display was 4K and would never play it.
        for fixture in QHDFitFixtures.rows {
            let planned = NativeWallpaperDeployment.variantSpecs(
                sourceSize: fixture.source, sourceFPS: fixture.fps, displayPixels: [fixture.display])
            XCTAssertEqual(planned.contains { $0.filename == "Wallpaper.qhd.mov" }, fixture.playsQHD, "\(fixture)")
        }
        let uhd = CGSize(width: 3840, height: 2160)
        func plansQHD(_ displays: [CGSize]) -> Bool {
            NativeWallpaperDeployment.variantSpecs(sourceSize: uhd, sourceFPS: 60, displayPixels: displays)
                .contains { $0.filename == "Wallpaper.qhd.mov" }
        }
        XCTAssertFalse(plansQHD([]))
        XCTAssertTrue(plansQHD([uhd, CGSize(width: 2560, height: 1440)]))
        // Battery copies don't depend on the displays.
        XCTAssertEqual(
            NativeWallpaperDeployment.variantSpecs(sourceSize: uhd, sourceFPS: 60, displayPixels: [uhd]).map(\.filename),
            ["Wallpaper.reduced.mov", "Wallpaper.minimal.mov"])
    }

    func testCopySizesMatchTheSharedFixtures() {
        // The extension's selection test builds its copies with these sizes.
        let size = NativeWallpaperDeployment.copySize(source:fitting:)
        for fixture in QHDFitFixtures.rows {
            XCTAssertEqual(size(fixture.source, CGSize(width: 1920, height: 1080)), fixture.reduced)
            XCTAssertEqual(size(fixture.source, CGSize(width: 1280, height: 720)), fixture.minimal)
            XCTAssertEqual(size(fixture.source, CGSize(width: 2560, height: 1440)), fixture.qhd)
        }
    }

    func testCopyReadinessFollowsWhatEachSurfacePlays() {
        typealias Surface = NativeWallpaperDeployment.Surface
        let uhd = CGSize(width: 3840, height: 2160)
        let qhd = CGSize(width: 2560, height: 1440)
        func readiness(_ filename: String, _ surfaces: [Surface], fps: Double = 60, power: Bool = true)
            -> NativeWallpaperDeployment.VariantEncodeQueue.Readiness
        {
            let spec = NativeWallpaperDeployment.variantSpecs(sourceSize: uhd, sourceFPS: fps).first { $0.filename == filename }!
            return NativeWallpaperDeployment.copyReadiness(
                spec, sourceSize: uhd, sourceFPS: fps, surfaces: surfaces, canMakeOptionalCopies: power)
        }
        // Battery Saver plays the 720p copy, so it goes before the 1080p one.
        let saver = [Surface(pixelSize: qhd, tier: .minimal)]
        XCTAssertEqual(readiness("Wallpaper.minimal.mov", saver), .ready(rank: 0))
        XCTAssertEqual(readiness("Wallpaper.reduced.mov", saver), .ready(rank: 1))
        XCTAssertEqual(readiness("Wallpaper.reduced.mov", [Surface(pixelSize: uhd, tier: .reduced)]), .ready(rank: 0))
        // Full Quality on a 1440p display plays the 1440p copy: it went
        // after both battery copies nobody was playing.
        let full = [Surface(pixelSize: qhd, tier: .full)]
        XCTAssertEqual(readiness("Wallpaper.qhd.mov", full), .ready(rank: 0))
        XCTAssertEqual(readiness("Wallpaper.minimal.mov", full), .ready(rank: 1))
        // A 30 fps source on a 1080p display at Full Quality plays the 1080p copy.
        XCTAssertEqual(
            readiness("Wallpaper.reduced.mov", [Surface(pixelSize: CGSize(width: 1920, height: 1080), tier: .full)], fps: 30),
            .ready(rank: 0))
        // The 1440p copy is held while power or the tier keeps it unplayed,
        // and dropped once no surface fits it.
        XCTAssertEqual(readiness("Wallpaper.qhd.mov", full, power: false), .hold)
        XCTAssertEqual(readiness("Wallpaper.qhd.mov", saver), .hold)
        XCTAssertEqual(readiness("Wallpaper.qhd.mov", [Surface(pixelSize: uhd, tier: .full)]), .drop)
        XCTAssertEqual(readiness("Wallpaper.qhd.mov", []), .drop)
    }

    func testReducedTierRanksTheCopyTheExtensionPlays() {
        typealias Surface = NativeWallpaperDeployment.Surface
        for fixture in QHDFitFixtures.reducedRows {
            let specs = NativeWallpaperDeployment.variantSpecs(sourceSize: fixture.source, sourceFPS: fixture.fps)
            XCTAssertEqual(Set(specs.map(\.filename)), fixture.planned, "\(fixture)")
            let surfaces = [Surface(pixelSize: fixture.source, tier: .reduced)]
            for spec in specs where !spec.forFullQuality {
                let readiness = NativeWallpaperDeployment.copyReadiness(
                    spec, sourceSize: fixture.source, sourceFPS: fixture.fps, surfaces: surfaces, canMakeOptionalCopies: true
                )
                let expected: NativeWallpaperDeployment.VariantEncodeQueue.Readiness =
                    spec.filename == fixture.reducedPlays ? .ready(rank: 0) : .ready(rank: 1)
                XCTAssertEqual(readiness, expected, "\(spec.filename) for \(fixture)")
            }
        }
    }

    func testRestoreReportsNoDisplayAnOverlayOwns() {
        let wallpaper = WallpaperID()
        let native = DisplayID(rawValue: "native")
        let cropped = DisplayID(rawValue: "cropped")
        let spanning = DisplayID(rawValue: "spanning")
        let off = DisplayID(rawValue: "off")
        let crop = DisplayComposition(scale: 1.5)
        let span = DisplayComposition(spanningCanvas: CGRect(x: 0, y: 0, width: 5120, height: 1440))
        let assignments = [
            DisplayAssignment(displayID: native, wallpaperID: wallpaper),
            DisplayAssignment(displayID: cropped, wallpaperID: wallpaper, composition: crop),
            DisplayAssignment(displayID: spanning, wallpaperID: wallpaper, composition: span),
            DisplayAssignment(displayID: off, wallpaperID: wallpaper, composition: crop, isEnabled: false),
        ]
        XCTAssertEqual(NativeWallpaperEngine.overlayOwnedDisplays(in: assignments, onlyDefaultCrop: true), [cropped, spanning])
        XCTAssertEqual(NativeWallpaperEngine.overlayOwnedDisplays(in: assignments, onlyDefaultCrop: false), [])
    }

    func testNoBackfillForAQHDCopyNoDisplayPlays() {
        let entry = NativeWallpaperDeployment.EntryInfo(
            id: UUID().uuidString, name: "x", filename: "Wallpaper.mp4", duration: 5, fps: 60,
            resolution: CGSize(width: 3840, height: 2160), dateAdded: Date(), variants: variants
        )
        XCTAssertFalse(
            NativeWallpaperDeployment.needsVariants(entry, displayPixels: [CGSize(width: 3840, height: 2160)], fileExists: { _ in true }))
        XCTAssertTrue(
            NativeWallpaperDeployment.needsVariants(entry, displayPixels: [CGSize(width: 2560, height: 1440)], fileExists: { _ in true }))
    }

    func testQHDCopyKeepsTheSourceAspect() {
        let qhd = NativeWallpaperDeployment.variantSpecs(sourceSize: CGSize(width: 4096, height: 2304), sourceFPS: 60).first {
            $0.filename == "Wallpaper.qhd.mov"
        }
        XCTAssertEqual(qhd?.fitting, CGSize(width: 2560, height: 1440))
        let portrait = NativeWallpaperDeployment.variantSpecs(sourceSize: CGSize(width: 2160, height: 3840), sourceFPS: 60).first {
            $0.filename == "Wallpaper.qhd.mov"
        }
        XCTAssertEqual(portrait?.fitting, CGSize(width: 1440, height: 2560))
    }

    func testBatteryCopiesAreCappedAt30FPS() {
        // 60 fps battery copies decoded and redrew twice as often as needed.
        func rates(_ fps: Double) -> [String: Double] {
            Dictionary(
                uniqueKeysWithValues:
                    NativeWallpaperDeployment
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
        let reduced = NativeWallpaperDeployment.NativeVideoVariant(
            filename: "Wallpaper.reduced.mov", fps: 60, resolution: CGSize(width: 1920, height: 1080))
        let minimal = NativeWallpaperDeployment.NativeVideoVariant(
            filename: "Wallpaper.minimal.mov", fps: 60, resolution: CGSize(width: 1280, height: 720))
        let merged = NativeWallpaperDeployment.merging([minimal], with: [reduced])
        XCTAssertEqual(Set(merged.map(\.filename)), ["Wallpaper.reduced.mov", "Wallpaper.minimal.mov"])
        let replaced = NativeWallpaperDeployment.merging(
            [reduced],
            with: [NativeWallpaperDeployment.NativeVideoVariant(filename: "Wallpaper.reduced.mov", fps: 30, resolution: reduced.resolution)]
        )
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
        stale.variants =
            [.init(filename: "Wallpaper.reduced.mov", fps: 60, resolution: CGSize(width: 1920, height: 1080))] + variants.dropFirst()
            + [.init(filename: "Wallpaper.qhd.mov", fps: 60, resolution: CGSize(width: 2560, height: 1440))]
        XCTAssertTrue(NativeWallpaperDeployment.needsVariants(stale, displayPixels: qhdDisplay, fileExists: { _ in true }))
        // Listed in metadata but deleted from disk: repair it.
        XCTAssertTrue(
            NativeWallpaperDeployment.needsVariants(complete, displayPixels: qhdDisplay, fileExists: { $0 != "Wallpaper.qhd.mov" }))
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

/// Deploy copies the library file into a staging folder outside the
/// `videos` folder the extension scans, then moves the finished entry in
/// with one rename.
final class DeploymentStagingTests: XCTestCase {
    private var root: URL!
    private let id = UUID().uuidString
    private var videos: URL { root.appendingPathComponent("videos") }
    private var staging: URL { root.appendingPathComponent("deploy-staging") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func source(_ text: String) throws -> URL {
        let url = root.appendingPathComponent("library-\(UUID().uuidString).mov")
        try Data(text.utf8).write(to: url)
        return url
    }

    private func stage(_ source: URL) throws -> NativeWallpaperDeployment.StagedDeployment {
        try NativeWallpaperDeployment.stageDeployment(
            source: source, entryID: id, filename: "Wallpaper.mov", stagingFolderURL: staging, videosFolderURL: videos)
    }

    private func publish(_ staged: NativeWallpaperDeployment.StagedDeployment) throws {
        try NativeWallpaperDeployment.publishDeployment(
            staged, stagingFolderURL: staging, videosFolderURL: videos, trustedAncestor: root)
    }

    func testStagingHappensOutsideTheScannedFolder() throws {
        // The entry folder was created in videos/ before the copy, so a scan
        // could see it empty or half-written.
        let staged = try stage(try source("v1"))
        XCTAssertEqual(staged.hash, SHA256.hash(data: Data("v1".utf8)).map { String(format: "%02x", $0) }.joined())
        XCTAssertFalse(FileManager.default.fileExists(atPath: videos.appendingPathComponent(id).path))
        XCTAssertEqual(try Data(contentsOf: staged.videoURL), Data("v1".utf8))

        try publish(staged)
        let published = videos.appendingPathComponent(id).appendingPathComponent("Wallpaper.mov")
        XCTAssertEqual(try Data(contentsOf: published), Data("v1".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: staging.path), [])
    }

    func testRedeployReplacesTheWholeEntry() throws {
        try publish(try stage(try source("v1")))
        try Data("old copy".utf8).write(to: videos.appendingPathComponent(id).appendingPathComponent("Wallpaper.minimal.mov"))
        try publish(try stage(try source("v2")))
        let dir = videos.appendingPathComponent(id)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["Wallpaper.mov"])
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("Wallpaper.mov")), Data("v2".utf8))
    }

    func testPublishOverASymlinkedEntryLeavesItsTarget() throws {
        let fm = FileManager.default
        let victim = root.appendingPathComponent("Documents", isDirectory: true)
        try fm.createDirectory(at: victim, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: victim.appendingPathComponent("thesis.pages"))
        try fm.createDirectory(at: videos, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: videos.appendingPathComponent(id), withDestinationURL: victim)

        try publish(try stage(try source("v1")))
        XCTAssertTrue(fm.fileExists(atPath: victim.appendingPathComponent("thesis.pages").path))
        XCTAssertNil(try? fm.destinationOfSymbolicLink(atPath: videos.appendingPathComponent(id).path))
    }

    func testAnInterruptedStageIsClearedOnTheNextDeploy() throws {
        let first = try stage(try source("v1"))
        let second = try stage(try source("v2"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.directoryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.directoryURL.path))
    }
}

/// Removing a wallpaper from the library has to take its deployed copy
/// with it, or System Settings keeps offering it.
final class DeploymentRemovalTests: XCTestCase {
    private var root: URL!
    private var videos: URL { root.appendingPathComponent("videos") }
    private var staging: URL { root.appendingPathComponent("copy-staging") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func deployed(_ id: String) throws -> URL {
        let dir = videos.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["Wallpaper.mov", "Wallpaper.minimal.mov", "thumbnail.jpg", "metadata.json"] {
            try Data("x".utf8).write(to: dir.appendingPathComponent(name))
        }
        return dir
    }

    func testRemovalDeletesTheEntryAndItsStagedCopies() throws {
        let fm = FileManager.default
        let gone = UUID().uuidString
        let kept = UUID().uuidString
        let goneDir = try deployed(gone)
        let keptDir = try deployed(kept)
        let goneExport = staging.appendingPathComponent("\(gone).abc.Wallpaper.reduced.mov")
        let keptExport = staging.appendingPathComponent("\(kept).abc.Wallpaper.reduced.mov")
        for url in [goneExport, keptExport] { try Data("x".utf8).write(to: url) }

        try NativeWallpaperDeployment.deleteDeployedFiles(
            entryID: gone, videosFolderURL: videos, stagingFolderURL: staging, trustedAncestor: root)
        XCTAssertFalse(fm.fileExists(atPath: goneDir.path))
        XCTAssertFalse(fm.fileExists(atPath: goneExport.path))
        XCTAssertTrue(fm.fileExists(atPath: keptDir.appendingPathComponent("Wallpaper.mov").path))
        XCTAssertTrue(fm.fileExists(atPath: keptExport.path))
    }

    func testRemovalOfASymlinkedEntryLeavesItsTarget() throws {
        let fm = FileManager.default
        let id = UUID().uuidString
        let victim = root.appendingPathComponent("Documents", isDirectory: true)
        try fm.createDirectory(at: victim, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: victim.appendingPathComponent("thesis.pages"))
        try fm.createDirectory(at: videos, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: videos.appendingPathComponent(id), withDestinationURL: victim)

        try NativeWallpaperDeployment.deleteDeployedFiles(
            entryID: id, videosFolderURL: videos, stagingFolderURL: staging, trustedAncestor: root)
        XCTAssertTrue(fm.fileExists(atPath: victim.appendingPathComponent("thesis.pages").path))
        XCTAssertNil(try? fm.destinationOfSymbolicLink(atPath: videos.appendingPathComponent(id).path))
    }

    func testRemovalRefusesANameThatIsNotAnEntryID() throws {
        let dir = try deployed("Wallpapers")
        let export = staging.appendingPathComponent("Wallpapers.abc.Wallpaper.reduced.mov")
        try Data("x".utf8).write(to: export)
        XCTAssertThrowsError(
            try NativeWallpaperDeployment.deleteDeployedFiles(
                entryID: "Wallpapers", videosFolderURL: videos, stagingFolderURL: staging, trustedAncestor: root))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: export.path))
    }

    func testRemovalReportsAFolderItCannotDelete() throws {
        let fm = FileManager.default
        let id = UUID().uuidString
        let dir = try deployed(id)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        XCTAssertThrowsError(
            try NativeWallpaperDeployment.deleteDeployedFiles(
                entryID: id, videosFolderURL: videos, stagingFolderURL: staging, trustedAncestor: root))
        // A wallpaper already gone is not an error.
        XCTAssertNoThrow(
            try NativeWallpaperDeployment.deleteDeployedFiles(
                entryID: UUID().uuidString, videosFolderURL: videos, stagingFolderURL: staging, trustedAncestor: root))
    }

    @MainActor
    func testARemovedWallpaperIsNotDeployedAgain() async throws {
        let id = WallpaperID()
        NativeWallpaperDeployment.markRemoved(entryID: id.rawValue.uuidString)
        defer { NativeWallpaperDeployment.unmarkRemoved(entryID: id.rawValue.uuidString) }
        let asset = WallpaperAsset(
            id: id, name: "Gone", mediaURL: root.appendingPathComponent("gone.mov"), duration: 5,
            framesPerSecond: 30, pixelSize: CGSize(width: 1920, height: 1080), contentHash: "gone", containsAudio: false)
        do {
            _ = try await NativeWallpaperDeployment.ensureDeployed(asset: asset, surfaces: [])
            XCTFail("expected the removed wallpaper to be refused")
        } catch NativeWallpaperDeployment.DeploymentError.removed {}
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

    /// `NativeWallpaperDeployment.publish` with native mode on unless a
    /// test says otherwise; the test host leaves it off.
    private func publish(
        _ staged: URL, job: NativeWallpaperDeployment.VariantEncodeQueue.Job, resolution: CGSize, videosFolderURL: URL,
        writeMetadata: ((Data, TrustedDirectory) throws -> Void)? = nil,
        isNativeModeOn: () -> Bool = { true }
    ) -> NativeWallpaperDeployment.PublishResult {
        if let writeMetadata {
            return NativeWallpaperDeployment.publish(
                staged, job: job, resolution: resolution, videosFolderURL: videosFolderURL, writeMetadata: writeMetadata,
                isNativeModeOn: isNativeModeOn)
        }
        return NativeWallpaperDeployment.publish(
            staged, job: job, resolution: resolution, videosFolderURL: videosFolderURL, isNativeModeOn: isNativeModeOn)
    }

    private var dest: URL { videos.appendingPathComponent(id).appendingPathComponent(minimal.filename) }
    private let size = CGSize(width: 1280, height: 720)

    func testPublishesACopyForTheCurrentDeployment() throws {
        try deploy(hash: "aaa")
        let staged = try stage(job(hash: "aaa"))
        let result = publish(staged, job: job(hash: "aaa"), resolution: size, videosFolderURL: videos)
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
        let result = publish(staged, job: job(hash: "old"), resolution: size, videosFolderURL: videos)
        XCTAssertEqual(result, .stale)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertNil(try NativeWallpaperDeployment.entry(id: id, videosFolderURL: videos)?.variants)
    }

    func testNoCopyIsPublishedOnceNativeModeIsOff() throws {
        // A copy waiting on the entry lock published into the extension's
        // container after native mode was turned off.
        try deploy(hash: "aaa")
        let staged = try stage(job(hash: "aaa"))
        let result = publish(
            staged, job: job(hash: "aaa"), resolution: size, videosFolderURL: videos, isNativeModeOn: { false })
        XCTAssertEqual(result, .nativeModeOff)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
        XCTAssertNil(try NativeWallpaperDeployment.entry(id: id, videosFolderURL: videos)?.variants)
    }

    func testPublishMergesVariantsWrittenWhileWaitingForTheEntryFileLock() throws {
        try deploy(hash: "aaa")
        let entryURL = videos.appendingPathComponent(id)
        let lock = open(entryURL.appendingPathComponent(".copy-publish.lock").path, O_CREAT | O_RDWR, 0o600)
        guard lock >= 0 else { throw POSIXError(.EIO) }
        defer { close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw POSIXError(.EIO) }

        let job = job(hash: "aaa")
        let staged = try stage(job)
        let videos = self.videos
        let size = self.size
        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            started.signal()
            XCTAssertEqual(
                NativeWallpaperDeployment.publish(staged, job: job, resolution: size, videosFolderURL: videos, isNativeModeOn: { true }),
                .published)
            finished.signal()
        }
        XCTAssertEqual(started.wait(timeout: .now() + 5), .success)
        let beforeUnlock = finished.wait(timeout: .now() + 0.5)
        XCTAssertEqual(beforeUnlock, .timedOut)

        let otherMovie = "Wallpaper.reduced.mov"
        var entry = try XCTUnwrap(NativeWallpaperDeployment.entry(id: id, videosFolderURL: videos))
        entry.variants = [.init(filename: otherMovie, fps: 30, resolution: size)]
        let folder = try TrustedDirectory(url: entryURL)
        try folder.writeFile(named: otherMovie, contents: Data("other copy".utf8))
        try folder.writeFile(named: "metadata.json", contents: JSONEncoder().encode(entry))
        XCTAssertEqual(flock(lock, LOCK_UN), 0)
        if beforeUnlock == .timedOut {
            XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        }

        let updated = try XCTUnwrap(NativeWallpaperDeployment.entry(id: id, videosFolderURL: videos))
        XCTAssertEqual(Set(updated.variants?.map(\.filename) ?? []), [otherMovie, minimal.filename])
    }

    @MainActor
    func testTurningNativeModeOffReturnsWhileMetadataWriteIsBlocked() throws {
        let suite = "VariantPublicationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        nonisolated(unsafe) let setting = NativeModeSetting(defaults: defaults, usedNativeBefore: { false })
        setting.enable()
        try deploy(hash: "aaa")
        let job = job(hash: "aaa")
        let staged = try stage(job)
        let videos = self.videos
        let size = self.size
        let writing = DispatchSemaphore(value: 0)
        let disabled = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            defer { finished.signal() }
            _ = NativeWallpaperDeployment.publish(
                staged, job: job, resolution: size, videosFolderURL: videos,
                writeMetadata: { data, folder in
                    writing.signal()
                    XCTAssertEqual(disabled.wait(timeout: .now() + 2), .success)
                    XCTAssertFalse(setting.isEnabled)
                    try folder.writeFile(named: "metadata.json", contents: data)
                },
                isNativeModeOn: { setting.isEnabled })
        }
        XCTAssertEqual(writing.wait(timeout: .now() + 5), .success)
        setting.disable()
        disabled.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
    }

    func testFailedMetadataWriteKeepsThePreviousVariant() throws {
        try deploy(hash: "aaa")
        let job = job(hash: "aaa")
        let previous = try stage(job)
        let original = Data("previous copy".utf8)
        try original.write(to: previous)
        XCTAssertEqual(publish(previous, job: job, resolution: size, videosFolderURL: videos), .published)
        let metadata = videos.appendingPathComponent(id).appendingPathComponent("metadata.json")
        let originalMetadata = try Data(contentsOf: metadata)

        let replacement = try stage(job)
        let failed = publish(
            replacement, job: job, resolution: CGSize(width: 640, height: 360), videosFolderURL: videos,
            writeMetadata: { _, _ in throw POSIXError(.ENOSPC) })
        XCTAssertEqual(failed, .failed)
        XCTAssertEqual(try? Data(contentsOf: dest), original)
        XCTAssertEqual(try Data(contentsOf: metadata), originalMetadata)
    }

    @MainActor
    func testFailedWriteDiscardsThePreviousMovieOnceRemovalStarts() throws {
        try deploy(hash: "aaa")
        let job = job(hash: "aaa")
        XCTAssertEqual(publish(try stage(job), job: job, resolution: size, videosFolderURL: videos), .published)
        let staged = try stage(job)
        let entryID = id
        defer { NativeWallpaperDeployment.unmarkRemoved(entryID: entryID) }
        _ = publish(
            staged, job: job, resolution: size, videosFolderURL: videos,
            writeMetadata: { _, _ in
                NativeWallpaperDeployment.markRemoved(entryID: entryID)
                throw POSIXError(.ENOSPC)
            })
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: staging.path), [])
    }

    func testPublishDoesNotSucceedWhenTheEntryIsReplacedDuringCommit() throws {
        try deploy(hash: "aaa")
        let job = job(hash: "aaa")
        XCTAssertEqual(publish(try stage(job), job: job, resolution: size, videosFolderURL: videos), .published)
        let staged = try stage(job)
        let entryURL = videos.appendingPathComponent(id)
        let oldURL = root.appendingPathComponent("old-entry")
        let result = publish(
            staged, job: job, resolution: size, videosFolderURL: videos,
            writeMetadata: { data, folder in
                try FileManager.default.moveItem(at: entryURL, to: oldURL)
                try FileManager.default.createDirectory(at: entryURL, withIntermediateDirectories: false)
                try folder.writeFile(named: "metadata.json", contents: data)
            })
        XCTAssertEqual(result, .deferred)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldURL.appendingPathComponent(minimal.filename).path))
    }

    func testAFailedMetadataWriteNeverTakesTheFileBackFromTheEntry() throws {
        // The export went back to staging by name, so the extension could
        // swap it inside the entry first and have the app probe its bytes.
        let fm = FileManager.default
        try deploy(hash: "aaa")
        let staged = try stage(job(hash: "aaa"))
        let dest = self.dest
        let failed = publish(
            staged, job: job(hash: "aaa"), resolution: size, videosFolderURL: videos,
            writeMetadata: { _, _ in
                try? fm.removeItem(at: dest)
                try? Data("planted".utf8).write(to: dest)
                throw CocoaError(.fileWriteOutOfSpace)
            })
        XCTAssertEqual(failed, .failed)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: staging.path), [])
        XCTAssertFalse(fm.fileExists(atPath: dest.path))
        let retried = publish(try stage(job(hash: "aaa")), job: job(hash: "aaa"), resolution: size, videosFolderURL: videos)
        XCTAssertEqual(retried, .published)
    }

    /// A staging folder swapped for a symlink to `victim`, holding a file
    /// named like the export `job` would publish.
    private func symlinkedStaging(for job: NativeWallpaperDeployment.VariantEncodeQueue.Job) throws -> (staged: URL, victimFile: URL) {
        let fm = FileManager.default
        let victim = root.appendingPathComponent("victim", isDirectory: true)
        try fm.createDirectory(at: victim, withIntermediateDirectories: true)
        let linked = root.appendingPathComponent("linked-staging", isDirectory: true)
        try fm.createSymbolicLink(at: linked, withDestinationURL: victim)
        let staged = NativeWallpaperDeployment.stagedURL(for: job, stagingFolderURL: linked)
        let victimFile = victim.appendingPathComponent(staged.lastPathComponent)
        try Data("keep".utf8).write(to: victimFile)
        return (staged, victimFile)
    }

    func testAStaleCopyIsNotDeletedThroughASymlinkedStagingFolder() throws {
        try deploy(hash: "new")
        let (staged, victimFile) = try symlinkedStaging(for: job(hash: "old"))
        let result = publish(staged, job: job(hash: "old"), resolution: size, videosFolderURL: videos)
        XCTAssertNotEqual(result, .published)
        XCTAssertEqual(try Data(contentsOf: victimFile), Data("keep".utf8))
    }

    func testACopyIsNotTakenFromASymlinkedStagingFolder() throws {
        try deploy(hash: "aaa")
        let (staged, victimFile) = try symlinkedStaging(for: job(hash: "aaa"))
        let result = publish(staged, job: job(hash: "aaa"), resolution: size, videosFolderURL: videos)
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(try Data(contentsOf: victimFile), Data("keep".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
    }

    func testNoCopyIsEncodedIntoASymlinkedStagingFolder() async throws {
        let (staged, victimFile) = try symlinkedStaging(for: job(hash: "aaa"))
        let result = await NativeWallpaperDeployment.transcode(
            sourceURL: root.appendingPathComponent("source.mov"), to: staged, spec: minimal
        ) { true }
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: victimFile.deletingLastPathComponent().path).count, 1)
        XCTAssertEqual(try Data(contentsOf: victimFile), Data("keep".utf8))
    }

    func testAnExportIsKeptWhenTheVideosFolderCantBeTrusted() throws {
        // A videos folder swapped for a symlink says nothing about whether
        // the job is stale, so the export stays for a retry.
        let fm = FileManager.default
        try deploy(hash: "aaa")
        let staged = try stage(job(hash: "aaa"))
        let moved = root.appendingPathComponent("videos-real")
        try fm.moveItem(at: videos, to: moved)
        try fm.createSymbolicLink(at: videos, withDestinationURL: moved)
        let result = publish(staged, job: job(hash: "aaa"), resolution: size, videosFolderURL: videos)
        XCTAssertEqual(result, .failed)
        XCTAssertTrue(fm.fileExists(atPath: staged.path))
    }

    func testAnExportIsKeptWhileTheVideosFolderIsMissing() throws {
        // videos/ moved aside for a moment: the entry may still exist.
        let fm = FileManager.default
        try deploy(hash: "aaa")
        let staged = try stage(job(hash: "aaa"))
        try fm.moveItem(at: videos, to: root.appendingPathComponent("videos-aside"))
        let result = publish(staged, job: job(hash: "aaa"), resolution: size, videosFolderURL: videos)
        XCTAssertEqual(result, .failed)
        XCTAssertTrue(fm.fileExists(atPath: staged.path))
    }

    func testAnExportOfARemovedEntryIsDiscarded() throws {
        let staged = try stage(job(hash: "aaa"))
        try FileManager.default.removeItem(at: videos.appendingPathComponent(id))
        let result = publish(staged, job: job(hash: "aaa"), resolution: size, videosFolderURL: videos)
        XCTAssertEqual(result, .stale)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
    }

    func testCopyExportsAreStagedOutsideTheExtensionsContainer() {
        // The app probes a finished export by path. In the container the
        // extension could swap it after the regular-file check and have
        // AVFoundation parse bytes nobody encoded.
        let staging = NativeWallpaperDeployment.stagingFolderURL.standardizedFileURL
        let container = NativeWallpaperDeployment.containerURL.standardizedFileURL
        XCTAssertFalse(staging.pathComponents.starts(with: container.pathComponents))
        XCTAssertEqual(
            staging.deletingLastPathComponent(),
            NativeWallpaperDeployment.transcodeSourcesFolderURL.standardizedFileURL.deletingLastPathComponent())
    }

    func testLaunchDeletesExportsOlderVersionsLeftInTheContainer() throws {
        // An older LumaWall still running may be writing a fresh one, so
        // only exports untouched for an hour go.
        let fm = FileManager.default
        let docs = root.appendingPathComponent("Documents", isDirectory: true)
        let legacy = docs.appendingPathComponent("copy-staging", isDirectory: true)
        try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
        let old = legacy.appendingPathComponent("\(id).aaa.Wallpaper.minimal.mov")
        let fresh = legacy.appendingPathComponent("\(id).\(UUID().uuidString).partial.mov")
        for url in [old, fresh] { try Data("x".utf8).write(to: url) }
        let now = Date()
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-3_601)], ofItemAtPath: old.path)
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-60)], ofItemAtPath: fresh.path)
        NativeWallpaperDeployment.removeLegacyCopyStaging(documentsURL: docs, trustedAncestor: root, now: now)
        XCTAssertFalse(fm.fileExists(atPath: old.path))
        XCTAssertTrue(fm.fileExists(atPath: fresh.path))
    }

    func testLegacyStagingCleanupLeavesSymlinkTargetsAlone() throws {
        let fm = FileManager.default
        let victim = root.appendingPathComponent("victim", isDirectory: true)
        try fm.createDirectory(at: victim, withIntermediateDirectories: true)
        let precious = victim.appendingPathComponent("thesis.mov")
        try Data("keep".utf8).write(to: precious)
        let docs = root.appendingPathComponent("Documents", isDirectory: true)
        try fm.createDirectory(at: docs, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: docs.appendingPathComponent("copy-staging"), withDestinationURL: victim)
        let later = Date().addingTimeInterval(86_400)
        NativeWallpaperDeployment.removeLegacyCopyStaging(documentsURL: docs, trustedAncestor: root, now: later)
        XCTAssertTrue(fm.fileExists(atPath: precious.path))

        // Documents itself swapped for a link: nothing below it is entered.
        try fm.removeItem(at: docs)
        let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
        let foreign = elsewhere.appendingPathComponent("copy-staging/\(id).aaa.Wallpaper.minimal.mov")
        try fm.createDirectory(at: foreign.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: foreign)
        try fm.createSymbolicLink(at: docs, withDestinationURL: elsewhere)
        NativeWallpaperDeployment.removeLegacyCopyStaging(documentsURL: docs, trustedAncestor: root, now: later)
        XCTAssertTrue(fm.fileExists(atPath: foreign.path))
    }

    func testOnlyARegularFileCountsAsAFinishedExport() throws {
        let fm = FileManager.default
        let folder = try TrustedDirectory(url: staging)
        XCTAssertFalse(NativeWallpaperDeployment.reusableExport(named: "missing.mov", in: folder))
        try Data("x".utf8).write(to: staging.appendingPathComponent("done.mov"))
        XCTAssertTrue(NativeWallpaperDeployment.reusableExport(named: "done.mov", in: folder))
        // A folder or a symlink there would block the copy for good; it's
        // cleared so the encode runs again. A symlink's target stays.
        try fm.createDirectory(at: staging.appendingPathComponent("folder.mov"), withIntermediateDirectories: false)
        XCTAssertFalse(NativeWallpaperDeployment.reusableExport(named: "folder.mov", in: folder))
        XCTAssertFalse(fm.fileExists(atPath: staging.appendingPathComponent("folder.mov").path))
        let outside = root.appendingPathComponent("outside.mov")
        try Data("keep".utf8).write(to: outside)
        try fm.createSymbolicLink(at: staging.appendingPathComponent("link.mov"), withDestinationURL: outside)
        XCTAssertFalse(NativeWallpaperDeployment.reusableExport(named: "link.mov", in: folder))
        XCTAssertNil(try? fm.destinationOfSymbolicLink(atPath: staging.appendingPathComponent("link.mov").path))
        XCTAssertEqual(try Data(contentsOf: outside), Data("keep".utf8))
    }

    func testPublishReplacesASymlinkedCopyWithoutTouchingItsTarget() throws {
        let fm = FileManager.default
        try deploy(hash: "aaa")
        let outside = root.appendingPathComponent("outside.mov")
        try Data("keep".utf8).write(to: outside)
        try fm.createSymbolicLink(at: dest, withDestinationURL: outside)
        let staged = try stage(job(hash: "aaa"))
        let result = publish(staged, job: job(hash: "aaa"), resolution: size, videosFolderURL: videos)
        XCTAssertEqual(result, .published)
        XCTAssertEqual(try Data(contentsOf: outside), Data("keep".utf8))
        XCTAssertEqual(try Data(contentsOf: dest), Data("copy".utf8))
        XCTAssertNil(try? fm.destinationOfSymbolicLink(atPath: dest.path))
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
        NativeWallpaperDeployment.cleanUpAbandonedExports(videosFolderURL: videos, stagingFolderURL: staging, trustedAncestor: root)
        XCTAssertFalse(fm.fileExists(atPath: partial.path))
        XCTAssertFalse(fm.fileExists(atPath: legacyTemp.path))
        XCTAssertFalse(fm.fileExists(atPath: stale.path))
        XCTAssertTrue(fm.fileExists(atPath: current.path))
        XCTAssertTrue(fm.fileExists(atPath: videos.appendingPathComponent(id).appendingPathComponent("metadata.json").path))
    }

    func testStartupCleanupKeepsOnlyPublishingPartialsOwnedByLiveProcesses() throws {
        let live = staging.appendingPathComponent("\(getpid()).\(UUID().uuidString).publishing.partial.mov")
        let abandoned = staging.appendingPathComponent("\(Int32.max).\(UUID().uuidString).publishing.partial.mov")
        for url in [live, abandoned] { try Data("copy".utf8).write(to: url) }

        NativeWallpaperDeployment.cleanUpAbandonedExports(videosFolderURL: videos, stagingFolderURL: staging, trustedAncestor: root)

        XCTAssertTrue(FileManager.default.fileExists(atPath: live.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))
    }

    func testStartupCleanupKeepsAnExportItCantJudge() throws {
        // An entry folder that can't be opened safely says nothing about
        // whether its exports are stale. One whose entry is gone is.
        let fm = FileManager.default
        try deploy(hash: "aaa")
        let kept = try stage(job(hash: "aaa"))
        let entry = videos.appendingPathComponent(id)
        let moved = root.appendingPathComponent("entry-real")
        try fm.moveItem(at: entry, to: moved)
        try fm.createSymbolicLink(at: entry, withDestinationURL: moved)
        let orphan = staging.appendingPathComponent("\(UUID().uuidString).aaa.Wallpaper.minimal.mov")
        try Data("x".utf8).write(to: orphan)
        NativeWallpaperDeployment.cleanUpAbandonedExports(videosFolderURL: videos, stagingFolderURL: staging, trustedAncestor: root)
        XCTAssertTrue(fm.fileExists(atPath: kept.path))
        XCTAssertFalse(fm.fileExists(atPath: orphan.path))
    }

    func testStartupCleanupLeavesSymlinkTargetsAlone() throws {
        // Cleanup listed the staging folder and entry folders by path, so
        // either one swapped for a symlink had its target's files deleted.
        let fm = FileManager.default
        try deploy(hash: "aaa")
        let victim = root.appendingPathComponent("Documents", isDirectory: true)
        try fm.createDirectory(at: victim, withIntermediateDirectories: true)
        let precious = victim.appendingPathComponent("thesis.pages")
        let legacyName = "Wallpaper.minimal.mov.\(UUID().uuidString).tmp.mov"
        for url in [precious, victim.appendingPathComponent(legacyName)] { try Data("keep".utf8).write(to: url) }
        let entry = NativeWallpaperDeployment.EntryInfo(
            id: id, name: "x", filename: "Wallpaper.mov", duration: 5, fps: 30,
            resolution: CGSize(width: 1280, height: 720), dateAdded: Date())
        try JSONEncoder().encode(entry).write(to: victim.appendingPathComponent("metadata.json"))
        try fm.removeItem(at: staging)
        try fm.createSymbolicLink(at: staging, withDestinationURL: victim)
        let linkedEntry = videos.appendingPathComponent(UUID().uuidString)
        try fm.createSymbolicLink(at: linkedEntry, withDestinationURL: victim)

        NativeWallpaperDeployment.cleanUpAbandonedExports(videosFolderURL: videos, stagingFolderURL: staging, trustedAncestor: root)
        XCTAssertTrue(fm.fileExists(atPath: precious.path))
        XCTAssertTrue(fm.fileExists(atPath: victim.appendingPathComponent(legacyName).path))
    }

    func testStartupCleanupRefusesASymlinkAboveTheStagingFolder() throws {
        // The extension can swap its own Documents folder for a symlink;
        // cleanup then opened a real copy-staging folder somewhere else.
        let fm = FileManager.default
        let victim = root.appendingPathComponent("Elsewhere", isDirectory: true)
        let foreign = victim.appendingPathComponent("copy-staging", isDirectory: true)
        try fm.createDirectory(at: foreign, withIntermediateDirectories: true)
        let movie = foreign.appendingPathComponent("\(id).\(UUID().uuidString).partial.mov")
        try Data("keep".utf8).write(to: movie)
        let docs = root.appendingPathComponent("Documents")
        try fm.createSymbolicLink(at: docs, withDestinationURL: victim)

        NativeWallpaperDeployment.cleanUpAbandonedExports(
            videosFolderURL: docs.appendingPathComponent("videos"),
            stagingFolderURL: docs.appendingPathComponent("copy-staging"), trustedAncestor: root, stagingAncestor: root)
        XCTAssertTrue(fm.fileExists(atPath: movie.path))
    }

    func testStartupCleanupDeletesOnlyStagedMovies() throws {
        let fm = FileManager.default
        try deploy(hash: "aaa")
        let note = staging.appendingPathComponent("README.txt")
        let folder = staging.appendingPathComponent("nested", isDirectory: true)
        try Data("x".utf8).write(to: note)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        NativeWallpaperDeployment.cleanUpAbandonedExports(videosFolderURL: videos, stagingFolderURL: staging, trustedAncestor: root)
        XCTAssertTrue(fm.fileExists(atPath: note.path))
        XCTAssertTrue(fm.fileExists(atPath: folder.path))
    }

    func testLegacyCleanupKeepsAPrimaryRecoveredFromAnExport() throws {
        // The extension can recover an old export as an entry's primary
        // video. Deleting it made the extension prune the whole entry.
        let fm = FileManager.default
        let recovered = "Wallpaper.minimal.mov.\(UUID().uuidString).tmp.mov"
        let dir = videos.appendingPathComponent(id)
        let entry = NativeWallpaperDeployment.EntryInfo(
            id: id, name: "x", filename: recovered, duration: 5, fps: 30,
            resolution: CGSize(width: 1280, height: 720), dateAdded: Date()
        )
        try JSONEncoder().encode(entry).write(to: dir.appendingPathComponent("metadata.json"))
        let userFile = dir.appendingPathComponent("Holiday.tmp.mov")
        for url in [dir.appendingPathComponent(recovered), userFile] { try Data("x".utf8).write(to: url) }
        // No readable metadata: the extension may still recover this one.
        let unlisted = videos.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: unlisted, withIntermediateDirectories: true)
        let orphan = unlisted.appendingPathComponent("Wallpaper.qhd.mov.\(UUID().uuidString).tmp.mov")
        try Data("x".utf8).write(to: orphan)

        NativeWallpaperDeployment.cleanUpAbandonedExports(videosFolderURL: videos, stagingFolderURL: staging, trustedAncestor: root)
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent(recovered).path))
        XCTAssertTrue(fm.fileExists(atPath: userFile.path))
        XCTAssertTrue(fm.fileExists(atPath: orphan.path))
    }
}
