import Foundation

/// File layer of `EnergyLogStore`: the snapshot, the numbered journals, and the
/// recovery rules for reading them back.
struct EnergyLogDisk: Sendable {
    struct PersistedLog: Codable {
        var samples: [EnergySample]
        var soakStartedAt: Date?
        /// Absent in files written before the journal existed.
        var journalGeneration: Int?
    }

    /// What launch found on disk.
    struct Loaded {
        var snapshot = EnergyLogSnapshot()
        /// Generation the next append goes to.
        var generation = 0
        /// Lines already in the journals that were replayed.
        var journalLines = 0
        /// Replayed journals should be folded into a fresh snapshot.
        var needsCompaction = false
        /// The snapshot or a journal could not be read. Nothing may be written
        /// or deleted, since a read failure says nothing about the contents.
        var suspended = false
    }

    private enum SnapshotRead {
        case missing
        case loaded(PersistedLog)
        case corrupt
        case unreadable
    }

    static let journalPrefix = "EnergyLog.samples."
    let base: URL
    let fileURL: URL

    init(base: URL) {
        self.base = base
        self.fileURL = base.appendingPathComponent("EnergyLog.json")
    }

    func journalURL(generation: Int) -> URL {
        base.appendingPathComponent("\(Self.journalPrefix)\(generation).jsonl")
    }

    /// Generations of the journals on disk, ascending.
    func journalGenerations() -> [Int] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
        return names.compactMap { name -> Int? in
            guard name.hasPrefix(Self.journalPrefix), name.hasSuffix(".jsonl") else { return nil }
            return Int(name.dropFirst(Self.journalPrefix.count).dropLast(".jsonl".count))
        }.sorted()
    }

    // MARK: Reading

    /// Rules:
    /// - A snapshot naming generation `n` is complete up to journal `n`; only
    ///   that journal is replayed, and older ones are stale.
    /// - A missing or corrupt snapshot, or journals newer than the snapshot,
    ///   leave no generation to trust, so every journal is replayed (oldest
    ///   first, duplicates dropped).
    /// - A snapshot or journal that exists but can't be read suspends writing
    ///   altogether; a corrupt snapshot is quarantined by `StoreIO.readJSON`.
    func load() -> Loaded {
        var loaded = Loaded()
        let generations = journalGenerations()
        var trusted: Int?
        switch readSnapshot() {
        case .unreadable:
            loaded.suspended = true
            return loaded
        case .loaded(let persisted):
            loaded.snapshot = EnergyLogSnapshot(samples: persisted.samples, soakStartedAt: persisted.soakStartedAt)
            trusted = persisted.journalGeneration ?? 0
        case .missing, .corrupt:
            break
        }
        let replay: [Int]
        let replayAll: Bool
        if let trusted, !generations.contains(where: { $0 > trusted }) {
            replay = generations.filter { $0 == trusted }
            replayAll = false
        } else {
            replay = generations
            replayAll = true
        }
        loaded.generation = max(trusted ?? 0, generations.last ?? 0)
        var replayed: [EnergySample] = []
        for generation in replay {
            guard let journal = Self.readJournal(at: journalURL(generation: generation)) else {
                loaded.suspended = true
                return loaded
            }
            replayed.append(contentsOf: journal.samples)
            loaded.journalLines += journal.lines
        }
        if replayAll {
            var seen = Set<Date>()
            let unique = (loaded.snapshot.samples + replayed).filter { seen.insert($0.date).inserted }
            loaded.snapshot.samples = unique.sorted { $0.date < $1.date }
        } else {
            loaded.snapshot.samples.append(contentsOf: replayed)
        }
        // Any journal, even one holding only a torn line, is folded into the
        // snapshot so appends start on a clean file.
        loaded.needsCompaction = !replay.isEmpty
        return loaded
    }

    private func readSnapshot() -> SnapshotRead {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .missing }
        guard let data = try? Data(contentsOf: fileURL) else { return .unreadable }
        if let decoded = try? JSONDecoder.lumaWall.decode(PersistedLog.self, from: data) {
            return .loaded(decoded)
        }
        // Moves the undecodable file aside so a later write can't destroy it.
        _ = StoreIO.readJSON(from: fileURL, as: PersistedLog.self)
        return .corrupt
    }

    /// Lines that don't decode, such as one cut short by a crash, are skipped.
    /// Returns nil when the file exists but can't be read.
    private static func readJournal(at url: URL) -> (samples: [EnergySample], lines: Int)? {
        guard FileManager.default.fileExists(atPath: url.path) else { return ([], 0) }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder.lumaWall
        let lines = data.split(separator: 0x0A)
        return (lines.compactMap { try? decoder.decode(EnergySample.self, from: Data($0)) }, lines.count)
    }

    // MARK: Writing

    /// Replaces the snapshot with one naming `generation`. Throws only if the
    /// snapshot was not replaced.
    func writeSnapshot(_ snapshot: EnergyLogSnapshot, generation: Int) throws {
        let persisted = PersistedLog(
            samples: snapshot.samples,
            soakStartedAt: snapshot.soakStartedAt,
            journalGeneration: generation
        )
        try StoreIO.writeJSON(persisted, to: fileURL)
    }

    /// Flushes the snapshot and its directory entry to stable storage. The
    /// older journals may be deleted only after this succeeds.
    func syncSnapshot() -> Bool {
        Self.fullSync(fileURL) && Self.fullSync(base)
    }

    func removeJournals(except keep: Int) {
        for generation in journalGenerations() where generation != keep {
            try? FileManager.default.removeItem(at: journalURL(generation: generation))
        }
    }

    func removeJournals(olderThan generation: Int) {
        for existing in journalGenerations() where existing < generation {
            try? FileManager.default.removeItem(at: journalURL(generation: existing))
        }
    }

    func append(_ sample: EnergySample, generation: Int) throws {
        var line = try Self.lineEncoder.encode(sample)
        line.append(0x0A)
        let url = journalURL(generation: generation)
        guard FileManager.default.fileExists(atPath: url.path) else {
            try line.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
            return
        }
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        if end > 0 {
            // A write cut short earlier leaves an unterminated line; end it
            // so this record isn't glued onto it.
            try handle.seek(toOffset: end - 1)
            if try handle.read(upToCount: 1)?.first != 0x0A {
                try handle.seekToEnd()
                try handle.write(contentsOf: Data([0x0A]))
            }
        }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    private static var lineEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func fullSync(_ url: URL) -> Bool {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        return fcntl(descriptor, F_FULLFSYNC) == 0 || fsync(descriptor) == 0
    }
}
