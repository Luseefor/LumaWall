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
/// generation `<n+1>`, syncs it, then deletes journal `<n>`, so a crash or failed
/// delete leaves a journal the snapshot no longer names, and it is never
/// replayed. If the snapshot or a journal can't be read, the store stops
/// writing so recovery stays possible (see `EnergyLogDisk.load`).
public actor EnergyLogStore {
    public static let retention: TimeInterval = 24 * 60 * 60
    /// Journal lines (one day of minute samples) before the next append compacts.
    public static let defaultCompactionThreshold = 1_440

    public enum StoreError: LocalizedError {
        case persistenceSuspended

        public var errorDescription: String? {
            "The energy log couldn't be read, so it was left unchanged."
        }
    }

    private let disk: EnergyLogDisk
    private let compactionThreshold: Int
    private var generation = 0
    private var snapshot = EnergyLogSnapshot()
    private var appendedLines = 0
    private var suspended = false

    public init(rootURL: URL? = nil, compactionThreshold: Int = EnergyLogStore.defaultCompactionThreshold) throws {
        let disk = EnergyLogDisk(base: try StorePaths.appSupportBase(rootURL: rootURL))
        self.disk = disk
        self.compactionThreshold = max(1, compactionThreshold)
        let loaded = disk.load()
        let pruned = Self.pruned(loaded.snapshot, now: .now)
        snapshot = pruned
        generation = loaded.generation
        appendedLines = loaded.journalLines
        suspended = loaded.suspended
        guard !suspended else { return }
        if loaded.needsCompaction || pruned.samples.count != loaded.snapshot.samples.count {
            // On failure the journals stay and `appendedLines` keeps counting
            // them, so the next record retries.
            if let next = try? Self.compact(pruned, to: generation + 1, disk: disk) {
                generation = next
                appendedLines = 0
            }
        } else {
            disk.removeJournals(olderThan: generation)
        }
    }

    public func current() -> EnergyLogSnapshot { snapshot }

    public func startSoak(at date: Date = .now) throws {
        guard !suspended else { throw StoreError.persistenceSuspended }
        snapshot.soakStartedAt = date
        try compactNow()
    }

    public func clearSoak() throws {
        guard !suspended else { throw StoreError.persistenceSuspended }
        snapshot.soakStartedAt = nil
        try compactNow()
    }

    public func record(_ sample: EnergySample, now: Date = .now) throws {
        snapshot.samples.append(sample)
        snapshot = Self.pruned(snapshot, now: now)
        guard !suspended else { return }
        try disk.append(sample, generation: generation)
        appendedLines += 1
        if appendedLines >= compactionThreshold {
            // The sample is already saved; a failed compaction retries on the
            // next record.
            try? compactNow()
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
    /// older journals once the snapshot is on stable storage.
    private func compactNow() throws {
        generation = try Self.compact(snapshot, to: generation + 1, disk: disk)
        appendedLines = 0
    }

    /// Returns the new generation. Throws only when the snapshot was not replaced.
    private static func compact(_ snapshot: EnergyLogSnapshot, to next: Int, disk: EnergyLogDisk) throws -> Int {
        try disk.writeSnapshot(snapshot, generation: next)
        // The snapshot now names `next`, so appends must follow it even if the
        // sync fails; the older journals then stay until a later compaction.
        if disk.syncSnapshot() {
            disk.removeJournals(except: next)
        }
        return next
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
