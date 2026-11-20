import AVFoundation
import AVFAudio
import CoreGraphics
import CoreMedia
import CoreVideo
import CryptoKit
import Foundation
import Testing
@testable import LumaWallCore

/// End-to-end import tests with synthesized videos, no fixtures, no production
/// data. Videos are encoded in-test with `AVAssetWriter` (software H.264 works
/// headless), so every path runs on any Mac.
///
/// Serialized: the tests share one hardware/software encoder resource, and
/// parallel encodes flaked the runner (VideoToolbox contention under load).
@Suite(.serialized)
struct MediaImporterTests {
    @Test func inspectsSynthesizedSilentVideo() async throws {
        let source = try await makeVideo(withAudio: false)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let importer = try MediaImporter(store: store(at: source.deletingLastPathComponent()))

        let inspection = try await importer.inspect(source)
        #expect(abs(inspection.duration - 1.0) < 0.25)
        #expect(abs(inspection.pixelSize.width - 1280) < 1)
        #expect(abs(inspection.pixelSize.height - 720) < 1)
        #expect(!inspection.containsAudio)
        #expect(inspection.contentHash.count == 64)
        #expect(inspection.fileSize > 0)
        // 1280 wide is below the 1080p bar: softness warning must fire.
        #expect(
            inspection.recommendations.contains {
                $0.contains("below 1080p")
            })
    }

    @Test func importsSilentVideoByCopyWithPoster() async throws {
        let dir = isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try await makeVideo(withAudio: false, in: dir, name: "clip.mov")
        let importer = try MediaImporter(store: store(at: dir))

        let outcome = try await importer.importVideo(source, preferredName: "  Demo  ")
        #expect(outcome.asset.name == "Demo")
        #expect(!outcome.removedAudio)
        #expect(outcome.asset.mediaURL.pathExtension == "mov")
        #expect(FileManager.default.fileExists(atPath: outcome.asset.mediaURL.path))
        #expect(FileManager.default.fileExists(atPath: try #require(outcome.asset.posterURL).path))
    }

    @Test func blankPreferredNameFallsBackToFilename() async throws {
        let dir = isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try await makeVideo(withAudio: false, in: dir, name: "myclip.mov")
        let importer = try MediaImporter(store: store(at: dir))

        let outcome = try await importer.importVideo(source, preferredName: "   ")
        #expect(outcome.asset.name == "myclip")
    }

    @Test func importsVideoWithAudioStripped() async throws {
        let dir = isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try await makeVideo(withAudio: true, in: dir, name: "talkie.mov")
        let importer = try MediaImporter(store: store(at: dir))

        let outcome = try await importer.importVideo(source)
        #expect(outcome.removedAudio)
        #expect(outcome.asset.mediaURL.lastPathComponent == "Wallpaper.mov")
        let output = AVURLAsset(url: outcome.asset.mediaURL)
        #expect(try await output.loadTracks(withMediaType: .audio).isEmpty)
        #expect(!(try await output.loadTracks(withMediaType: .video).isEmpty))
    }

    @Test func duplicateImportThrowsDuplicate() async throws {
        let dir = isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try await makeVideo(withAudio: false, in: dir, name: "once.mov")
        let importer = try MediaImporter(store: store(at: dir))
        _ = try await importer.importVideo(source)

        await #expect(throws: LibraryStore.StoreError.self) {
            try await importer.importVideo(source)
        }
    }

    @Test func webURLsAreRejectedBeforeAnyMediaWork() async throws {
        // A dropped HTTPS link went straight to AVURLAsset, which contacted
        // the server while probing it.
        let dir = isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let importer = try MediaImporter(store: store(at: dir))
        let web = try #require(URL(string: "https://example.com/clip.mov"))

        await #expect(throws: VerifiedFileCopy.CopyError.notALocalFile) { try await importer.inspect(web) }
        await #expect(throws: VerifiedFileCopy.CopyError.notALocalFile) { try await importer.importVideo(web) }
        #expect(MediaImporter.localFiles(in: [web, dir]) == [dir])
    }

    @Test func importStoresTheBytesItHashed() async throws {
        let dir = isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try await makeVideo(withAudio: false, in: dir, name: "clip.mov")
        let importer = try MediaImporter(store: store(at: dir))

        let outcome = try await importer.importVideo(source)
        let stored = try Data(contentsOf: outcome.asset.mediaURL)
        #expect(stored == (try Data(contentsOf: source)))
        #expect(outcome.asset.contentHash == SHA256.hash(data: stored).map { String(format: "%02x", $0) }.joined())
        #expect(try libraryItems(in: dir) == Set(["Library.json", outcome.asset.id.rawValue.uuidString]))
    }

    @Test func importRefusesAFolderNamedLikeAVideo() async throws {
        let dir = isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("bundle.mov", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let importer = try MediaImporter(store: store(at: dir))

        await #expect(throws: VerifiedFileCopy.CopyError.notARegularFile) { try await importer.importVideo(folder) }
        #expect(try await store(at: dir).assets().isEmpty)
    }

    @Test func aFailedImportLeavesNoStagedCopy() async throws {
        let dir = isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try await makeVideo(withAudio: false, in: dir, name: "clip.mov")
        let importer = try MediaImporter(store: store(at: dir))
        let first = try await importer.importVideo(source)

        await #expect(throws: LibraryStore.StoreError.self) { try await importer.importVideo(source) }
        #expect(try libraryItems(in: dir) == Set(["Library.json", first.asset.id.rawValue.uuidString]))
    }

    @Test func inspectRejectsNonVideo() async throws {
        let dir = isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let text = dir.appendingPathComponent("notes.txt")
        try "hello".write(to: text, atomically: true, encoding: .utf8)
        let importer = try MediaImporter(store: store(at: dir))

        // Unreadable media maps to the friendly error, not a raw AVError.
        await #expect(throws: MediaImporter.ImportError.self) {
            try await importer.inspect(text)
        }
        do {
            _ = try await importer.inspect(text)
            Issue.record("expected inspect to throw for a text file")
        } catch let error as MediaImporter.ImportError {
            #expect(error == .unsupportedMedia)
        }
    }

    @Test func inspectRejectsAudioOnlyFile() async throws {
        let dir = isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = try await makeAudioOnly(in: dir)
        let importer = try MediaImporter(store: store(at: dir))

        do {
            _ = try await importer.inspect(audio)
            Issue.record("expected inspect to throw for an audio-only file")
        } catch let error as MediaImporter.ImportError {
            #expect(error == .noVideoTrack)
        }
    }

    @Test func importErrorMessagesAreHumanReadable() {
        #expect(
            MediaImporter.ImportError.noVideoTrack.errorDescription?
                .contains("no video track") == true)
        #expect(!(MediaImporter.ImportError.invalidDuration.errorDescription?.isEmpty ?? true))
        #expect(!(MediaImporter.ImportError.unsupportedMedia.errorDescription?.isEmpty ?? true))
        #expect(!(MediaImporter.ImportError.posterGenerationFailed.errorDescription?.isEmpty ?? true))
    }

    @Test func recommendationsFlagLongHeavyAndFastSources() {
        func inspection(duration: TimeInterval, fps: Double, fileSize: Int64) -> ImportInspection {
            ImportInspection(
                duration: duration, framesPerSecond: fps,
                pixelSize: CGSize(width: 3840, height: 2160),
                fileSize: fileSize, contentHash: String(repeating: "a", count: 64),
                containsAudio: false
            )
        }
        #expect(
            inspection(duration: 61, fps: 30, fileSize: 10).recommendations.contains {
                $0.contains("Long loops")
            })
        #expect(
            inspection(duration: 5, fps: 30, fileSize: 201 * 1_024 * 1_024).recommendations.contains {
                $0.contains("200 MB")
            })
        #expect(
            inspection(duration: 5, fps: 240, fileSize: 10).recommendations.contains {
                $0.contains("120 FPS")
            })
        #expect(inspection(duration: 5, fps: 30, fileSize: 10).recommendations.isEmpty)
    }

    // MARK: - Helpers

    private func isolatedDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    /// What the library folder holds, so a stray staged copy shows.
    private func libraryItems(in dir: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("Library").path))
    }

    private func store(at dir: URL) throws -> LibraryStore {
        try LibraryStore(rootURL: dir.appendingPathComponent("Library", isDirectory: true))
    }

    private func makeVideo(withAudio: Bool, in dir: URL? = nil, name: String = "source.mov") async throws -> URL {
        try await TestVideos.makeVideo(withAudio: withAudio, in: dir, name: name)
    }

    private func makeAudioOnly(in dir: URL, name: String = "tone.wav") async throws -> URL {
        try TestVideos.makeSilenceWAV(in: dir, name: name)
    }
}
