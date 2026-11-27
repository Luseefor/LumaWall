import AVFoundation
import AVFAudio
import CoreMedia
import CoreVideo
import Foundation
@testable import LumaWallCore

/// Synthesized test media: encoded in-test with `AVAssetWriter`, so no
/// fixtures and no production data.
enum TestVideos {
    /// Encodes a 1-second 1280×720 black H.264 movie, optionally with a silent
    /// mono AAC track, and returns its URL.
    static func makeVideo(withAudio: Bool, in dir: URL? = nil, name: String = "source.mov") async throws -> URL {
        let dir =
            try dir.map {
                try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true)
                return $0
            } ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 1280,
            AVVideoHeightKey: 720,
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 1280,
                kCVPixelBufferHeightKey as String: 720,
            ]
        )
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if withAudio {
            var asbd = AudioStreamBasicDescription(
                mSampleRate: 44_100, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0
            )
            var format: CMFormatDescription?
            guard
                CMAudioFormatDescriptionCreate(
                    allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0,
                    layout: nil, magicCookieSize: 0, magicCookie: nil,
                    extensions: nil, formatDescriptionOut: &format
                ) == noErr, let format
            else { throw MediaImporter.ImportError.unsupportedMedia }
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 44_100,
                    AVNumberOfChannelsKey: 1,
                ], sourceFormatHint: format)
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioInput = input
        }

        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let frames = 30
        for frame in 0..<frames {
            try await waitUntilReady(videoInput, writer)
            let buffer = try makeBlackPixelBuffer()
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        if let audioInput {
            try await waitUntilReady(audioInput, writer)
            // Feed silence decoded from a WAV via AVAssetReader, so every
            // appended buffer is well-formed by construction (hand-rolled
            // CMSampleBuffers segfaulted the runner).
            let silence = try makeSilenceWAV(in: dir)
            let readerAsset = AVURLAsset(url: silence)
            guard let audioTrack = try await readerAsset.loadTracks(withMediaType: .audio).first else {
                throw MediaImporter.ImportError.unsupportedMedia
            }
            let reader = try AVAssetReader(asset: readerAsset)
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            reader.add(output)
            reader.startReading()
            while let sample = output.copyNextSampleBuffer() {
                try await waitUntilReady(audioInput, writer)
                audioInput.append(sample)
            }
        }
        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        await finishWriting(writer)
        guard writer.status == .completed else {
            throw MediaImporter.ImportError.unsupportedMedia
        }
        return url
    }

    /// Waits for `input` to take more data. Throws if the writer fails or
    /// the input isn't ready within 10 seconds, so a broken writer fails
    /// the test instead of spinning forever.
    private static func waitUntilReady(_ input: AVAssetWriterInput, _ writer: AVAssetWriter) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !input.isReadyForMoreMediaData {
            guard writer.status == .writing, ContinuousClock.now < deadline else {
                throw MediaImporter.ImportError.unsupportedMedia
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    /// Finish an `AVAssetWriter` via its completion-handler API. The async
    /// `finishWriting()` overlay traps in this environment (checked
    /// continuation resumed twice through KVO); the handler form is reliable.
    private static func finishWriting(_ writer: AVAssetWriter) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting {
                continuation.resume()
            }
        }
    }

    /// Encodes a 1-second silent mono WAV (no video track) and returns its URL.
    /// Written with AVAudioFile (safe high-level API), never hand-rolled buffers.
    static func makeSilenceWAV(in dir: URL, name: String = "tone.wav") throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1) else {
            throw MediaImporter.ImportError.unsupportedMedia
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100) else {
            throw MediaImporter.ImportError.unsupportedMedia
        }
        buffer.frameLength = buffer.frameCapacity
        memset(buffer.floatChannelData![0], 0, Int(buffer.frameLength) * MemoryLayout<Float>.size)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    private static func makeBlackPixelBuffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        guard
            CVPixelBufferCreate(
                kCFAllocatorDefault, 1280, 720, kCVPixelFormatType_32BGRA, nil, &buffer
            ) == kCVReturnSuccess, let buffer
        else {
            throw MediaImporter.ImportError.unsupportedMedia
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        memset(CVPixelBufferGetBaseAddress(buffer), 0, CVPixelBufferGetDataSize(buffer))
        return buffer
    }
}
