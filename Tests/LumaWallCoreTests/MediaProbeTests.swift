import CoreGraphics
import Foundation
import Synchronization
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

        let full = try await probe.posterFrame(
            open(video), typeIdentifier: "com.apple.quicktime-movie", maxPixelSize: nil, nearStart: false)
        #expect(full.width == 1280 && full.height == 720)
        #expect(full.makeImage()?.width == 1280)
        let small = try await probe.posterFrame(
            open(video), typeIdentifier: "com.apple.quicktime-movie", maxPixelSize: CGSize(width: 640, height: 360),
            nearStart: true)
        #expect(small.width <= 640 && small.height <= 360)
        #expect(small.pixels.count == small.bytesPerRow * small.height)
    }

    @Test func anAssetKeepsReadingAfterItsSourceIsReleased() async throws {
        // The resource loader holds its delegate weakly, and Swift may
        // release `HandleBackedAsset` right after its last use, before
        // AVFoundation asks for bytes. A load must not depend on it.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = try await TestVideos.makeVideo(withAudio: false, in: dir)
        let asset = try HandleBackedAsset(file: open(video), typeIdentifier: "com.apple.quicktime-movie").asset
        let tracks = Mutex<Int?>(nil)
        await awaitWithDeadline(.seconds(10)) {
            let count = try? await asset.loadTracks(withMediaType: .video).count
            tracks.withLock { $0 = count }
        }
        #expect(tracks.withLock { $0 } == 1)
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

    @Test func oversizedRepliesAreRefusedBeforeDecoding() throws {
        // A compromised service could make the app parse an arbitrarily
        // large reply; the byte count is checked first.
        let big = Data(repeating: 0x20, count: 20_000)
        #expect(throws: MediaProbeError.serviceUnavailable) {
            try MediaServiceContract.decode(MediaInfo.self, reply: big, error: nil, maxReplyBytes: 16_384)
        }
        #expect(throws: MediaProbeError.serviceUnavailable) {
            try MediaServiceContract.decode(MediaInfo.self, reply: nil, error: big, maxReplyBytes: 16_384)
        }
        let info = MediaInfo(
            videoTrackCount: 1, audioTrackCount: 0, pixelSize: CGSize(width: 10, height: 10), duration: 1, framesPerSecond: 30)
        let (reply, _) = MediaServiceContract.encode(Result<MediaInfo, MediaProbeError>.success(info))
        #expect(try MediaServiceContract.decode(MediaInfo.self, reply: reply, error: nil, maxReplyBytes: 16_384) == info)
        let (_, failure) = MediaServiceContract.encode(Result<MediaInfo, MediaProbeError>.failure(.noVideoTrack))
        #expect(throws: MediaProbeError.noVideoTrack) {
            try MediaServiceContract.decode(MediaInfo.self, reply: nil, error: failure, maxReplyBytes: 16_384)
        }
    }

    @Test func aPosterReplyIsBoundedByTheSizeAsked() {
        let box = CGSize(width: 640, height: 360)
        // Pixels plus base64 overhead for the largest frame that fits.
        #expect(MediaServiceContract.maxPosterReplyBytes(fitting: box) >= 640 * 360 * 4 * 4 / 3)
        #expect(MediaServiceContract.maxPosterReplyBytes(fitting: box) < 640 * 360 * 4 * 2)
        #expect(MediaServiceContract.maxPosterReplyBytes(fitting: nil) >= 4_096 * 4_096 * 4 * 4 / 3)
        let fits = PosterFrame(width: 640, height: 360, bytesPerRow: 2_560, pixels: Data())
        let wider = PosterFrame(width: 1_280, height: 360, bytesPerRow: 5_120, pixels: Data())
        #expect(fits.fits(box))
        #expect(!wider.fits(box))
        #expect(wider.fits(nil))
    }

    @Test func aWhiteFrameFitsItsReplyLimit() throws {
        // Base64 of 0xFF bytes is all slashes, which JSON may escape.
        let box = CGSize(width: 320, height: 200)
        let white = PosterFrame(width: 320, height: 180, bytesPerRow: 1_280, pixels: Data(repeating: 0xFF, count: 1_280 * 180))
        let (reply, _) = MediaServiceContract.encode(Result<PosterFrame, MediaProbeError>.success(white))
        let limit = MediaServiceContract.maxPosterReplyBytes(fitting: box)
        #expect(try MediaServiceContract.decode(PosterFrame.self, reply: reply, error: nil, maxReplyBytes: limit).pixels == white.pixels)
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
