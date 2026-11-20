import Foundation

struct VideoEntry: Codable, Equatable {
    let id: String
    var name: String
    var filename: String
    var duration: Double
    var fps: Double
    var resolution: CGSize
    var dateAdded: Date
    var variants: [VideoVariant]?
    var contentHash: String?
    var audioStripped: Bool?
}

/// Reads one library entry directory (`videos/<UUID>/`) without changing
/// it. The app publishes entries and may still be staging one, so a scan
/// never prunes a directory or writes metadata; it skips what it can't use.
/// Every file it accepts is a regular file directly in the entry directory:
/// a symlink could point the renderer anywhere.
enum LibraryEntryScan {
    enum Outcome: Equatable {
        case entry(VideoEntry)
        /// Not listed; the reason is logged.
        case skipped(String)
    }

    static let videoExtensions: Set = ["mp4", "mov", "m4v"]

    static func read(directory: URL) -> Outcome {
        let id = directory.lastPathComponent
        guard PathSafety.isValidEntryID(id) else { return .skipped("not a UUID directory") }
        guard fileType(directory) == .typeDirectory else { return .skipped("not a directory") }

        let metadataURL = directory.appendingPathComponent("metadata.json")
        if isRegularFile(metadataURL), let data = try? Data(contentsOf: metadataURL),
            let entry = try? JSONDecoder().decode(VideoEntry.self, from: data)
        {
            // Metadata id must match its directory, and the filename must be
            // a safe basename.
            guard entry.id == id, PathSafety.isSafeComponent(entry.filename) else {
                return .skipped("metadata id or filename mismatch or unsafe")
            }
            guard isRegularFile(directory.appendingPathComponent(entry.filename)) else {
                return .skipped("video file missing or not a regular file")
            }
            return .entry(usableVariants(of: entry, in: directory))
        }

        guard let video = recoverableVideo(in: directory) else { return .skipped("no metadata and no video file") }
        let created = (try? video.resourceValues(forKeys: [.creationDateKey]))?.creationDate
        return .entry(
            VideoEntry(
                id: id,
                name: video.deletingPathExtension().lastPathComponent,
                filename: video.lastPathComponent,
                duration: 0,
                fps: 0,
                resolution: .zero,
                // The file's creation date keeps a recovered entry's place in
                // the library order stable across scans.
                dateAdded: created ?? Date(),
            ))
    }

    /// True when `file` is a regular file and the entry directory holding
    /// it is still a real directory. Checked again at playback time, since
    /// either can change after a scan.
    static func isPlayable(_ file: URL) -> Bool {
        fileType(file.deletingLastPathComponent()) == .typeDirectory && isRegularFile(file)
    }

    /// True when `url` itself (not a symlink's target) is a regular file.
    static func isRegularFile(_ url: URL) -> Bool {
        fileType(url) == .typeRegular
    }

    /// The entry with only variants whose names are safe basenames of
    /// regular files in `directory`.
    private static func usableVariants(of entry: VideoEntry, in directory: URL) -> VideoEntry {
        guard let variants = entry.variants else { return entry }
        let usable = variants.filter {
            PathSafety.isSafeComponent($0.filename) && isRegularFile(directory.appendingPathComponent($0.filename))
        }
        guard usable.count != variants.count else { return entry }
        var copy = entry
        copy.variants = usable.isEmpty ? nil : usable
        return copy
    }

    /// The first regular file with a video extension directly in `directory`,
    /// in name order so repeated scans agree.
    private static func recoverableVideo(in directory: URL) -> URL? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.sorted()
            .map { directory.appendingPathComponent($0) }
            .first { videoExtensions.contains($0.pathExtension.lowercased()) && isRegularFile($0) }
    }

    /// The type of the item at `url`, without following a final symlink.
    private static func fileType(_ url: URL) -> FileAttributeType? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
    }
}
