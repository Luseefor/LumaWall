import Foundation

public struct EnergySample: Codable, Equatable, Sendable {
    public var date: Date
    public var processCPUPercent: Double
    public var systemCPUPercent: Double
    public var processMemoryMB: Double
    public var batteryPercent: Int
    public var isOnBattery: Bool
    public var decoderCount: Int
    public var powerProfile: String
    public var playbackActive: Bool

    public init(
        date: Date = .now,
        processCPUPercent: Double,
        systemCPUPercent: Double,
        processMemoryMB: Double,
        batteryPercent: Int,
        isOnBattery: Bool,
        decoderCount: Int,
        powerProfile: String,
        playbackActive: Bool
    ) {
        self.date = date
        self.processCPUPercent = processCPUPercent
        self.systemCPUPercent = systemCPUPercent
        self.processMemoryMB = processMemoryMB
        self.batteryPercent = batteryPercent
        self.isOnBattery = isOnBattery
        self.decoderCount = decoderCount
        self.powerProfile = powerProfile
        self.playbackActive = playbackActive
    }
}

public struct EnergySoakReport: Equatable, Sendable {
    public var startedAt: Date
    public var endedAt: Date
    public var sampleCount: Int
    public var durationHours: Double
    public var averageProcessCPU: Double
    public var peakProcessCPU: Double
    public var averageMemoryMB: Double
    public var peakMemoryMB: Double
    public var averageDecoders: Double
    public var peakDecoders: Int
    public var batteryStartPercent: Int?
    public var batteryEndPercent: Int?
    public var batteryDeltaPercent: Int?
    public var onBatterySampleRatio: Double
    public var meets24HourGate: Bool

    public var proofSummary: String {
        let hours = String(format: "%.1f", durationHours)
        let cpu = String(format: "%.2f", averageProcessCPU)
        let peakCPU = String(format: "%.1f", peakProcessCPU)
        let ram = String(format: "%.0f", averageMemoryMB)
        let peakRAM = String(format: "%.0f", peakMemoryMB)
        let decoders = String(format: "%.2f", averageDecoders)
        var lines = [
            "LumaWall Energy Log",
            "Window: \(hours)h · \(sampleCount) samples",
            "App CPU avg \(cpu)% (peak \(peakCPU)%)",
            "RAM avg \(ram) MB (peak \(peakRAM) MB)",
            "Decoders avg \(decoders) (peak \(peakDecoders))",
            "Battery samples: \(Int((onBatterySampleRatio * 100).rounded()))%"
        ]
        if let start = batteryStartPercent, let end = batteryEndPercent, let delta = batteryDeltaPercent {
            lines.append("Battery \(start)% → \(end)% (Δ \(delta)) while on battery")
        }
        lines.append(meets24HourGate ? "24h threshold met" : "Under 24h (still collecting)")
        return lines.joined(separator: "\n")
    }
}

public struct EnergyLogSnapshot: Codable, Equatable, Sendable {
    public var samples: [EnergySample]
    public var soakStartedAt: Date?

    public init(samples: [EnergySample] = [], soakStartedAt: Date? = nil) {
        self.samples = samples
        self.soakStartedAt = soakStartedAt
    }
}

