import CryptoKit
import Darwin
import Foundation

/// Copies a video into LumaWall's own folders and hashes the bytes as they
/// are written.
///
/// Checking a file by path and then copying it by path lets the file change
/// in between, so the checked bytes and the stored bytes can differ. Here
/// the source is opened once, checked to be a regular file through that
/// descriptor, and the copy and its hash come from the same reads. Callers
/// then inspect and publish the copy, never the source again.
public enum VerifiedFileCopy {
    public enum CopyError: LocalizedError, Equatable {
        case notALocalFile
        case notARegularFile

        public var errorDescription: String? {
            switch self {
            case .notALocalFile: "Only files on this Mac can be imported."
            case .notARegularFile: "The selected item is not a regular file."
            }
        }
    }

    public struct Result: Equatable, Sendable {
        /// Lower-case hex SHA-256 of the copied bytes.
        public let sha256: String
        public let size: Int64
    }

    /// SHA-256 of the regular file at `url`, read through one descriptor
    /// checked to be a regular file. A FIFO or device put in its place is
    /// refused instead of blocking the read.
    public static func sha256(ofFileAt url: URL) throws -> Result {
        let reader = try openRegularFile(url)
        var hasher = SHA256()
        var size: Int64 = 0
        while let chunk = try reader.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: chunk)
            size += Int64(chunk.count)
        }
        return Result(sha256: hex(hasher.finalize()), size: size)
    }

    private static func openRegularFile(_ url: URL) throws -> FileHandle {
        guard url.isFileURL else { throw CopyError.notALocalFile }
        // O_NONBLOCK so a FIFO can't stall the open; it is refused below.
        let input = open(url.path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard input >= 0 else { throw POSIXError.current }
        let reader = FileHandle(fileDescriptor: input, closeOnDealloc: true)
        var info = stat()
        guard fstat(input, &info) == 0 else { throw POSIXError.current }
        guard info.st_mode & S_IFMT == S_IFREG else { throw CopyError.notARegularFile }
        _ = fcntl(input, F_SETFL, fcntl(input, F_GETFL) & ~O_NONBLOCK)
        return reader
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Copies the regular file at `source` to `destination`, which must not
    /// exist yet; an existing file or symlink there is never written through.
    /// Removes the partial copy on failure or cancellation.
    public static func copy(from source: URL, to destination: URL) throws -> Result {
        guard destination.isFileURL else { throw CopyError.notALocalFile }
        let reader = try openRegularFile(source)

        let output = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard output >= 0 else { throw POSIXError.current }
        let writer = FileHandle(fileDescriptor: output, closeOnDealloc: true)
        do {
            var hasher = SHA256()
            var size: Int64 = 0
            while let chunk = try reader.read(upToCount: 1_048_576), !chunk.isEmpty {
                try Task.checkCancellation()
                hasher.update(data: chunk)
                try writer.write(contentsOf: chunk)
                size += Int64(chunk.count)
            }
            try writer.synchronize()
            return Result(sha256: hex(hasher.finalize()), size: size)
        } catch {
            unlink(destination.path)
            throw error
        }
    }
}
