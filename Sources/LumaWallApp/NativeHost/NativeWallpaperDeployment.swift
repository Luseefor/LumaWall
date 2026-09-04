import AVFoundation
import AppKit
import CryptoKit
import Foundation
import LumaWallCore

enum NativeWallpaperDeployment {
    struct EntryInfo: Codable, Equatable, Sendable {
        let id: String
        var name: String
        var filename: String
        var duration: Double
        var fps: Double
        var resolution: CGSize
        var dateAdded: Date
        var contentHash: String?
        var audioStripped: Bool?
    }

    static var videosFolderURL: URL {
        WallpaperHostCapabilities.extensionDocumentsURL.appendingPathComponent("videos", isDirectory: true)
    }

    static func videoURL(for entry: EntryInfo) -> URL {
        videosFolderURL.appendingPathComponent(entry.id, isDirectory: true)
            .appendingPathComponent(entry.filename)
    }

    @MainActor
    static func ensureDeployed(asset: WallpaperAsset) async throws -> EntryInfo {
        let entryID = asset.id.rawValue.uuidString
        guard PathSafety.isValidEntryID(entryID) else {
            throw DeploymentError.invalidEntry
        }

        let hash = try await contentHash(for: asset.mediaURL)
        if let existing = entry(id: entryID),
           FileManager.default.fileExists(atPath: videoURL(for: existing).path),
           existing.contentHash == hash {
            return existing
        }

        // Stage the (potentially large) video file off the main actor. The old
        // code copied gigabytes on MainActor, stalling the UI + watchdog.
        let staged = try await Task.detached(priority: .utility) {
            let fm = FileManager.default
            try fm.createDirectory(at: videosFolderURL, withIntermediateDirectories: true)
            let dir = videosFolderURL.appendingPathComponent(entryID, isDirectory: true)
            if fm.fileExists(atPath: dir.path) {
                try fm.removeItem(at: dir)
            }
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let filename = PathSafety.isSafeComponent(asset.mediaURL.lastPathComponent)
                ? asset.mediaURL.lastPathComponent
                : "Wallpaper.mov"
            let dest = dir.appendingPathComponent(filename)
            try fm.copyItem(at: asset.mediaURL, to: dest)
            return (dir: dir, dest: dest, filename: filename)
        }.value

        let probe = try await probe(url: staged.dest)
        let entry = EntryInfo(
            id: entryID,
            name: asset.name,
            filename: staged.filename,
            duration: probe.duration,
            fps: probe.fps,
            resolution: probe.resolution,
            dateAdded: asset.createdAt,
            contentHash: hash,
            audioStripped: false
        )
        let data = try JSONEncoder().encode(entry)
        try data.write(to: staged.dir.appendingPathComponent("metadata.json"), options: .atomic)
        await generateThumbnail(for: staged.dest, in: staged.dir)
        notifyLibraryChanged()
        return entry
    }

    static func entry(id: String) -> EntryInfo? {
        let metadataURL = videosFolderURL
            .appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent("metadata.json")
        guard let data = try? Data(contentsOf: metadataURL) else { return nil }
        return try? JSONDecoder().decode(EntryInfo.self, from: data)
    }

    static func notifyLibraryChanged() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(
            center,
            CFNotificationName("app.lumawall.personal.libraryChanged" as CFString),
            nil,
            nil,
            true
        )
    }

    private struct Probe {
        let duration: Double
        let fps: Double
        let resolution: CGSize
    }

    private static func probe(url: URL) async throws -> Probe {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw DeploymentError.noVideoTrack
        }
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let transformed = naturalSize.applying(transform)
        let resolution = CGSize(width: abs(transformed.width), height: abs(transformed.height))
        let fps = Double(try await track.load(.nominalFrameRate))
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        guard duration.isFinite, duration > 0 else { throw DeploymentError.invalidDuration }
        return Probe(duration: duration, fps: fps, resolution: resolution)
    }

    private static func contentHash(for url: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let data = try handle.read(upToCount: 1_024 * 1_024), !data.isEmpty {
                try Task.checkCancellation()
                hasher.update(data: data)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }

    @MainActor
    private static func generateThumbnail(for videoURL: URL, in directory: URL) async {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 360)
        guard let cgImage = try? await generator.image(at: .zero).image else { return }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { return }
        try? jpeg.write(to: directory.appendingPathComponent("thumbnail.jpg"), options: .atomic)
    }

    enum DeploymentError: LocalizedError {
        case invalidEntry, noVideoTrack, invalidDuration
        var errorDescription: String? {
            switch self {
            case .invalidEntry: "Could not prepare that wallpaper for the system host."
            case .noVideoTrack: "That file has no video track."
            case .invalidDuration: "That video duration is invalid."
            }
        }
    }
}

enum PathSafety {
    static func isValidEntryID(_ id: String) -> Bool { UUID(uuidString: id) != nil }

    static func isSafeComponent(_ name: String) -> Bool {
        if name.isEmpty || name == "." || name == ".." { return false }
        if name.contains("/") || name.contains("\\") { return false }
        if name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) { return false }
        return (name as NSString).lastPathComponent == name
    }
}
