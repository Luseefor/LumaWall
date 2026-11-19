import CoreGraphics
import CryptoKit
import Foundation
import os

/// One still in WallpaperAgent's cache directory, named the way the Agent
/// names its own: `<sha256 of choice>-<width>-<height>-0-<16 hex>.bmp`. The
/// last field used to be the write time; it now holds the video file's
/// modification time (still a timestamp bit pattern), so a replaced video
/// gets a new entry instead of matching the old frame.
struct StillCacheEntry: Hashable, Sendable {
    let choiceHash: String
    let width: Int
    let height: Int
    let version: UInt64

    init(choiceHash: String, width: Int, height: Int, version: UInt64) {
        self.choiceHash = choiceHash
        self.width = width
        self.height = height
        self.version = version
    }

    /// Nil for anything that isn't a still in this layout.
    init?(fileName: String) {
        guard fileName.hasSuffix(".bmp") else { return nil }
        let parts = fileName.dropLast(4).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 5, parts[0].count == 64, parts[3] == "0",
              let width = Int(parts[1]), let height = Int(parts[2]),
              let version = UInt64(parts[4], radix: 16) else { return nil }
        self.init(choiceHash: String(parts[0]), width: width, height: height, version: version)
    }

    var fileName: String {
        "\(choiceHash)-\(width)-\(height)-0-\(String(format: "%016llx", version)).bmp"
    }

    func sameContent(as other: StillCacheEntry) -> Bool {
        choiceHash == other.choiceHash && version == other.version
    }
}

/// A still on disk. `modified` is bumped on every hit, so it orders entries
/// by last use.
struct StillCacheFile: Sendable {
    let entry: StillCacheEntry
    let bytes: Int
    let modified: Date
}

struct StillSize: Hashable, Sendable {
    let width: Int
    let height: Int
}

/// Decisions for the still cache. The file I/O lives in BMPCache.swift.
enum StillCache {
    /// About ten 4K stills (24.9 MB each).
    static let byteBudget = 256 << 20

    enum Source: Equatable {
        /// The entry is already on disk.
        case existing
        /// The same video's still is cached for another display size. The
        /// BMP holds the video's own frame whatever the display size, so a
        /// copy (an APFS clone) is the same file without a decode.
        case copy(from: StillCacheEntry)
        case decode
    }

