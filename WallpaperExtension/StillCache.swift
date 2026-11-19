import CoreGraphics
import CryptoKit
import Foundation

/// Which wallpaper and display size a still is for.
struct StillCacheKey: Hashable, Sendable {
    let choiceHash: String
    let width: Int
    let height: Int
}

/// One still in WallpaperAgent's cache directory, named as the extension has
/// always named them: `<sha256 of choice>-<width>-<height>-0-<16 hex>.bmp`,
/// where the last field is the write time as a Double bit pattern. Which
/// video the frame came from is kept in an extended attribute, not the name.
struct StillCacheEntry: Hashable, Sendable {
    let key: StillCacheKey
    let written: UInt64

    init(key: StillCacheKey, written: UInt64) {
        self.key = key
        self.written = written
    }

    /// Nil for anything that isn't a still in this layout.
    init?(fileName: String) {
        guard fileName.hasSuffix(".bmp") else { return nil }
        let parts = fileName.dropLast(4).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 5, parts[0].count == 64, parts[3] == "0",
              let width = Int(parts[1]), let height = Int(parts[2]),
              let written = UInt64(parts[4], radix: 16) else { return nil }
        self.init(key: StillCacheKey(choiceHash: String(parts[0]), width: width, height: height), written: written)
    }

    var fileName: String {
        "\(key.choiceHash)-\(key.width)-\(key.height)-0-\(String(format: "%016llx", written)).bmp"
    }
}

/// A still on disk as a scan sees it.
struct StillCacheFile: Sendable {
    let entry: StillCacheEntry
    let bytes: Int
    /// The video it was decoded from (`StillCache.version`), or nil for a
    /// file written before versions were recorded.
    let version: String?
    let lastUsed: Date
    /// The BMP header's file size matches the bytes on disk.
    let isComplete: Bool

    /// A nil `choiceHash` matches any wallpaper: a version names one file.
    func holds(_ choiceHash: String?, version: String) -> Bool {
        isComplete && (choiceHash == nil || entry.key.choiceHash == choiceHash) && self.version == version
    }
}

struct StillSize: Hashable, Sendable {
    let width: Int
    let height: Int
}

/// Decisions for the still cache. StillCacheStore does the file I/O.
enum StillCache {
    /// About ten 4K stills (24.9 MB each).
    static let byteBudget = 256 << 20

    enum Source: Equatable {
        case existing(StillCacheEntry)
        /// This video's still is cached for another display size. The BMP
        /// holds the video's own frame whatever the display size, so a copy
        /// (an APFS clone) is the same file without a decode.
        case copy(from: StillCacheEntry)
        case decode
    }

    static func choiceHash(_ identifier: String) -> String {
        SHA256.hash(data: Data(identifier.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Identifies the video a still was decoded from. A shuffle choice
    /// resolves to different files under one choice hash, and a replaced file
    /// keeps its path, so all three parts count.
    static func version(path: String, modified: Date?, size: Int?) -> String {
        let identity = "\(path)\n\(modified?.timeIntervalSinceReferenceDate.bitPattern ?? 0)\n\(size ?? -1)"
        return SHA256.hash(data: Data(identity.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func source(for key: StillCacheKey, version: String, in files: [StillCacheFile]) -> Source {
        let usable = files.filter { $0.holds(key.choiceHash, version: version) }.sorted { $0.entry.written > $1.entry.written }
        if let exact = usable.first(where: { $0.entry.key == key }) { return .existing(exact.entry) }
        if let sibling = usable.first { return .copy(from: sibling.entry) }
        return .decode
    }

    /// Stills of this video that can seed a renderer, best first: this size,
    /// then other sizes (same pixels). Never another wallpaper or video.
    static func candidates(_ files: [StillCacheFile], choiceHash: String?, version: String, size: StillSize) -> [StillCacheFile] {
        files.filter { $0.holds(choiceHash, version: version) }.sorted { a, b in
            let aExact = a.entry.key.width == size.width && a.entry.key.height == size.height
            let bExact = b.entry.key.width == size.width && b.entry.key.height == size.height
            return aExact != bExact ? aExact : a.entry.written > b.entry.written
        }
    }

    /// Entries to delete: incomplete files, all but the newest file per key,
    /// other versions of `current`'s wallpaper, then the least recently used
    /// until the total fits `budget`. Only `keeping`, the entry just written
    /// or hit, survives over budget.
    static func evictions(
        _ files: [StillCacheFile], current: (choiceHash: String, version: String)?,
        keeping: StillCacheEntry?, budget: Int,
    ) -> [StillCacheEntry] {
        var newest: [StillCacheKey: UInt64] = [:]
        for file in files where file.isComplete {
            newest[file.entry.key] = max(newest[file.entry.key] ?? 0, file.entry.written)
        }
        let isDead = { (file: StillCacheFile) -> Bool in
            if file.entry == keeping { return false }
            if !file.isComplete || file.entry.written != newest[file.entry.key] { return true }
            if let current, file.entry.key.choiceHash == current.choiceHash, file.version != current.version { return true }
            return false
        }
        var removed = files.filter(isDead).map(\.entry)
        let live = files.filter { !isDead($0) }
        var total = live.reduce(0) { $0 + $1.bytes }
        for file in live.sorted(by: { $0.lastUsed < $1.lastUsed }) where total > budget && file.entry != keeping {
            removed.append(file.entry)
            total -= file.bytes
        }
        return removed
    }
}

/// Coalesces concurrent misses. Each group is one wallpaper's video; the
/// first caller leads, later callers hand their size to the leader, which
/// writes each size once before the group ends.
struct StillCacheFlights {
    private struct Group {
        var claimed: Set<StillSize>
        var queue: [StillSize] = []
    }

    private var groups: [String: Group] = [:]

    /// True if the caller leads `group`. False means a write is in flight
    /// and its leader will also write `size`.
    mutating func join(_ group: String, size: StillSize) -> Bool {
        guard var flight = groups[group] else {
            groups[group] = Group(claimed: [size])
            return true
        }
        if flight.claimed.insert(size).inserted { flight.queue.append(size) }
        groups[group] = flight
        return false
    }

    /// The leader's next size, or nil, which ends the group so the next miss
    /// leads a new one.
    mutating func next(_ group: String) -> StillSize? {
        guard var flight = groups[group], !flight.queue.isEmpty else {
            groups[group] = nil
            return nil
        }
        let size = flight.queue.removeFirst()
        groups[group] = flight
        return size
    }
}

extension StillCache {
    static let bmpHeaderSize = 54

    /// The file size a BMP header written by `encodeBMP` promises, or nil if
    /// `header` isn't one. Comparing it with the bytes on disk catches a file
    /// cut short by an interrupted write.
    static func bmpFileSize(header: Data) -> Int? {
        guard header.count >= bmpHeaderSize else { return nil }
        let bytes = [UInt8](header.prefix(bmpHeaderSize))
        let le32 = { (o: Int) in UInt32(bytes[o]) | UInt32(bytes[o + 1]) << 8 | UInt32(bytes[o + 2]) << 16 | UInt32(bytes[o + 3]) << 24 }
        let width = Int(Int32(bitPattern: le32(18)))
        let height = abs(Int(Int32(bitPattern: le32(22))))
        guard bytes[0] == 0x42, bytes[1] == 0x4D, le32(10) == UInt32(bmpHeaderSize), le32(14) == 40,
              width > 0, height > 0, bytes[28] == 24, le32(30) == 0 else { return nil }
        let fileSize = bmpHeaderSize + ((width * 3 + 3) & ~3) * height
        return Int(le32(2)) == fileSize ? fileSize : nil
    }

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
