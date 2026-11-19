import CoreGraphics
import Darwin
import Foundation
import ImageIO
import os

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
        /// The directory won't take the extended attributes a still needs.
        case refused(errno: Int32)
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

    /// setxattr errors that won't go away for a directory.
    private static let permanentRefusals: Set<Int32> = [EPERM, EACCES, ENOTSUP]

    private let budget: Int
    private let tag: @Sendable (URL, String, String) -> Int32
    /// Test seam: runs between eviction's scan and its deletes.
    private let onEvictionScan: @Sendable () -> Void
    /// Test seam: runs after a seed picks its file, before it decodes.
    private let onSeedPicked: @Sendable () -> Void
    /// Directories that refused the attributes, by path, with the errno.
    /// The lock also orders a seed's last-use touch against eviction's
    /// scan-then-delete, since seeds run outside the actor.
    private let refusals = OSAllocatedUnfairLock<[String: Int32]>(initialState: [:])
    private var flights = StillCacheFlights()
    /// The video each wallpaper's most recent write asked for, keyed by
    /// directory and choice.
    private var latest: [String: String] = [:]
    /// Directories already cleared of temp files a crash left behind.
    private var recovered: Set<String> = []

    init(
        budget: Int = StillCache.byteBudget,
        tag: @escaping @Sendable (URL, String, String) -> Int32 = setStillAttribute,
        onEvictionScan: @escaping @Sendable () -> Void = {},
        onSeedPicked: @escaping @Sendable () -> Void = {},
    ) {
        self.budget = budget
        self.tag = tag
        self.onEvictionScan = onEvictionScan
        self.onSeedPicked = onSeedPicked
    }

    /// Make sure `dir` holds this video's still at `size`. A copy of another
    /// size of the same video is used when there is one; otherwise `encode`
    /// is called, at most once per call, for the BMP bytes. A call that hit
    /// or wrote a still then removes other videos of this wallpaper and
    /// trims the directory to the budget; any other outcome deletes nothing.
    func write(in dir: URL, choiceHash: String, version: String, size: StillSize, encode: @escaping @Sendable () async -> Data?) async -> Report {
        let scope = dir.standardizedFileURL.path
        if let refused = refusals.withLock({ $0[scope] }) { return Report(outcome: .refused(errno: refused), created: 0) }
        recover(dir, scope: scope)
        let wallpaper = "\(scope)\n\(choiceHash)"
        latest[wallpaper] = version
        let group = "\(wallpaper)\n\(version)"
        guard flights.join(group, size: size) else { return Report(outcome: .joined, created: 0) }

        var encoded: Data??
        var first: Outcome?
        var created = 0
        var kept: StillCacheEntry?
        var next: StillSize? = size
        while let current = next {
            let key = StillCacheKey(choiceHash: choiceHash, width: current.width, height: current.height)
            var result = settle(key, version: version, wallpaper: wallpaper, in: dir)
            if result == nil {
                if encoded == nil { encoded = .some(await encode()) }
                result = settle(key, version: version, wallpaper: wallpaper, in: dir)
                    ?? publishEncoded(encoded ?? nil, key: key, version: version, in: dir)
            }
            let (outcome, entry) = result ?? (.failed, nil)
            first = first ?? outcome
            switch outcome {
            case .created: created += 1
            case .superseded, .refused:
                // A newer video owns this wallpaper's entries, or nothing can
                // be tagged here: leave the directory alone.
                if case let .refused(errno) = outcome { refusals.withLock { $0[scope] = errno } }
                while flights.next(group) != nil {}
                return Report(outcome: first ?? outcome, created: created)
            default: break
            }
            if let entry { kept = entry }
            next = flights.next(group)
        }

        guard let kept else { return Report(outcome: first ?? .failed, created: created) }
        let current = latest[wallpaper].map { (choiceHash: choiceHash, version: $0) }
        let budget = budget, onEvictionScan = onEvictionScan
        refusals.withLock { _ in
            let files = Self.scan(dir)
            onEvictionScan()
            for stale in StillCache.evictions(files, current: current, keeping: kept, budget: budget) {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(stale.fileName))
            }
        }
        return Report(outcome: first ?? .failed, created: created)
    }

    /// The outcome when no decode is needed, or nil when it is.
    private func settle(_ key: StillCacheKey, version: String, wallpaper: String, in dir: URL) -> (Outcome, StillCacheEntry?)? {
        // Also runs after the decode: another write may have found the
        // directory refused while this one was suspended.
        let scope = dir.standardizedFileURL.path
        if let refused = refusals.withLock({ $0[scope] }) { return (.refused(errno: refused), nil) }
        guard latest[wallpaper] == version else { return (.superseded, nil) }
        switch StillCache.source(for: key, version: version, in: Self.scan(dir)) {
        case let .existing(entry):
            // A refused touch is a refused publish: the caller marks the
            // directory. Any other failure evicts nothing, like a failed publish.
            switch tag(dir.appendingPathComponent(entry.fileName), Self.usedAttribute, Self.nowString()) {
            case 0: return (.hit, entry)
            case let error where Self.permanentRefusals.contains(error): return (.refused(errno: error), nil)
            default: return (.failed, nil)
            }
        case let .copy(from: sibling):
            let source = dir.appendingPathComponent(sibling.fileName)
            switch publish(key: key, version: version, in: dir, fill: { try FileManager.default.copyItem(at: source, to: $0) }) {
            case let .entry(entry): return (.created, entry)
            case let .refused(errno): return (.refused(errno: errno), nil)
            case .failed: return nil // A failed copy falls through to a decode.
            }
        case .decode:
            return nil
        }
    }

    private func publishEncoded(_ data: Data?, key: StillCacheKey, version: String, in dir: URL) -> (Outcome, StillCacheEntry?) {
        guard let data else { return (.failed, nil) }
        switch publish(key: key, version: version, in: dir, fill: { try data.write(to: $0) }) {
        case let .entry(entry): return (.created, entry)
        case let .refused(errno): return (.refused(errno: errno), nil)
        case .failed: return (.failed, nil)
        }
    }

    private enum Published {
        case entry(StillCacheEntry)
        case refused(Int32)
        case failed
    }

    /// Fill a temp file, tag it, and rename it to the entry's name.
    private func publish(key: StillCacheKey, version: String, in dir: URL, fill: (URL) throws -> Void) -> Published {
        let temp = dir.appendingPathComponent("\(Self.tempPrefix)\(UUID().uuidString)\(Self.tempSuffix)")
        let now = Date().timeIntervalSinceReferenceDate
        let entry = StillCacheEntry(key: key, written: now.bitPattern)
        let result: Published
        if (try? fill(temp)) == nil {
            result = .failed
        } else if case let error = tag(temp, Self.versionAttribute, version), error != 0 {
            result = Self.permanentRefusals.contains(error) ? .refused(error) : .failed
        } else if case let error = tag(temp, Self.usedAttribute, String(now)), error != 0 {
            result = Self.permanentRefusals.contains(error) ? .refused(error) : .failed
        } else if rename(temp.path, dir.appendingPathComponent(entry.fileName).path) != 0 {
            result = .failed
        } else {
            return .entry(entry)
        }
        try? FileManager.default.removeItem(at: temp)
        return result
    }

    private func recover(_ dir: URL, scope: String) {
        guard recovered.insert(scope).inserted,
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for name in names where name.hasPrefix(Self.tempPrefix) && name.hasSuffix(Self.tempSuffix) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    /// This video's still to seed a renderer with, decoded, or nil. A nil
    /// `choiceHash` takes a still of this video cached under any choice.
    /// Skips any candidate that fails to decode. Runs outside the actor (the
    /// acquire path can't wait on a write; a rename never exposes a partial
    /// file), but picks, touches and maps each candidate under the lock
    /// eviction holds, so an eviction can't delete it on a scan from before
    /// the touch, and a later delete can't take the bytes from the decode.
    nonisolated func load(in dir: URL, choiceHash: String?, version: String, size: StillSize) -> CGImage? {
        let scope = dir.standardizedFileURL.path
        var tried: Set<StillCacheEntry> = []
        while true {
            let excluded = tried, tag = tag
            // Mapped under the lock: the mapping keeps the bytes readable if
            // an eviction deletes the file before the decode below.
            let pick: (entry: StillCacheEntry, bytes: Data?)? = refusals.withLock { refused in
                guard refused[scope] == nil,
                      let file = StillCache.candidates(Self.scan(dir), choiceHash: choiceHash, version: version, size: size)
                          .first(where: { !excluded.contains($0.entry) }) else { return nil }
                let url = dir.appendingPathComponent(file.entry.fileName)
                // A refused touch marks the directory as a refused publish
                // does, so writes stop too. A transient failure still seeds.
                let error = tag(url, Self.usedAttribute, Self.nowString())
                if Self.permanentRefusals.contains(error) {
                    refused[scope] = error
                    return nil
                }
                return (file.entry, try? Data(contentsOf: url, options: .alwaysMapped))
            }
            guard let pick else { return nil }
            tried.insert(pick.entry)
            onSeedPicked()
            let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
            if let bytes = pick.bytes,
               let source = CGImageSourceCreateWithData(bytes as CFData, nil),
               let image = CGImageSourceCreateImageAtIndex(source, 0, options) {
                return image
            }
        }
    }

    private nonisolated static func nowString() -> String {
        String(Date().timeIntervalSinceReferenceDate)
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

/// 0, or the errno `setxattr` failed with.
@discardableResult
func setStillAttribute(_ url: URL, _ name: String, _ value: String) -> Int32 {
    url.withUnsafeFileSystemRepresentation { path -> Int32 in
        guard let path else { return EINVAL }
        let bytes = Array(value.utf8)
        return setxattr(path, name, bytes, bytes.count, 0, 0) == 0 ? 0 : errno
    }
}
