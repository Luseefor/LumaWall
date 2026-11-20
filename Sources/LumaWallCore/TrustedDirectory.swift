import Darwin
import Foundation

/// An open folder LumaWall owns, for listing and deleting inside it without
/// following symlinks.
///
/// Path-based deletes resolve every component when they run, so a folder
/// swapped for a symlink between a check and `removeItem` sends the delete
/// somewhere else. Here every step is relative to a descriptor this type
/// holds: names are single components, folders are opened with
/// `O_NOFOLLOW`, and a symlink met along the way is unlinked, never entered.
public final class TrustedDirectory {
    public enum Kind: Equatable, Sendable { case file, directory, symlink, other }

    public struct Entry: Equatable, Sendable {
        public var name: String
        public var kind: Kind
    }

    private let fd: Int32

    /// Opens `url`. The folders above it are followed as usual; `url`'s own
    /// last component must be a real folder, not a symlink.
    public convenience init(url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError.current }
        self.init(fd: fd)
    }

    private init(fd: Int32) { self.fd = fd }

    deinit { close(fd) }

    /// The folder `name` inside this one. Throws if it is missing, a file,
    /// or a symlink.
    public func subdirectory(_ name: String) throws -> TrustedDirectory {
        try Self.checkName(name)
        let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard child >= 0 else { throw POSIXError.current }
        return TrustedDirectory(fd: child)
    }

    /// The items in this folder, without `.` and `..`, as they are on disk:
    /// a symlink is reported as `.symlink` whatever it points at.
    public func entries() throws -> [Entry] {
        try Self.names(in: fd).map { name in
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return Entry(name: name, kind: .other) }
            return Entry(name: name, kind: Self.kind(of: info.st_mode))
        }
    }

    /// Deletes `name` and, when it is a folder, everything in it. A symlink
    /// anywhere in the tree is removed as a link; its target is untouched.
    public func removeItem(named name: String) throws {
        try Self.checkName(name)
        try Self.removeTree(named: name, in: fd)
    }

    /// Deletes `name` only when it is a file or a symlink. Refuses folders.
    public func removeFile(named name: String) throws {
        try Self.checkName(name)
        var info = stat()
        guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw POSIXError.current }
        guard Self.kind(of: info.st_mode) != .directory else { throw POSIXError(.EISDIR) }
        guard unlinkat(fd, name, 0) == 0 else { throw POSIXError.current }
    }

    private static func checkName(_ name: String) throws {
        guard PathSafety.isSafeComponent(name) else { throw POSIXError(.EINVAL) }
    }

    private static func kind(of mode: mode_t) -> Kind {
        switch mode & S_IFMT {
        case S_IFREG: .file
        case S_IFDIR: .directory
        case S_IFLNK: .symlink
        default: .other
        }
    }

    private static func removeTree(named name: String, in parent: Int32) throws {
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw POSIXError.current }
        if kind(of: info.st_mode) != .directory {
            guard unlinkat(parent, name, 0) == 0 else { throw POSIXError.current }
            return
        }
        // O_NOFOLLOW: a folder swapped for a symlink after the stat above
        // fails here with ELOOP instead of being entered.
        let child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard child >= 0 else {
            let error = errno
            guard error == ELOOP || error == ENOTDIR else { throw POSIXError.code(error) }
            guard unlinkat(parent, name, 0) == 0 else { throw POSIXError.current }
            return
        }
        defer { close(child) }
        for item in try names(in: child) {
            try removeTree(named: item, in: child)
        }
        guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else { throw POSIXError.current }
    }

    /// Lists `dirFD` through a fresh descriptor, so the caller's descriptor
    /// keeps its offset and stays open.
    private static func names(in dirFD: Int32) throws -> [String] {
        let listFD = openat(dirFD, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard listFD >= 0 else { throw POSIXError.current }
        guard let dir = fdopendir(listFD) else {
            let error = POSIXError.current
            close(listFD)
            throw error
        }
        defer { closedir(dir) }
        var names: [String] = []
        while let entry = readdir(dir) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }
}

extension POSIXError {
    static var current: POSIXError { code(errno) }

    static func code(_ value: Int32) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: value) ?? .EIO)
    }
}
