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

    /// Which folder on disk this is, whatever path reached it.
    public struct Identity: Codable, Equatable, Sendable {
        public var device: Int64
        public var inode: UInt64
    }

    private let fd: Int32

    /// Opens `url`. The folders above it are followed as usual; `url`'s own
    /// last component must be a real folder, not a symlink.
    public convenience init(url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError.current }
        self.init(fd: fd)
    }

    /// Opens `url` by walking down from `ancestor`, refusing a symlink at
    /// every step below it. Use this when a process with less trust than
    /// the app can write anywhere between `ancestor` and `url`, such as the
    /// extension inside its own container.
    public convenience init(url: URL, below ancestor: URL) throws {
        let base = ancestor.standardizedFileURL.pathComponents
        let target = url.standardizedFileURL.pathComponents
        guard target.count >= base.count, Array(target.prefix(base.count)) == base else {
            throw POSIXError(.EINVAL)
        }
        var current = try TrustedDirectory(url: ancestor)
        for name in target.dropFirst(base.count) {
            current = try current.subdirectory(name)
        }
        self.init(fd: try Self.duplicate(current.fd))
    }

    private init(fd: Int32) { self.fd = fd }

    private static func duplicate(_ fd: Int32) throws -> Int32 {
        let copy = fcntl(fd, F_DUPFD_CLOEXEC, 0)
        guard copy >= 0 else { throw POSIXError.current }
        return copy
    }

    deinit { close(fd) }

    /// The device and inode of the folder this is open on.
    public func identity() throws -> Identity {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw POSIXError.current }
        return Identity(device: Int64(info.st_dev), inode: UInt64(info.st_ino))
    }

    /// The folder `name` inside this one. Throws if it is missing, a file,
    /// or a symlink.
    public func subdirectory(_ name: String) throws -> TrustedDirectory {
        try Self.checkName(name)
        let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard child >= 0 else { throw POSIXError.current }
        return TrustedDirectory(fd: child)
    }

    /// The folder `name` inside this one, made first if it is missing.
    /// Throws when something other than a real folder is there, a symlink
    /// included.
    public func makeSubdirectory(named name: String) throws -> TrustedDirectory {
        try Self.checkName(name)
        guard mkdirat(fd, name, 0o755) == 0 || errno == EEXIST else { throw POSIXError.current }
        return try subdirectory(name)
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

    /// The bytes of the regular file `name`. Refuses symlinks, folders and
    /// anything else that isn't a plain file.
    public func readFile(named name: String) throws -> Data {
        try openFile(named: name).readToEnd() ?? Data()
    }

    /// The regular file `name`, open for reading. Refuses symlinks, folders
    /// and anything else that isn't a plain file; a FIFO can't block the open.
    public func openFile(named name: String) throws -> FileHandle {
        try Self.checkName(name)
        let file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard file >= 0 else { throw POSIXError.current }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
        var info = stat()
        guard fstat(file, &info) == 0 else { throw POSIXError.current }
        guard Self.kind(of: info.st_mode) == .file else { throw POSIXError(.EFTYPE) }
        _ = fcntl(file, F_SETFL, fcntl(file, F_GETFL) & ~O_NONBLOCK)
        return handle
    }

    /// Runs work under a file lock shared by cooperating processes. Keep the
    /// lock file in place so waiters and new callers always lock the same inode.
    public func withExclusiveFileLock<Result>(named name: String, _ work: () throws -> Result) throws -> Result {
        try Self.checkName(name)
        let lock = openat(fd, name, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard lock >= 0 else { throw POSIXError.current }
        defer { close(lock) }
        var info = stat()
        guard fstat(lock, &info) == 0 else { throw POSIXError.current }
        guard Self.kind(of: info.st_mode) == .file else { throw POSIXError(.EFTYPE) }
        while flock(lock, LOCK_EX) != 0 {
            guard errno == EINTR else { throw POSIXError.current }
        }
        return try work()
    }

    /// Writes `contents` to `name` in one step: the bytes go to a new hidden
    /// file opened `O_EXCL | O_NOFOLLOW`, which is then renamed over `name`.
    /// A symlink at `name` is replaced, never written through. Fails on a
    /// folder at `name`, leaving nothing behind.
    public func writeFile(named name: String, contents: Data) throws {
        try Self.checkName(name)
        let temp = ".\(name).\(UUID().uuidString).tmp"
        let file = openat(fd, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard file >= 0 else { throw POSIXError.current }
        do {
            let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
            try handle.write(contentsOf: contents)
            try handle.close()
            guard renameat(fd, temp, fd, name) == 0 else { throw POSIXError.current }
        } catch {
            unlinkat(fd, temp, 0)
            throw error
        }
    }

    /// Deletes `name` only when it is a file or a symlink. Refuses folders.
    public func removeFile(named name: String) throws {
        try Self.checkName(name)
        var info = stat()
        guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw POSIXError.current }
        guard Self.kind(of: info.st_mode) != .directory else { throw POSIXError(.EISDIR) }
        guard unlinkat(fd, name, 0) == 0 else { throw POSIXError.current }
    }

    /// What `name` is on disk, without following a symlink; nil when it
    /// doesn't exist.
    public func kind(ofItemNamed name: String) throws -> Kind? {
        try Self.checkName(name)
        var info = stat()
        guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return nil }
            throw POSIXError.current
        }
        return Self.kind(of: info.st_mode)
    }

    /// When `name` was last modified, without following a symlink.
    public func modificationDate(ofItemNamed name: String) throws -> Date {
        try Self.checkName(name)
        var info = stat()
        guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw POSIXError.current }
        let time = info.st_mtimespec
        return Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1_000_000_000)
    }

    /// Renames `name` to `newName` in this folder. Fails rather than
    /// replace anything already at `newName`.
    public func renameItem(named name: String, to newName: String) throws {
        try Self.checkName(name)
        try Self.checkName(newName)
        guard renameatx_np(fd, name, fd, newName, UInt32(RENAME_EXCL)) == 0 else { throw POSIXError.current }
    }

    /// Moves `name` into `destination` as `newName` in one rename. If
    /// an item is already there, it is swapped into this folder and kept
    /// until `commit` succeeds. If `commit` throws, the old item is restored
    /// and the replacement discarded. Callers must serialize publishers
    /// when using `commit`. Both folders must be on one volume.
    public func publishItem(
        named name: String, into destination: TrustedDirectory, as newName: String,
        commit: () throws -> Void = {}
    ) throws {
        try Self.checkName(name)
        try Self.checkName(newName)
        let replaced = try moveForPublication(named: name, into: destination, as: newName)
        do {
            try commit()
        } catch {
            if replaced {
                let discarded = try moveForPublication(named: name, into: destination, as: newName)
                if discarded { try? removeItem(named: name) }
            } else {
                try? destination.removeFile(named: newName)
            }
            throw error
        }
        // If deletion fails, the caller's cleanup can remove the leftover.
        if replaced { try? removeItem(named: name) }
    }

    /// Returns whether the old destination was swapped into this folder.
    private func moveForPublication(named name: String, into destination: TrustedDirectory, as newName: String) throws -> Bool {
        // Bounded: a destination appearing and disappearing must not
        // hold the caller here forever.
        for _ in 0..<8 {
            if renameatx_np(fd, name, destination.fd, newName, UInt32(RENAME_EXCL)) == 0 { return false }
            guard errno == EEXIST else { throw POSIXError.current }
            if renameatx_np(fd, name, destination.fd, newName, UInt32(RENAME_SWAP)) == 0 { return true }
            // The old item may have vanished between the two renames.
            guard errno == ENOENT else { throw POSIXError.current }
        }
        throw POSIXError(.EBUSY)
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
            // Something else deleting part of the tree at the same time is
            // fine; the folder still has to end up empty below.
            do { try removeTree(named: item, in: child) } catch POSIXError.ENOENT {}
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
        while true {
            // readdir returns nil both at the end and on an error; only
            // errno tells them apart.
            errno = 0
            guard let entry = readdir(dir) else {
                if errno != 0 { throw POSIXError.current }
                return names
            }
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if name != "." && name != ".." { names.append(name) }
        }
    }
}

extension POSIXError {
    static var current: POSIXError { code(errno) }

    static func code(_ value: Int32) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: value) ?? .EIO)
    }
}
