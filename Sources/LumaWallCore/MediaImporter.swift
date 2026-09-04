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
    public enum ImportError: LocalizedError {
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

    public func inspect(_ sourceURL: URL) async throws -> ImportInspection {
        let asset = AVURLAsset(url: sourceURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ImportError.noVideoTrack
        }
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        guard duration.isFinite, duration > 0 else { throw ImportError.invalidDuration }
        let size = try await track.load(.naturalSize).applying(track.load(.preferredTransform))
        let fileSize = Int64(try sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        async let hash = Self.sha256(of: sourceURL)
        async let audioTracks = asset.loadTracks(withMediaType: .audio)
        return try await ImportInspection(
            duration: duration,
            framesPerSecond: Double(track.load(.nominalFrameRate)),
            pixelSize: CGSize(width: abs(size.width), height: abs(size.height)),
            fileSize: fileSize,
            contentHash: hash,
            containsAudio: !audioTracks.isEmpty
        )
    }

    public func importVideo(_ sourceURL: URL, preferredName: String? = nil) async throws -> ImportOutcome {
        let inspection = try await inspect(sourceURL)
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
                try await exportVideoOnly(from: sourceURL, to: mediaURL)
            } else {
                let ext = sourceURL.pathExtension.isEmpty ? "mov" : sourceURL.pathExtension.lowercased()
                mediaURL = folder.appendingPathComponent("Wallpaper.\(ext)")
                try FileManager.default.copyItem(at: sourceURL, to: mediaURL)
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
        guard let destination = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw ImportError.unsupportedMedia }
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
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ) else { throw ImportError.posterGenerationFailed }
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