/// Energy samples for the 24 h soak report.
///
/// `EnergyLog.json` holds a snapshot (samples plus the soak start). New samples
/// are appended as one JSON line each to a journal, `EnergyLog.samples.<n>.jsonl`,
/// instead of rewriting the snapshot every minute. The snapshot records which
/// journal generation `<n>` belongs to it. Compaction writes a snapshot naming
/// generation `<n+1>` before deleting journal `<n>`, so a crash or failed delete
/// leaves a journal the snapshot no longer names, and it is never replayed.
public actor EnergyLogStore {
    public static let retention: TimeInterval = 24 * 60 * 60
    /// Journal lines (one day of minute samples) before the next append compacts.
    public static let defaultCompactionThreshold = 1_440
    private static let journalPrefix = "EnergyLog.samples."

    private struct PersistedLog: Codable {
        var samples: [EnergySample]
        var soakStartedAt: Date?
        /// Absent in files written before the journal existed.
        var journalGeneration: Int?
    }

    private let base: URL
    private let fileURL: URL
    private let compactionThreshold: Int
    private var generation = 0
    private var snapshot = EnergyLogSnapshot()
    private var appendedLines = 0

    public init(rootURL: URL? = nil, compactionThreshold: Int = EnergyLogStore.defaultCompactionThreshold) throws {
        let base = try StorePaths.appSupportBase(rootURL: rootURL)
        self.base = base
        self.fileURL = base.appendingPathComponent("EnergyLog.json")
        self.compactionThreshold = max(1, compactionThreshold)
        let persisted = StoreIO.readJSON(from: fileURL, as: PersistedLog.self)
        let generation = persisted?.journalGeneration ?? 0
        var loaded = EnergyLogSnapshot(samples: persisted?.samples ?? [], soakStartedAt: persisted?.soakStartedAt)
        let journalURL = Self.journalURL(in: base, generation: generation)
        let hasJournal = FileManager.default.fileExists(atPath: journalURL.path)
        loaded.samples.append(contentsOf: Self.readJournal(at: journalURL))
        let pruned = Self.pruned(loaded, now: .now)
        self.generation = generation
        self.snapshot = pruned
        // Any journal, even one holding only a torn line, is folded into the
        // snapshot so appends always start on a clean file.
        if hasJournal || pruned.samples.count != loaded.samples.count {
            if (try? Self.writeCompacted(pruned, generation: generation + 1, base: base, fileURL: fileURL)) != nil {
                self.generation = generation + 1
            }
        } else {
            Self.removeJournals(in: base, keeping: generation)
        }
    }

    public func current() -> EnergyLogSnapshot { snapshot }

    public func startSoak(at date: Date = .now) throws {
        snapshot.soakStartedAt = date
        try compactNow()
    }

    public func clearSoak() throws {
        snapshot.soakStartedAt = nil
        try compactNow()
    }

    public func record(_ sample: EnergySample, now: Date = .now) throws {
        snapshot.samples.append(sample)
        snapshot = Self.pruned(snapshot, now: now)
        try append(sample)
        if appendedLines >= compactionThreshold {
            try compactNow()
        }
    }

    public func report(now: Date = .now) -> EnergySoakReport? {
        snapshot = Self.pruned(snapshot, now: now)
        let start = snapshot.soakStartedAt ?? snapshot.samples.first?.date
        guard let start else { return nil }
        let window = snapshot.samples.filter { $0.date >= start && $0.date <= now }
        guard !window.isEmpty else { return nil }
        return Self.makeReport(samples: window, startedAt: start, endedAt: now)
    }

    public static func makeReport(
        samples: [EnergySample],
        startedAt: Date,
        endedAt: Date
    ) -> EnergySoakReport {
        let cpu = samples.map(\.processCPUPercent)
        let memory = samples.map(\.processMemoryMB)
        let decoders = samples.map(\.decoderCount)
        let onBattery = samples.filter(\.isOnBattery)
        let batteryDelta: Int?
        let batteryStart = onBattery.first?.batteryPercent
        let batteryEnd = onBattery.last?.batteryPercent
        if let batteryStart, let batteryEnd {
            batteryDelta = batteryEnd - batteryStart
        } else {
            batteryDelta = nil
        }
        let duration = max(0, endedAt.timeIntervalSince(startedAt))
        return EnergySoakReport(
            startedAt: startedAt,
            endedAt: endedAt,
            sampleCount: samples.count,
            durationHours: duration / 3_600,
            averageProcessCPU: average(cpu),
            peakProcessCPU: cpu.max() ?? 0,
            averageMemoryMB: average(memory),
            peakMemoryMB: memory.max() ?? 0,
            averageDecoders: average(decoders.map(Double.init)),
            peakDecoders: decoders.max() ?? 0,
            batteryStartPercent: batteryStart,
            batteryEndPercent: batteryEnd,
            batteryDeltaPercent: batteryDelta,
            onBatterySampleRatio: samples.isEmpty ? 0 : Double(onBattery.count) / Double(samples.count),
            meets24HourGate: duration >= retention - 60
        )
    }

    /// Writes the snapshot under the next journal generation, then deletes the
    /// older journals.
    private func compactNow() throws {
        try Self.writeCompacted(snapshot, generation: generation + 1, base: base, fileURL: fileURL)
        generation += 1
        appendedLines = 0
    }

    private static func writeCompacted(
        _ snapshot: EnergyLogSnapshot, generation: Int, base: URL, fileURL: URL
    ) throws {
        let persisted = PersistedLog(
            samples: snapshot.samples,
            soakStartedAt: snapshot.soakStartedAt,
            journalGeneration: generation
        )
        try StoreIO.writeJSON(persisted, to: fileURL)
        removeJournals(in: base, keeping: generation)
    }

    private func append(_ sample: EnergySample) throws {
        var line = try Self.lineEncoder.encode(sample)
        line.append(0x0A)
        let url = Self.journalURL(in: base, generation: generation)
        if FileManager.default.fileExists(atPath: url.path) {
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
        } else {
            try line.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        }
        appendedLines += 1
    }

    private static func journalURL(in base: URL, generation: Int) -> URL {
        base.appendingPathComponent("\(journalPrefix)\(generation).jsonl")
    }

    /// Deletes every journal except the one for `generation`, including
    /// stale ones and the unnumbered name an earlier build used.
    private static func removeJournals(in base: URL, keeping generation: Int) {
        let keep = journalURL(in: base, generation: generation).lastPathComponent
        let names = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
        for name in names where name.hasPrefix(journalPrefix) && name != keep {
            try? FileManager.default.removeItem(at: base.appendingPathComponent(name))
        }
    }

    private static var lineEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// Skips lines that don't decode, such as one cut short by a crash.
    private static func readJournal(at url: URL) -> [EnergySample] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder.lumaWall
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(EnergySample.self, from: Data($0)) }
    }

    private static func pruned(_ snapshot: EnergyLogSnapshot, now: Date) -> EnergyLogSnapshot {
        let cutoff = now.addingTimeInterval(-retention)
        var next = snapshot
        next.samples.removeAll { $0.date < cutoff }
        return next
    }

    private static func average(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }
}
