import AVFoundation
import CoreGraphics
import Foundation

/// `MediaProbing` with AVFoundation, reading only through the handle it is
/// given. The asset uses a private URL scheme served by a resource loader
/// that answers byte-range requests with `pread` on the handle, so this
/// works inside a sandbox that grants no file access at all.
///
/// The media service runs this. LumaWallCore's tests run it in-process.
public struct LocalMediaProbe: MediaProbing {
    public init() {}

    public func inspect(_ file: FileHandle, typeIdentifier: String) async throws -> MediaInfo {
        let source = try HandleBackedAsset(file: file, typeIdentifier: typeIdentifier)
        let asset = source.asset
        let videoTracks: [AVAssetTrack]
        do {
            videoTracks = try await asset.loadTracks(withMediaType: .video)
        } catch {
            throw MediaProbeError.unsupportedMedia
        }
        guard let track = videoTracks.first else { throw MediaProbeError.noVideoTrack }
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        guard duration.isFinite, duration > 0 else { throw MediaProbeError.invalidDuration }
        let size = try await track.load(.naturalSize).applying(track.load(.preferredTransform))
        let audio = try await asset.loadTracks(withMediaType: .audio)
        return try await MediaInfo(
            videoTrackCount: videoTracks.count,
            audioTrackCount: audio.count,
            pixelSize: CGSize(width: abs(size.width), height: abs(size.height)),
            duration: duration,
            framesPerSecond: Double(track.load(.nominalFrameRate))
        )
    }

    public func posterFrame(_ file: FileHandle, typeIdentifier: String, maxPixelSize: CGSize?, nearStart: Bool) async throws
        -> PosterFrame
    {
        let source = try HandleBackedAsset(file: file, typeIdentifier: typeIdentifier)
        let generator = AVAssetImageGenerator(asset: source.asset)
        generator.appliesPreferredTrackTransform = true
        let side = CGFloat(PosterFrame.maxSide)
        let requested = maxPixelSize ?? CGSize(width: side, height: side)
        generator.maximumSize = CGSize(width: min(requested.width, side), height: min(requested.height, side))
        var time = CMTime.zero
        if nearStart {
            let duration = (try? await source.asset.load(.duration).seconds) ?? 0
            let seconds = duration.isFinite && duration > 0 ? min(1, duration / 2) : 0
            time = CMTime(seconds: seconds, preferredTimescale: 600)
        }
        let image: CGImage
        do {
            image = try await generator.image(at: time).image
        } catch {
            throw MediaProbeError.posterUnavailable
        }
        return try Self.pixels(of: image)
    }

    /// Redraws `image` into a BGRA buffer the app can wrap without decoding.
    static func pixels(of image: CGImage) throws -> PosterFrame {
        let width = min(image.width, PosterFrame.maxSide)
        let height = min(image.height, PosterFrame.maxSide)
        let bytesPerRow = width * 4
        var data = Data(count: bytesPerRow * height)
        let drawn = data.withUnsafeMutableBytes { raw -> Bool in
            guard
                let context = CGContext(
                    data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                    space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn, width > 0, height > 0 else { throw MediaProbeError.posterUnavailable }
        return PosterFrame(width: width, height: height, bytesPerRow: bytesPerRow, pixels: data)
    }
}

/// An `AVURLAsset` whose bytes come from an open file handle. The asset
/// holds its resource loader: AVFoundation holds the delegate only weakly,
/// so whoever keeps the asset (a generator, a pending load) keeps it served.
final class HandleBackedAsset: Sendable {
    let asset: AVURLAsset

    init(file: FileHandle, typeIdentifier: String) throws {
        var info = stat()
        guard fstat(file.fileDescriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw MediaProbeError.unsupportedMedia
        }
        let loader = HandleResourceLoader(file: file, length: Int64(info.st_size), typeIdentifier: typeIdentifier)
        // The scheme only has to be one AVFoundation doesn't load itself, so
        // every read goes to the delegate.
        asset = LoaderOwningAsset(url: URL(string: "lumawall-media://source/media")!, loader: loader)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
    }
}

private final class LoaderOwningAsset: AVURLAsset, @unchecked Sendable {
    private let loader: HandleResourceLoader

    init(url: URL, loader: HandleResourceLoader) {
        self.loader = loader
        super.init(url: url, options: nil)
    }
}

/// Serves AVFoundation's byte-range requests from the handle.
private final class HandleResourceLoader: NSObject, AVAssetResourceLoaderDelegate, Sendable {
    let queue = DispatchQueue(label: "app.lumawall.media-probe.loader")
    private let file: FileHandle
    private let length: Int64
    private let typeIdentifier: String

    init(file: FileHandle, length: Int64, typeIdentifier: String) {
        self.file = file
        self.length = length
        self.typeIdentifier = typeIdentifier
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        if let info = loadingRequest.contentInformationRequest {
            info.contentType = typeIdentifier
            info.contentLength = length
            info.isByteRangeAccessSupported = true
        }
        if let request = loadingRequest.dataRequest {
            var offset = request.currentOffset
            let end =
                request.requestsAllDataToEndOfResource
                ? length : min(length, request.requestedOffset + Int64(request.requestedLength))
            let chunk = 1 << 20
            var buffer = [UInt8](repeating: 0, count: chunk)
            while offset < end, !loadingRequest.isCancelled {
                let want = Int(min(Int64(chunk), end - offset))
                let got = buffer.withUnsafeMutableBytes { pread(file.fileDescriptor, $0.baseAddress, want, off_t(offset)) }
                guard got > 0 else {
                    loadingRequest.finishLoading(with: MediaProbeError.unsupportedMedia)
                    return true
                }
                request.respond(with: Data(buffer[0..<got]))
                offset += Int64(got)
            }
        }
        loadingRequest.finishLoading()
        return true
    }
}
