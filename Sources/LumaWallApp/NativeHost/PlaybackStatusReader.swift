import Darwin
import Foundation
import LumaWallCore

/// Reads the status file the wallpaper extension writes, and calls back when
/// it changes (the extension posts a Darwin notification after each write).
/// The extension can write its container, so the file is checked like any
/// outside input: a regular file, small, and a version this build reads.
enum PlaybackStatusReader {
    static let maxBytes = 64 * 1024

    static var defaultDirectory: URL { WallpaperHostCapabilities.extensionDocumentsURL }

    /// Every live extension process's snapshot in `directory`, merged. A file
    /// whose process has exited is a leftover and is skipped; the higher pid
    /// wins a display two processes both list.
    static func read(
        in directory: URL = defaultDirectory,
        isAlive: (Int32) -> Bool = processIsAlive
    ) -> PlaybackStatusSnapshot {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let files = names.compactMap { name in PlaybackStatusSnapshot.pid(fromFileName: name).map { (pid: $0, name: name) } }
            .filter { isAlive($0.pid) }
            .sorted { $0.pid < $1.pid }
        return PlaybackStatusSnapshot.merged(
            files.compactMap { read(file: directory.appendingPathComponent($0.name)) })
    }

    static func read(file url: URL) -> PlaybackStatusSnapshot? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
            values.isRegularFile == true, let size = values.fileSize, size <= maxBytes,
            let data = try? Data(contentsOf: url)
        else { return nil }
        return PlaybackStatusSnapshot.decode(data)
    }

    /// Signal 0 only checks. EPERM means the process exists but isn't ours.
    static func processIsAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}

/// Observes the status notification for as long as it lives.
final class PlaybackStatusObserver: @unchecked Sendable {
    private let onChange: @Sendable () -> Void

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                Unmanaged<PlaybackStatusObserver>.fromOpaque(observer).takeUnretainedValue().onChange()
            },
            PlaybackStatusSnapshot.notificationName as CFString,
            nil,
            .deliverImmediately
        )
    }

    deinit {
        CFNotificationCenterRemoveEveryObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque())
    }
}
