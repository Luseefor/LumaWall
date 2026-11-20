import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// Reads what LumaWall needs from a video: its tracks and timing, and a
/// still frame. Parsing untrusted media is where a decoder exploit would
/// run, so the app does it through `MediaServiceClient`, which hands an
/// open, read-only file handle to a sandboxed XPC service running
/// `LocalMediaProbe`. The service never gets a path and can't open files.
///
/// This file is compiled into LumaWallCore and into the media service.
public protocol MediaProbing: Sendable {
    func inspect(_ file: FileHandle, typeIdentifier: String) async throws -> MediaInfo
    /// A frame scaled to fit `maxPixelSize` when given, with the track's
    /// orientation applied: the first frame, or with `nearStart` the frame
    /// at one second (or mid-way through a shorter video), which skips
    /// black fade-ins.
    func posterFrame(_ file: FileHandle, typeIdentifier: String, maxPixelSize: CGSize?, nearStart: Bool) async throws
        -> PosterFrame
}

extension MediaProbing {
    /// Opens the regular file at `url` read-only and inspects it.
    public func inspect(fileAt url: URL) async throws -> MediaInfo {
        try await inspect(MediaFile.open(url), typeIdentifier: MediaFile.typeIdentifier(for: url))
    }

    public func posterFrame(fileAt url: URL, maxPixelSize: CGSize? = nil, nearStart: Bool = false) async throws -> PosterFrame {
        try await posterFrame(
            MediaFile.open(url), typeIdentifier: MediaFile.typeIdentifier(for: url), maxPixelSize: maxPixelSize,
            nearStart: nearStart)
    }
}

public enum MediaFile {
    /// A read-only handle to the regular file at `url`. FIFOs, devices and
    /// folders are refused without blocking.
    public static func open(_ url: URL) throws -> FileHandle {
        guard url.isFileURL else { throw MediaProbeError.unsupportedMedia }
        let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw MediaProbeError.unsupportedMedia }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        return handle
    }

    /// The type AVFoundation is told the bytes are, from the file name.
    public static func typeIdentifier(for url: URL) -> String {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()), type.conforms(to: .audiovisualContent)
        else { return UTType.quickTimeMovie.identifier }
        return type.identifier
    }
}

public struct MediaInfo: Codable, Equatable, Sendable {
    public var videoTrackCount: Int
    public var audioTrackCount: Int
    /// Oriented size of the first video track.
    public var pixelSize: CGSize
    public var duration: TimeInterval
    public var framesPerSecond: Double

    public init(
        videoTrackCount: Int, audioTrackCount: Int, pixelSize: CGSize, duration: TimeInterval, framesPerSecond: Double
    ) {
        self.videoTrackCount = videoTrackCount
        self.audioTrackCount = audioTrackCount
        self.pixelSize = pixelSize
        self.duration = duration
        self.framesPerSecond = framesPerSecond
    }

    public var hasAudio: Bool { audioTrackCount > 0 }

    /// The service's reply is checked like any outside input: finite,
    /// positive, and within sizes no real video exceeds.
    public var isPlausible: Bool {
        let limit: CGFloat = 32_768
        return videoTrackCount > 0 && audioTrackCount >= 0
            && pixelSize.width.isFinite && pixelSize.height.isFinite
            && pixelSize.width > 0 && pixelSize.height > 0 && pixelSize.width <= limit && pixelSize.height <= limit
            && duration.isFinite && duration > 0 && duration < 30 * 24 * 3600
            && framesPerSecond.isFinite && framesPerSecond >= 0 && framesPerSecond <= 1_000
    }
}

/// A still frame as 32-bit BGRA pixels with premultiplied alpha. Plain
/// pixels, not JPEG or PNG, so the app never runs an image decoder on bytes
/// the service produced.
public struct PosterFrame: Codable, Sendable {
    /// Largest side the service returns: 64 MB of pixels at most per reply.
    public static let maxSide = 4_096

    public var width: Int
    public var height: Int
    public var bytesPerRow: Int
    public var pixels: Data

    public init(width: Int, height: Int, bytesPerRow: Int, pixels: Data) {
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.pixels = pixels
    }

    /// The frame as an image, or nil when the sizes don't describe the
    /// bytes exactly.
    public func makeImage() -> CGImage? {
        guard width > 0, height > 0, width <= Self.maxSide, height <= Self.maxSide,
            bytesPerRow >= width * 4, bytesPerRow <= width * 4 + 64,
            pixels.count == bytesPerRow * height,
            let provider = CGDataProvider(data: pixels as CFData)
        else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

public enum MediaProbeError: Error, Codable, Equatable, LocalizedError {
    case noVideoTrack
    case invalidDuration
    case unsupportedMedia
    case posterUnavailable
    /// The media service couldn't be reached or stopped mid-request.
    case serviceUnavailable

    public var errorDescription: String? {
        switch self {
        case .noVideoTrack: "The selected file contains no video track."
        case .invalidDuration: "The video has an invalid duration."
        case .unsupportedMedia: "This video cannot be prepared for wallpaper playback."
        case .posterUnavailable: "LumaWall could not create a poster frame."
        case .serviceUnavailable: "LumaWall's media reader stopped unexpectedly."
        }
    }
}