    static func choiceHash(_ identifier: String) -> String {
        SHA256.hash(data: Data(identifier.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func version(modified: Date?) -> UInt64 {
        modified?.timeIntervalSinceReferenceDate.bitPattern ?? 0
    }

    static func source(for target: StillCacheEntry, in files: [StillCacheFile]) -> Source {
        if files.contains(where: { $0.entry == target }) { return .existing }
        if let sibling = files.first(where: { $0.entry.sameContent(as: target) }) { return .copy(from: sibling.entry) }
        return .decode
    }

    /// Entries to delete after writing `keeping`: every other version of a
    /// kept wallpaper, then the least recently used until the total fits
    /// `budget`. The kept entries are never removed, even over budget.
    static func evictions(_ files: [StillCacheFile], keeping: Set<StillCacheEntry>, budget: Int) -> [StillCacheEntry] {
        let isStale = { (entry: StillCacheEntry) in
            keeping.contains { $0.choiceHash == entry.choiceHash && $0.version != entry.version }
        }
        let stale = files.filter { isStale($0.entry) }
        let live = files.filter { !isStale($0.entry) }
        var removed = stale.map(\.entry)
        var total = live.reduce(0) { $0 + $1.bytes }
        let candidates = live.filter { !keeping.contains($0.entry) }.sorted { $0.modified < $1.modified }
        for file in candidates where total > budget {
            removed.append(file.entry)
            total -= file.bytes
        }
        return removed
    }

    /// The still to seed a new renderer with, best first: this video at this
    /// size, this video at another size (same pixels), an older version of
    /// this wallpaper, then the most recent still of any wallpaper, which is
    /// what the extension showed before entries were versioned.
    static func lookup(_ files: [StillCacheFile], choiceHash: String, version: UInt64, width: Int, height: Int) -> StillCacheFile? {
        let target = StillCacheEntry(choiceHash: choiceHash, width: width, height: height, version: version)
        let newestFirst = files.sorted { $0.modified > $1.modified }
        return newestFirst.first { $0.entry == target }
            ?? newestFirst.first { $0.entry.sameContent(as: target) }
            ?? newestFirst.first { $0.entry.choiceHash == choiceHash }
            ?? newestFirst.first
    }
}

/// Coalesces concurrent cache misses. Each group is one wallpaper version;
/// the first caller leads and writes, later callers hand their size to the
/// leader, which writes each size once (by copy) before the group ends.
final class StillCacheFlights: Sendable {
    private struct Group {
        var claimed: Set<StillSize>
        var queue: [StillSize] = []
    }

    private let groups = OSAllocatedUnfairLock<[String: Group]>(initialState: [:])

    /// True if the caller leads the write for `group`. False means a write is
    /// in flight and its leader will also write `size`.
    func join(_ group: String, size: StillSize) -> Bool {
        groups.withLock { groups in
            guard var flight = groups[group] else {
                groups[group] = Group(claimed: [size])
                return true
            }
            if flight.claimed.insert(size).inserted { flight.queue.append(size) }
            groups[group] = flight
            return false
        }
    }

    /// The leader's next size to write, or nil, which ends the group so the
    /// next miss leads a new one.
    func next(_ group: String) -> StillSize? {
        groups.withLock { groups in
            guard var flight = groups[group], !flight.queue.isEmpty else {
                groups[group] = nil
                return nil
            }
            let size = flight.queue.removeFirst()
            groups[group] = flight
            return size
        }
    }
}

extension StillCache {
    /// A top-down 24bpp BGR BMP of `image`. Converts through a 64-row BGRA strip
    /// into the output buffer, so the only full-frame allocation is the file.
    static func encodeBMP(_ image: CGImage) -> Data? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        let paddedRowBytes = (width * 3 + 3) & ~3
        let pixelDataSize = paddedRowBytes * height
        let fileHeaderSize = 14
        let dibHeaderSize = 40
        let headerSize = fileHeaderSize + dibHeaderSize

        var bmp = Data(count: headerSize + pixelDataSize)
        bmp[0] = 0x42; bmp[1] = 0x4D // "BM"
        bmpWriteLE32(&bmp, offset: 2, value: UInt32(headerSize + pixelDataSize))
        bmpWriteLE32(&bmp, offset: 10, value: UInt32(headerSize))
        let d = fileHeaderSize
        bmpWriteLE32(&bmp, offset: d, value: UInt32(dibHeaderSize))
        bmpWriteLE32(&bmp, offset: d + 4, value: UInt32(bitPattern: Int32(width)))
        bmpWriteLE32(&bmp, offset: d + 8, value: UInt32(bitPattern: Int32(-height))) // top-down
        bmpWriteLE16(&bmp, offset: d + 12, value: 1) // planes
        bmpWriteLE16(&bmp, offset: d + 14, value: 24) // bits per pixel
        bmpWriteLE32(&bmp, offset: d + 16, value: 0) // BI_RGB
        bmpWriteLE32(&bmp, offset: d + 20, value: UInt32(pixelDataSize))

        let stripRows = min(64, height)
        let stripRowBytes = width * 4
        var strip = [UInt8](repeating: 0, count: stripRowBytes * stripRows)
        let converted = strip.withUnsafeMutableBytes { stripBuf -> Bool in
            guard let ctx = CGContext(
                data: stripBuf.baseAddress,
                width: width,
                height: stripRows,
                bitsPerComponent: 8,
                bytesPerRow: stripRowBytes,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue,
            ) else { return false }
            ctx.interpolationQuality = .none
            let src = stripBuf.baseAddress!.assumingMemoryBound(to: UInt8.self)
            return bmp.withUnsafeMutableBytes { out -> Bool in
                let pixels = out.baseAddress!.advanced(by: headerSize).assumingMemoryBound(to: UInt8.self)
                for top in stride(from: 0, to: height, by: stripRows) {
                    let rows = min(stripRows, height - top)
                    // Crop rects count rows from the top; a bitmap context's first
                    // row in memory is its top, so the band lands at rows 0..<rows.
                    guard let band = image.cropping(to: CGRect(x: 0, y: top, width: width, height: rows)) else { return false }
                    ctx.clear(CGRect(x: 0, y: 0, width: width, height: stripRows))
                    ctx.draw(band, in: CGRect(x: 0, y: stripRows - rows, width: width, height: rows))
                    for r in 0 ..< rows {
                        let s = src + r * stripRowBytes
                        let o = pixels + (top + r) * paddedRowBytes
                        for x in 0 ..< width {
                            o[x * 3] = s[x * 4] // B
                            o[x * 3 + 1] = s[x * 4 + 1] // G
                            o[x * 3 + 2] = s[x * 4 + 2] // R
                        }
                    }
                }
                return true
            }
        }
        return converted ? bmp : nil
    }

    private static func bmpWriteLE32(_ data: inout Data, offset: Int, value: UInt32) {
        data[offset] = UInt8(value & 0xFF)
        data[offset + 1] = UInt8((value >> 8) & 0xFF)
        data[offset + 2] = UInt8((value >> 16) & 0xFF)
        data[offset + 3] = UInt8((value >> 24) & 0xFF)
    }

    private static func bmpWriteLE16(_ data: inout Data, offset: Int, value: UInt16) {
        data[offset] = UInt8(value & 0xFF)
        data[offset + 1] = UInt8((value >> 8) & 0xFF)
    }
}
