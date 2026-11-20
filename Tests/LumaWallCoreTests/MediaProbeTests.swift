import CoreGraphics
import Foundation
import Testing

@testable import LumaWallCore

/// The probe the sandboxed media service runs. It only gets an open file
/// handle, never a path, so every read goes through the handle.
@Suite(.serialized)
struct MediaProbeTests {
    private func open(_ url: URL) throws -> FileHandle { try FileHandle(forReadingFrom: url) }

    @Test func inspectsAVideoThroughItsFileHandle() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let silent = try await TestVideos.makeVideo(withAudio: false, in: dir, name: "silent.mov")
        let loud = try await TestVideos.makeVideo(withAudio: true, in: dir, name: "loud.mov")
        let probe = LocalMediaProbe()

        let info = try await probe.inspect(open(silent), typeIdentifier: "com.apple.quicktime-movie")
        #expect(info.videoTrackCount == 1)
        #expect(!info.hasAudio)
        #expect(info.pixelSize == CGSize(width: 1280, height: 720))
        #expect(abs(info.duration - 1) < 0.25)
        #expect(abs(info.framesPerSecond - 30) < 1)
        #expect(try await probe.inspect(open(loud), typeIdentifier: "com.apple.quicktime-movie").hasAudio)
    }

    @Test func extractsAPosterFrameAsPlainPixels() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = try await TestVideos.makeVideo(withAudio: false, in: dir)
        let probe = LocalMediaProbe()

        let full = try await probe.posterFrame(open(video), typeIdentifier: "com.apple.quicktime-movie", maxPixelSize: nil)
        #expect(full.width == 1280 && full.height == 720)
        #expect(full.makeImage()?.width == 1280)
        let small = try await probe.posterFrame(
            open(video), typeIdentifier: "com.apple.quicktime-movie", maxPixelSize: CGSize(width: 640, height: 360))
        #expect(small.width <= 640 && small.height <= 360)
        #expect(small.pixels.count == small.bytesPerRow * small.height)
    }

    @Test func refusesAFileWithoutVideo() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let text = dir.appendingPathComponent("notes.mov")
        try Data("not a movie".utf8).write(to: text)
        let audio = try TestVideos.makeSilenceWAV(in: dir)
        let probe = LocalMediaProbe()

        await #expect(throws: MediaProbeError.unsupportedMedia) {
            try await probe.inspect(open(text), typeIdentifier: "com.apple.quicktime-movie")
        }
        await #expect(throws: MediaProbeError.noVideoTrack) {
            try await probe.inspect(open(audio), typeIdentifier: "com.microsoft.waveform-audio")
        }
    }

    @Test func pixelsThatDontMatchTheirSizeMakeNoImage() {
        // The app builds images from what the service returns; a reply that
        // lies about its size must not be read past its end.
        let short = PosterFrame(width: 100, height: 100, bytesPerRow: 400, pixels: Data(count: 10))
        let narrowRows = PosterFrame(width: 100, height: 1, bytesPerRow: 40, pixels: Data(count: 40))
        let huge = PosterFrame(width: 100_000, height: 100_000, bytesPerRow: 400_000, pixels: Data())
        #expect(short.makeImage() == nil)
        #expect(narrowRows.makeImage() == nil)
        #expect(huge.makeImage() == nil)
        #expect(PosterFrame(width: 2, height: 2, bytesPerRow: 8, pixels: Data(count: 16)).makeImage() != nil)
    }

    @Test func infoOutsideSaneBoundsIsRejected() {
        var info = MediaInfo(
            videoTrackCount: 1, audioTrackCount: 0, pixelSize: CGSize(width: 1920, height: 1080), duration: 10,
            framesPerSecond: 30)
        #expect(info.isPlausible)
        info.duration = .infinity
        #expect(!info.isPlausible)
        info.duration = 10
        info.pixelSize = CGSize(width: -1, height: 1080)
        #expect(!info.isPlausible)
    }
}
