import Foundation
import LumaWallCore

/// Reads the status file the wallpaper extension writes, and calls back when
/// it changes (the extension posts a Darwin notification after each write).
/// The extension can write its container, so the file is checked like any
/// outside input: a regular file, small, and a version this build reads.
enum PlaybackStatusReader {
    static let maxBytes = 64 * 1024

    static var defaultURL: URL {
        WallpaperHostCapabilities.extensionDocumentsURL
            .appendingPathComponent(PlaybackStatusSnapshot.fileName)
    }

    static func read(from url: URL = defaultURL) -> PlaybackStatusSnapshot? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
            values.isRegularFile == true, let size = values.fileSize, size <= maxBytes,
            let data = try? Data(contentsOf: url)
        else { return nil }
        return PlaybackStatusSnapshot.decode(data)
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
