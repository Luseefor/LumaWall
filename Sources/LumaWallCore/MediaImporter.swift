import AVFoundation
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
        case mediaReaderStopped

        init(_ error: MediaProbeError) {
            switch error {
            case .noVideoTrack: self = .noVideoTrack
            case .invalidDuration: self = .invalidDuration
            case .unsupportedMedia: self = .unsupportedMedia
            case .posterUnavailable: self = .posterGenerationFailed
            case .serviceUnavailable: self = .mediaReaderStopped
            }
        }

        public var errorDescription: String? {
            switch self {
            case .noVideoTrack: "The selected file contains no video track."
            case .invalidDuration: "The video has an invalid duration."
            case .unsupportedMedia: "This video cannot be prepared for wallpaper playback."
            case .posterGenerationFailed: "LumaWall could not create a poster frame."
            case .mediaReaderStopped: "LumaWall's media reader stopped before it finished reading this video."
            }
        }
    }

    private let store: LibraryStore

    /// Parses media for the importer. The app passes its sandboxed media
    /// service; LumaWallCore's tests pass `LocalMediaProbe`.
    private let probe: any MediaProbing

    public init(store: LibraryStore, probe: any MediaProbing) {
        self.store = store
        self.probe = probe
    }

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
            fileSize: fileSize, contentHash: Self.sha256(of: sourceURL), containsAudio: media.hasAudio)
    }

    private func inspectMedia(_ url: URL) async throws -> MediaInfo {
        do {
            return try await probe.inspect(fileAt: url)
        } catch let error as MediaProbeError {
            throw ImportError(error)
        }
    }

    /// Copies the source into a staging folder once, then
    /// inspects, hashes and stores only that copy. A source swapped or
    /// rewritten after the copy can't change what was checked.
    public func importVideo(_ sourceURL: URL, preferredName: String? = nil) async throws -> ImportOutcome {
        guard sourceURL.isFileURL else { throw VerifiedFileCopy.CopyError.notALocalFile }
        // A fresh system folder on the library's volume: outside Scratch,
        // which Clear Disk Cache empties, and never shared with another
        // import, so the staged copy can be moved into the library.
        let staging = try FileManager.default.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: store.rootURL, create: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let ext = sourceURL.pathExtension.isEmpty ? "mov" : sourceURL.pathExtension.lowercased()
        let staged = staging.appendingPathComponent("\(UUID().uuidString).\(ext)")
        let copy = try await Task.detached(priority: .userInitiated) {
            try VerifiedFileCopy.copy(from: sourceURL, to: staged)
        }.value
        let media = try await inspectMedia(staged)
        let inspection = ImportInspection(
            duration: media.duration, framesPerSecond: media.framesPerSecond, pixelSize: media.pixelSize,
            fileSize: copy.size, contentHash: copy.sha256, containsAudio: media.hasAudio)
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

    /// The first frame, read by the media probe and encoded here from the
    /// plain pixels it returns.
    private func generatePoster(for mediaURL: URL, outputURL: URL) async throws {
        let frame: PosterFrame
        do {
            frame = try await probe.posterFrame(fileAt: mediaURL)
        } catch let error as MediaProbeError {
            throw ImportError(error)
        }
        guard let image = frame.makeImage(),
            let destination = CGImageDestinationCreateWithURL(
                outputURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil
            )
        else { throw ImportError.posterGenerationFailed }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImportError.posterGenerationFailed }
    }

    private nonisolated static func sha256(of url: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            try VerifiedFileCopy.sha256(ofFileAt: url).sha256
        }.value
    }
}
