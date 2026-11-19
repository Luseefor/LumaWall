import Foundation
import os

/// An append-only log file that rotates to `name.1.ext`, `name.2.ext`, ...
/// once it passes `maxSize`. Safe to call from any thread.
final class LogFile: Sendable {
    let url: URL
    let maxSize: UInt64
    let rotatedCopies: Int
    private let handle = OSAllocatedUnfairLock(initialState: nil as FileHandle?)

    init(url: URL, maxSize: UInt64, rotatedCopies: Int) {
        self.url = url
        self.maxSize = maxSize
        self.rotatedCopies = rotatedCopies
    }

    /// Appends `line`, dropping it if the file can't be opened or written.
    /// A failed write drops the handle so the next call reopens the file.
    func append(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        handle.withLock { handle in
            if let h = handle, ((try? h.offset()) ?? 0) >= maxSize {
                try? h.close()
                handle = nil
                rotate()
            }
            if handle == nil { handle = open() }
            guard let h = handle else { return }
            do {
                // write(contentsOf:) throws; write(_:) raises an Objective-C
                // exception Swift can't catch, which aborted the extension.
                try h.write(contentsOf: data)
            } catch {
                try? h.close()
                handle = nil
            }
        }
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
        for i in rotatedCopies + 1 ... rotatedCopies + 3 where fm.fileExists(atPath: copy(i).path) {
            try? fm.removeItem(at: copy(i))
        }
    }
}
