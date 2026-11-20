import Foundation
import os

/// An append-only log file that rotates to `name.1.ext`, `name.2.ext`, ...
/// once it passes `maxSize`. Safe to call from any thread.
final class LogFile: Sendable {
    let url: URL
    let maxSize: UInt64
    let rotatedCopies: Int
    /// Writes between checks that the open handle is still the file at `url`.
    static let pathCheckInterval = 64
    private struct State: @unchecked Sendable {
        var handle: FileHandle?
        var writesSinceCheck = 0
    }

    /// Only touched inside the lock.
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(url: URL, maxSize: UInt64, rotatedCopies: Int) {
        self.url = url
        self.maxSize = maxSize
        self.rotatedCopies = rotatedCopies
    }

    /// Appends `line`, dropping it if the file can't be opened or written.
    /// A failed write drops the handle so the next call reopens the file.
    func append(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        state.withLock { state in
            if let h = state.handle, ((try? h.offset()) ?? 0) >= maxSize {
                try? h.close()
                state.handle = nil
                rotate()
            }
            // A log deleted or replaced while open keeps taking writes into
            // the unlinked file, so check now and then that it's still there.
            state.writesSinceCheck += 1
            if let h = state.handle, state.writesSinceCheck >= Self.pathCheckInterval {
                state.writesSinceCheck = 0
                if !isFileAtURL(h) {
                    try? h.close()
                    state.handle = nil
                }
            }
            if state.handle == nil { state.handle = open() }
            guard let h = state.handle else { return }
            do {
                // write(contentsOf:) throws; write(_:) raises an Objective-C
                // exception Swift can't catch, which aborted the extension.
                try h.write(contentsOf: data)
            } catch {
                try? h.close()
                state.handle = nil
            }
        }
    }

    /// True when `handle` is still open on the file at `url`.
    private func isFileAtURL(_ handle: FileHandle) -> Bool {
        var open = stat(), current = stat()
        guard fstat(handle.fileDescriptor, &open) == 0, stat(url.path, &current) == 0 else { return false }
        return open.st_dev == current.st_dev && open.st_ino == current.st_ino
    }

    private func open() -> FileHandle? {
        guard let h = try? FileHandle(forWritingTo: url) else {
            FileManager.default.createFile(atPath: url.path, contents: nil)
            return try? FileHandle(forWritingTo: url)
        }
        _ = try? h.seekToEnd()
        return h
    }

    private func rotate() {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        func copy(_ i: Int) -> URL { dir.appendingPathComponent("\(base).\(i).\(ext)") }
        try? fm.removeItem(at: copy(rotatedCopies))
        if rotatedCopies > 1 {
            for i in stride(from: rotatedCopies - 1, through: 1, by: -1) where fm.fileExists(atPath: copy(i).path) {
                try? fm.moveItem(at: copy(i), to: copy(i + 1))
            }
        }
        if fm.fileExists(atPath: url.path) { try? fm.moveItem(at: url, to: copy(1)) }
        for i in rotatedCopies + 1...rotatedCopies + 3 where fm.fileExists(atPath: copy(i).path) {
            try? fm.removeItem(at: copy(i))
        }
    }
}
