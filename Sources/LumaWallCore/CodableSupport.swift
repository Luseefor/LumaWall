import Foundation

extension JSONEncoder {
    static var lumaWall: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var lumaWall: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Shared persistence helpers for the JSON file stores.
///
/// Every store resolves the same base directory and writes atomically with
/// file protection; centralizing it here (instead of copy-pasting per actor)
/// keeps those guarantees from drifting. Reads quarantine undecodable files
/// instead of silently resetting them: previously a corrupt file loaded
/// defaults into memory and the next persist overwrote the evidence.
public enum StorePaths {
    public static func appSupportBase(rootURL: URL? = nil) throws -> URL {
        let base =
            rootURL
            ?? FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            )[0].appendingPathComponent("LumaWall", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
}

public enum StoreIO {
    /// Store files stay encrypted until the first unlock after boot, then
    /// readable while the screen is locked. LumaWall runs schedules and
    /// lock-screen playback while locked; "complete unless open" made an
    /// existing file unreadable then, so loads came back empty.
    ///
    /// A store that exists but can't be read is never replaced: its owner
    /// loaded it as empty, so saving would erase the real data.
    public static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try JSONEncoder.lumaWall.encode(value)
        if let error = unreadableExistingFile(at: url) { throw error }
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// The error opening an existing store for reading, or nil when it's
    /// readable or absent. Doesn't follow a symlink (ELOOP counts as
    /// readable here: the atomic write replaces the link, as before).
    private static func unreadableExistingFile(at url: URL) -> POSIXError? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd >= 0 {
            close(fd)
            return nil
        }
        let code = errno
        guard code == EPERM || code == EACCES else { return nil }
        return POSIXError(POSIXErrorCode(rawValue: code) ?? .EACCES)
    }

    /// Writes `value` readable only by the user (0600), for diagnostics. The
    /// bytes go to a new `O_EXCL | O_NOFOLLOW` temp file renamed over `url`,
    /// so an existing file or symlink at `url` is replaced, never written
    /// through.
    public static func writePrivateJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try JSONEncoder.lumaWall.encode(value)
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
            guard rename(temp.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            unlink(temp.path)
            throw error
        }
    }

    /// The bytes of the regular file at `url`, refusing a symlink or anything
    /// else in its place.
    public static func readRegularFile(at url: URL) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw POSIXError(.EFTYPE) }
        return try handle.readToEnd() ?? Data()
    }

    /// Best-effort variant for contexts that must not throw (crash-time saves).
    @discardableResult
    public static func tryWriteJSON<T: Encodable>(_ value: T, to url: URL) -> Bool {
        (try? writeJSON(value, to: url)) != nil
    }

    /// Loads and decodes `type`, returning nil when the file is missing (normal
    /// first launch). When bytes exist but decoding fails, the file is moved
    /// aside as `<name>.corrupt-<epoch>` before returning nil, so a later
    /// persist cannot destroy the evidence.
    /// `isValid` rejects bytes that decode but break an invariant the type
    /// can't express, such as a repeated ID; those are quarantined too.
    public static func readJSON<T: Decodable>(
        from url: URL, as type: T.Type, isValid: (T) -> Bool = { _ in true }
    ) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let decoded = try? JSONDecoder.lumaWall.decode(type, from: data), isValid(decoded) {
            upgradeProtection(at: url)
            return decoded
        }
        quarantineCorruptFile(at: url)
        return nil
    }

    /// Files written before the switch to "until first unlock" keep the old
    /// class until rewritten. Change the class in place on the open file, so
    /// no bytes are rewritten (a second instance's newer save can't be
    /// replaced with stale data) and a symlink is never followed.
    private static func upgradeProtection(at url: URL) {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return }
        // Darwin's PROTECTION_CLASS_C (until first user authentication); the
        // constant isn't imported into Swift.
        let classC: Int32 = 3
        guard fcntl(fd, F_GETPROTECTIONCLASS) != classC else { return }
        _ = fcntl(fd, F_SETPROTECTIONCLASS, classC)
    }

    private static func quarantineCorruptFile(at url: URL) {
        let backup = url.deletingLastPathComponent().appendingPathComponent(
            "\(url.lastPathComponent).corrupt-\(Int(Date.now.timeIntervalSince1970))"
        )
        try? FileManager.default.moveItem(at: url, to: backup)
    }
}
