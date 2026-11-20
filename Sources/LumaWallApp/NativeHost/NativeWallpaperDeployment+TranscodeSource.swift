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
    /// One copy is kept at a time, for the source the queue is encoding;
    /// `release` deletes it once the queue moves on.
    final class TranscodeSources: @unchecked Sendable {
        enum SourceError: Error, Equatable {
            /// The deployed file no longer hashes to the job's source.
            case contentChanged
        }

        let folderURL: URL
        private let lock = NSLock()
        private var current: (key: String, name: String)?

        init(folderURL: URL) { self.folderURL = folderURL }

        /// The private copy of `job`'s source, made on first use and reused
        /// by later jobs for the same source.
        func copy(for job: VariantEncodeQueue.Job) throws -> URL {
            try lock.withLock {
                let folder = try privateFolder()
                if let current, current.key == job.sourceKey, (try? folder.kind(ofItemNamed: current.name)) == .file {
                    return folderURL.appendingPathComponent(current.name)
                }
                removeCurrent(from: folder)
                let source = job.sourceURL
                // AVFoundation goes by the extension to pick a reader.
                let name = UUID().uuidString + "." + (source.pathExtension.isEmpty ? "mov" : source.pathExtension)
                let destination = folderURL.appendingPathComponent(name)
                let entry = try trustedFolder(source.deletingLastPathComponent())
                let copied = try VerifiedFileCopy.copy(named: source.lastPathComponent, in: entry, to: destination)
                guard copied.sha256 == job.contentHash else {
                    try? folder.removeFile(named: name)
                    throw SourceError.contentChanged
                }
                current = (job.sourceKey, name)
                return destination
            }
        }

        /// Deletes the copy of `job`'s source, if it is the one kept.
        func release(_ job: VariantEncodeQueue.Job) {
            lock.withLock {
                guard current?.key == job.sourceKey, let folder = try? TrustedDirectory(url: folderURL) else { return }
                removeCurrent(from: folder)
            }
        }

        /// Deletes every copy, including ones a previous run left behind.
        func removeAll() {
            lock.withLock {
                current = nil
                let parent = try? TrustedDirectory(url: folderURL.deletingLastPathComponent())
                try? parent?.removeItem(named: folderURL.lastPathComponent)
            }
        }

        private func removeCurrent(from folder: TrustedDirectory) {
            if let current { try? folder.removeFile(named: current.name) }
            current = nil
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
