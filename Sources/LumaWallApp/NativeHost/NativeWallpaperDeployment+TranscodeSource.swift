import AVFoundation
import Foundation
import LumaWallCore

extension NativeWallpaperDeployment {
    /// App-private copies of deployed videos, for copy encodes to read.
    ///
    /// The deployed video sits in the extension's container, where the
    /// extension can swap it for a symlink to any of the user's files.
    /// AVFoundation opens a source by path, so encoding it in place could
    /// copy that file into staging the extension reads. Instead the deployed
    /// file is copied here first, opened without following a symlink and
    /// hashed as it is copied, and refused unless it hashes to the job's
    /// source. Encodes still read the published bytes, not the library file,
    /// which can change after deploy hashed it.
    ///
    /// A copy is kept for each source the queue still has work for, so a
    /// source another one interrupts isn't copied twice; `release` deletes
    /// it once the queue is done with that source.
    final class TranscodeSources: @unchecked Sendable {
        enum SourceError: Error, Equatable {
            /// The deployed file no longer hashes to the job's source.
            case contentChanged
        }

        let folderURL: URL
        /// Opens a folder of the extension's container without following a
        /// symlink on the way down.
        private let openFolder: @Sendable (URL) throws -> TrustedDirectory
        private let lock = NSLock()
        /// File names of the kept copies, by `Job.sourceKey`.
        private var kept: [String: String] = [:]

        init(folderURL: URL, openFolder: @escaping @Sendable (URL) throws -> TrustedDirectory = { try trustedFolder($0) }) {
            self.folderURL = folderURL
            self.openFolder = openFolder
        }

        /// The private copy of `job`'s source, made on first use and reused
        /// by later jobs for the same source.
        func copy(for job: VariantEncodeQueue.Job) throws -> URL {
            try lock.withLock {
                let folder = try privateFolder()
                if let name = kept[job.sourceKey] {
                    if (try? folder.kind(ofItemNamed: name)) == .file { return folderURL.appendingPathComponent(name) }
                    try? folder.removeItem(named: name)
                    kept[job.sourceKey] = nil
                }
                let source = job.sourceURL
                // AVFoundation goes by the extension to pick a reader.
                let name = UUID().uuidString + "." + (source.pathExtension.isEmpty ? "mov" : source.pathExtension)
                let destination = folderURL.appendingPathComponent(name)
                let entry = try openFolder(source.deletingLastPathComponent())
                let copied = try VerifiedFileCopy.copy(named: source.lastPathComponent, in: entry, to: destination)
                guard copied.sha256 == job.contentHash else {
                    try? folder.removeFile(named: name)
                    throw SourceError.contentChanged
                }
                kept[job.sourceKey] = name
                return destination
            }
        }

        /// Deletes the copy of `job`'s source, if one is kept.
        func release(_ job: VariantEncodeQueue.Job) {
            lock.withLock {
                guard let name = kept.removeValue(forKey: job.sourceKey) else { return }
                try? TrustedDirectory(url: folderURL).removeFile(named: name)
            }
        }

        /// Deletes the copies a previous run left behind, keeping the ones
        /// in use, so it is safe to call while an encode runs.
        func removeLeftovers() {
            lock.withLock {
                guard let folder = try? TrustedDirectory(url: folderURL) else { return }
                let inUse = Set(kept.values)
                for item in (try? folder.entries()) ?? [] where !inUse.contains(item.name) {
                    try? folder.removeItem(named: item.name)
                }
            }
        }

        private func privateFolder() throws -> TrustedDirectory {
            try FileManager.default.createDirectory(
                at: folderURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            return try TrustedDirectory(url: folderURL)
        }
    }

    /// Where `TranscodeSources` keeps its copies: the app's own Application
    /// Support folder, which the sandboxed extension can't read.
    static var transcodeSourcesFolderURL: URL {
        ((try? StorePaths.appSupportBase()) ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("transcode-sources", isDirectory: true)
    }

    static let transcodeSources = TranscodeSources(folderURL: transcodeSourcesFolderURL)

    /// Deletes private copies a crash left behind. Run at launch, since a
    /// later launch may never encode again to clean them up.
    static func removeLeftoverTranscodeSources() {
        Task.detached(priority: .utility) { transcodeSources.removeLeftovers() }
    }

    /// The asset a copy encode reads. A QuickTime movie can refer to media
    /// in other files, which the source's hash doesn't cover, so references
    /// are refused.
    static func transcodeAsset(_ url: URL) -> AVURLAsset {
        AVURLAsset(url: url, options: [AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue])
    }

    /// Runs `encode` on a private copy of `job`'s source from `sources`. A
    /// source that can't be copied safely, or no longer hashes to the job's
    /// source, fails without encoding anything.
    static func exportCopy(
        _ job: VariantEncodeQueue.Job, sources: TranscodeSources,
        encode: (URL) async -> TranscodeResult
    ) async -> TranscodeResult {
        let source: URL
        do {
            source = try sources.copy(for: job)
        } catch {
            return Task.isCancelled || error is CancellationError ? .skipped : .failed
        }
        return await encode(source)
    }
}
