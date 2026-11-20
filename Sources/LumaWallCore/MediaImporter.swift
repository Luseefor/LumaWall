import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct ImportInspection: Sendable {
    public let duration: TimeInterval
    public let framesPerSecond: Double
    public let pixelSize: CGSize
    public let fileSize: Int64
    public let contentHash: String
    public let containsAudio: Bool

    public var recommendations: [String] {
        var messages: [String] = []
        if max(pixelSize.width, pixelSize.height) < 1_920 {
            messages.append("The source is below 1080p and may look soft on Retina displays.")
        }
        if duration > 60 { messages.append("Long loops use more storage and take longer to optimize.") }
        if fileSize > 200 * 1_024 * 1_024 { messages.append("This source is larger than 200 MB.") }
        if framesPerSecond > 120 { messages.append("Frame rates above 120 FPS use more GPU.") }
        return messages
    }
}

public struct ImportOutcome: Sendable {
    public let asset: WallpaperAsset
    public let inspection: ImportInspection
    public let removedAudio: Bool
}

public actor MediaImporter {
    public enum ImportError: LocalizedError, Equatable {
        case noVideoTrack
        case invalidDuration
        case unsupportedMedia
        case posterGenerationFailed

        public var errorDescription: String? {
            switch self {
            case .noVideoTrack: "The selected file contains no video track."
            case .invalidDuration: "The video has an invalid duration."
            case .unsupportedMedia: "This video cannot be prepared for wallpaper playback."
            case .posterGenerationFailed: "LumaWall could not create a poster frame."
            }
        }
    }

    private let store: LibraryStore

    public init(store: LibraryStore) { self.store = store }

    /// The URLs a drop or file panel handed over that name local files.
    /// Anything else (a dragged web link) is dropped before AVFoundation can
    /// open it and contact its server.
    public static func localFiles(in urls: [URL]) -> [URL] {
        urls.filter(\.isFileURL)
    }

    /// Reads a video's properties. Only local files are opened.
    public func inspect(_ sourceURL: URL) async throws -> ImportInspection {
        guard sourceURL.isFileURL else { throw VerifiedFileCopy.CopyError.notALocalFile }
        let media = try await inspectMedia(sourceURL)
        let fileSize = Int64(try sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        return try await ImportInspection(
            duration: media.duration, framesPerSecond: media.framesPerSecond, pixelSize: media.pixelSize,
            fileSize: fileSize, contentHash: Self.sha256(of: sourceURL), containsAudio: media.containsAudio)
    }

    private struct MediaInfo {
        let duration: TimeInterval
        let framesPerSecond: Double
        let pixelSize: CGSize
        let containsAudio: Bool
    }

    private func inspectMedia(_ url: URL) async throws -> MediaInfo {
        let asset = AVURLAsset(url: url)
        let videoTracks: [AVAssetTrack]
        do {
            videoTracks = try await asset.loadTracks(withMediaType: .video)
        } catch {
            // AVFoundation surfaces unreadable media as a raw AVError ("Cannot
            // Open"); prefer the friendly message when the file itself exists.
            if FileManager.default.fileExists(atPath: url.path) {
                throw ImportError.unsupportedMedia
            }
            throw error
        }
        guard let track = videoTracks.first else {
            throw ImportError.noVideoTrack
        }
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        guard duration.isFinite, duration > 0 else { throw ImportError.invalidDuration }
        let size = try await track.load(.naturalSize).applying(track.load(.preferredTransform))
        return try await MediaInfo(
            duration: duration,
            framesPerSecond: Double(track.load(.nominalFrameRate)),
            pixelSize: CGSize(width: abs(size.width), height: abs(size.height)),
            containsAudio: !asset.loadTracks(withMediaType: .audio).isEmpty
        )
    }

    /// Copies the source into the library's Scratch folder once, then
    /// inspects, hashes and stores only that copy. A source swapped or
    /// rewritten after the copy can't change what was checked.
    public func importVideo(_ sourceURL: URL, preferredName: String? = nil) async throws -> ImportOutcome {
        guard sourceURL.isFileURL else { throw VerifiedFileCopy.CopyError.notALocalFile }
        let scratch = store.rootURL.appendingPathComponent("Scratch", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let ext = sourceURL.pathExtension.isEmpty ? "mov" : sourceURL.pathExtension.lowercased()
        let staged = scratch.appendingPathComponent("\(UUID().uuidString).\(ext)")
        defer { try? FileManager.default.removeItem(at: staged) }
        let copy = try await Task.detached(priority: .userInitiated) {
            try VerifiedFileCopy.copy(from: sourceURL, to: staged)
        }.value
        let media = try await inspectMedia(staged)
        let inspection = ImportInspection(
            duration: media.duration, framesPerSecond: media.framesPerSecond, pixelSize: media.pixelSize,
            fileSize: copy.size, contentHash: copy.sha256, containsAudio: media.containsAudio)
        if let duplicate = await store.asset(contentHash: inspection.contentHash) {
            throw LibraryStore.StoreError.duplicate(duplicate)
        }

        let id = WallpaperID()
        let folder = await store.folder(for: id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            let mediaURL: URL
            if inspection.containsAudio {
                mediaURL = folder.appendingPathComponent("Wallpaper.mov")
                try await exportVideoOnly(from: staged, to: mediaURL)
            } else {
                mediaURL = folder.appendingPathComponent("Wallpaper.\(ext)")
                try FileManager.default.moveItem(at: staged, to: mediaURL)
            }
            let posterURL = folder.appendingPathComponent("Poster.jpg")
            try await generatePoster(for: mediaURL, outputURL: posterURL)
            let name = preferredName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let asset = WallpaperAsset(
                id: id,
                name: name.flatMap { $0.isEmpty ? nil : $0 }
                    ?? sourceURL.deletingPathExtension().lastPathComponent,
                mediaURL: mediaURL,
                posterURL: posterURL,
                duration: inspection.duration,
                framesPerSecond: inspection.framesPerSecond,
                pixelSize: inspection.pixelSize,
                contentHash: inspection.contentHash,
                containsAudio: false
            )
            try await store.install(asset)
            return ImportOutcome(asset: asset, inspection: inspection, removedAudio: inspection.containsAudio)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            // A poll during the import may have cached the partial folder's size.
            await store.invalidateDiskUsage()
            throw error
        }
    }

    private func exportVideoOnly(from sourceURL: URL, to outputURL: URL) async throws {
        let sourceAsset = AVURLAsset(url: sourceURL)
        guard let sourceTrack = try await sourceAsset.loadTracks(withMediaType: .video).first else {
            throw ImportError.noVideoTrack
        }
        let duration = try await sourceAsset.load(.duration)
        let composition = AVMutableComposition()
        guard
            let destination = composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
            )
        else { throw ImportError.unsupportedMedia }
        try destination.insertTimeRange(.init(start: .zero, duration: duration), of: sourceTrack, at: .zero)
        destination.preferredTransform = try await sourceTrack.load(.preferredTransform)
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw ImportError.unsupportedMedia
        }
        try await exporter.export(to: outputURL, as: .mov)
    }

    private func generatePoster(for mediaURL: URL, outputURL: URL) async throws {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: mediaURL))
        generator.appliesPreferredTrackTransform = true
        let image = try await generator.image(at: .zero).image
        guard
            let destination = CGImageDestinationCreateWithURL(
                outputURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil
            )
        else { throw ImportError.posterGenerationFailed }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImportError.posterGenerationFailed }
    }

    private nonisolated static func sha256(of url: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
                try Task.checkCancellation()
                hasher.update(data: data)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }
}
