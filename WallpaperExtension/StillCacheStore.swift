import CoreGraphics
import Darwin
import Foundation
import ImageIO

/// The still cache in WallpaperAgent's cache directory. File names keep the
/// layout the extension has always written; the video a still came from and
/// when it was last used live in extended attributes, set on a temp file
/// before it is renamed into place, so a still is never visible without them
/// or half-written.
///
/// An actor so each scan-then-change step (hit, copy, publish, eviction)
/// runs with no other write in between. Only the decode suspends, and a
/// write re-checks after it.
actor StillCacheStore {
    enum Outcome: Equatable, Sendable {
        case hit, created
        /// A write for this video was in flight; its leader writes this size.
        case joined
        /// A newer write for this wallpaper asked for another video while
        /// this one decoded; its result was dropped.
        case superseded
        case failed
    }

    struct Report: Equatable, Sendable {
        /// What happened to the requested size.
        let outcome: Outcome
        /// Files this call put in place, including sizes that joined it.
        let created: Int
    }

    static let versionAttribute = "app.lumawall.still.version"
    static let usedAttribute = "app.lumawall.still.used"
    private static let tempPrefix = ".lumawall-"
    private static let tempSuffix = ".tmp"

    private let budget: Int
    private var flights = StillCacheFlights()
    /// The video each wallpaper's most recent write asked for.
    private var latest: [String: String] = [:]
    /// Directories already cleared of temp files a crash left behind.
    private var recovered: Set<String> = []

    init(budget: Int = StillCache.byteBudget) {
        self.budget = budget
    }

    /// Make sure `dir` holds this video's still at `size`. A copy of another
    /// size of the same video is used when there is one; otherwise `encode`
    /// is called, at most once per call, for the BMP bytes. Every call
    /// finishes by removing other videos of this wallpaper and trimming the
    /// directory to the budget.
    func write(in dir: URL, choiceHash: String, version: String, size: StillSize, encode: @escaping @Sendable () async -> Data?) async -> Report {
        recover(dir)
        latest[choiceHash] = version
        let group = "\(choiceHash)-\(version)"
        guard flights.join(group, size: size) else { return Report(outcome: .joined, created: 0) }

        var encoded: Data??
        var first: Outcome?
        var created = 0
        var kept: StillCacheEntry?
        var next: StillSize? = size
        while let current = next {
            let key = StillCacheKey(choiceHash: choiceHash, width: current.width, height: current.height)
            var result = settle(key, version: version, in: dir)
            if result == nil {
                if encoded == nil { encoded = .some(await encode()) }
                result = settle(key, version: version, in: dir) ?? publishEncoded(encoded ?? nil, key: key, version: version, in: dir)
            }
            let (outcome, entry) = result ?? (.failed, nil)
            first = first ?? outcome
            if outcome == .created { created += 1 }
            if let entry { kept = entry }
            if outcome == .superseded {
                while flights.next(group) != nil {}
                break
            }
            next = flights.next(group)
        }

        let current = latest[choiceHash].map { (choiceHash: choiceHash, version: $0) }
        for stale in StillCache.evictions(Self.scan(dir), current: current, keeping: kept, budget: budget) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(stale.fileName))
        }
        return Report(outcome: first ?? .failed, created: created)
    }

    /// The outcome when no decode is needed, or nil when it is.
    private func settle(_ key: StillCacheKey, version: String, in dir: URL) -> (Outcome, StillCacheEntry?)? {
        guard latest[key.choiceHash] == version else { return (.superseded, nil) }
        switch StillCache.source(for: key, version: version, in: Self.scan(dir)) {
        case let .existing(entry):
            Self.markUsed(dir.appendingPathComponent(entry.fileName))
            return (.hit, entry)
        case let .copy(from: sibling):
            let source = dir.appendingPathComponent(sibling.fileName)
            // A failed copy falls through to a decode.
            return publish(key: key, version: version, in: dir) { try FileManager.default.copyItem(at: source, to: $0) }
                .map { (.created, $0) }
        case .decode:
            return nil
        }
    }

    private func publishEncoded(_ data: Data?, key: StillCacheKey, version: String, in dir: URL) -> (Outcome, StillCacheEntry?) {
        guard let data, let entry = publish(key: key, version: version, in: dir, fill: { try data.write(to: $0) }) else {
            return (.failed, nil)
        }
        return (.created, entry)
    }

    /// Fill a temp file, tag it, and rename it to the entry's name.
    private func publish(key: StillCacheKey, version: String, in dir: URL, fill: (URL) throws -> Void) -> StillCacheEntry? {
        let temp = dir.appendingPathComponent("\(Self.tempPrefix)\(UUID().uuidString)\(Self.tempSuffix)")
        let now = Date().timeIntervalSinceReferenceDate
        let entry = StillCacheEntry(key: key, written: now.bitPattern)
        do {
            try fill(temp)
            guard setStillAttribute(temp, Self.versionAttribute, version),
                  setStillAttribute(temp, Self.usedAttribute, String(now)),
                  rename(temp.path, dir.appendingPathComponent(entry.fileName).path) == 0
            else { throw CocoaError(.fileWriteUnknown) }
            return entry
        } catch {
            try? FileManager.default.removeItem(at: temp)
            return nil
        }
    }

    private func recover(_ dir: URL) {
        guard recovered.insert(dir.standardizedFileURL.path).inserted,
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for name in names where name.hasPrefix(Self.tempPrefix) && name.hasSuffix(Self.tempSuffix) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    /// This video's still to seed a renderer with, decoded, or nil. Skips
    /// any candidate that fails to decode. Runs outside the actor: the
    /// acquire path can't wait on a write, and a rename never exposes a
    /// partial file.
    nonisolated static func load(in dir: URL, choiceHash: String, version: String, size: StillSize) -> CGImage? {
        for file in StillCache.candidates(scan(dir), choiceHash: choiceHash, version: version, size: size) {
            let url = dir.appendingPathComponent(file.entry.fileName)
            // Decode now: an eviction may delete the file once this returns.
            let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, options) else { continue }
            markUsed(url)
            return image
        }
        return nil
    }

    /// The stills in `dir` with what eviction and lookup need to know.
    nonisolated static func scan(_ dir: URL) -> [StillCacheFile] {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        guard let contents = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: Array(keys)) else {
            return []
        }
        return contents.compactMap { url in
            guard let entry = StillCacheEntry(fileName: url.lastPathComponent) else { return nil }
            let values = try? url.resourceValues(forKeys: keys)
            let bytes = values?.fileSize ?? 0
            let used = stillAttribute(url, usedAttribute).flatMap(Double.init).map(Date.init(timeIntervalSinceReferenceDate:))
            return StillCacheFile(
                entry: entry, bytes: bytes, version: stillAttribute(url, versionAttribute),
                lastUsed: used ?? values?.contentModificationDate ?? .distantPast,
                isComplete: header(of: url).flatMap(StillCache.bmpFileSize) == bytes,
            )
        }
    }

    private nonisolated static func header(of url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: StillCache.bmpHeaderSize)
    }

    /// Eviction removes the least recently used first; a hit or a seed is a use.
    private nonisolated static func markUsed(_ url: URL) {
        setStillAttribute(url, usedAttribute, String(Date().timeIntervalSinceReferenceDate))
    }
}

func stillAttribute(_ url: URL, _ name: String) -> String? {
    url.withUnsafeFileSystemRepresentation { path -> String? in
        guard let path else { return nil }
        let length = getxattr(path, name, nil, 0, 0, 0)
        guard length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        guard getxattr(path, name, &buffer, length, 0, 0) == length else { return nil }
        return String(decoding: buffer, as: UTF8.self)
    }
}

@discardableResult
func setStillAttribute(_ url: URL, _ name: String, _ value: String) -> Bool {
    url.withUnsafeFileSystemRepresentation { path -> Bool in
        guard let path else { return false }
        let bytes = Array(value.utf8)
        return setxattr(path, name, bytes, bytes.count, 0, 0) == 0
    }
}
