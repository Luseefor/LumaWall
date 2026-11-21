import Foundation
import CoreGraphics
import Darwin
import IOKit.ps

func selfTest() {
    let odd = Statistics([5, 1, 4, 2, 3])
    precondition(odd?.median == 3 && odd?.iqr == 2, "Unsorted odd sample")
    let even = Statistics([0, 4, 8, 12])
    precondition(even?.median == 6 && even?.iqr == 6, "Even sample")
    let single = Statistics([7])
    precondition(single?.median == 7 && single?.iqr == 0, "Singleton")
    precondition(Statistics([]) == nil, "Empty sample")
    let appleSilicon = mach_timebase_info_data_t(numer: 125, denom: 3)
    precondition(cpuNanoseconds(ticks: 24_000_000, timebase: appleSilicon) == 1_000_000_000, "Mach ticks to nanoseconds")
    print("Statistics and CPU conversion self-tests passed")
}

struct Statistics: Encodable {
    let count: Int
    let median: Double
    let min: Double
    let max: Double
    let iqr: Double

    init?(_ values: [Double]) {
        let sorted = values.sorted()
        guard let first = sorted.first, let last = sorted.last else { return nil }

        func quantile(_ fraction: Double) -> Double {
            let position = fraction * Double(sorted.count - 1)
            let lower = Int(position.rounded(.down))
            let upper = Int(position.rounded(.up))
            return sorted[lower] + (position - Double(lower)) * (sorted[upper] - sorted[lower])
        }

        count = sorted.count
        median = quantile(0.5)
        min = first
        max = last
        iqr = quantile(0.75) - quantile(0.25)
    }
}

struct BenchmarkError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

let usage = """
    Usage: swift scripts/benchmark-power.swift --label <name> [--duration 60] [--runs 5]
           [--output /tmp/lumawall-power.jsonl]
           swift scripts/benchmark-power.swift --self-test
    """

struct Options {
    let label: String
    var duration = 60.0
    var runs = 5
    var output = "/tmp/lumawall-power.jsonl"

    init(_ arguments: [String]) throws {
        guard arguments.count.isMultiple(of: 2) else { throw BenchmarkError(usage) }

        var label: String?
        for index in stride(from: 0, to: arguments.count, by: 2) {
            let flag = arguments[index]
            let value = arguments[index + 1]
            switch flag {
            case "--label":
                guard !value.isEmpty else { throw BenchmarkError("Label must be nonempty") }
                label = value
            case "--duration":
                guard let seconds = Double(value), seconds.isFinite, seconds >= 0.01 else {
                    throw BenchmarkError("Duration must be a finite number of seconds (at least 0.01)")
                }
                duration = seconds
            case "--runs":
                guard let count = Int(value), count > 0 else {
                    throw BenchmarkError("Runs must be a positive integer")
                }
                runs = count
            case "--output":
                output = value
            default:
                throw BenchmarkError("Unknown option \(flag)\n\(usage)")
            }
        }
        guard let label else { throw BenchmarkError(usage) }
        self.label = label
    }
}

func sysctlString(_ key: String) -> String {
    var count = 0
    guard sysctlbyname(key, nil, &count, nil, 0) == 0, count > 0 else { return "unknown" }
    var bytes = [UInt8](repeating: 0, count: count)
    guard sysctlbyname(key, &bytes, &count, nil, 0) == 0 else { return "unknown" }
    return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
}

struct Machine: Encodable {
    let model = sysctlString("hw.model")
    let chip = sysctlString("machdep.cpu.brand_string")
    let macOS = ProcessInfo.processInfo.operatingSystemVersionString

    static func displayCount() -> UInt32? {
        var count: UInt32 = 0
        return CGGetOnlineDisplayList(0, nil, &count) == .success ? count : nil
    }

    static func powerSource() -> String {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue()
        else { return "unknown" }
        return source as String
    }
}

let processNames = ["LumaWall", "LumaWallWallpaper", "LumaWallMediaService"]
let subjects = processNames + ["Total"]

func cpuNanoseconds(ticks: Double, timebase: mach_timebase_info_data_t) -> Double {
    ticks * Double(timebase.numer) / Double(timebase.denom)
}

struct Counters {
    let startTime: UInt64
    let timestamp: UInt64
    let userTicks: UInt64
    let systemTicks: UInt64
    let energyNanojoules: UInt64

    init?(pid: pid_t) {
        var usage = rusage_info_v6()
        let status = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
            }
        }
        guard status == 0, usage.ri_proc_exit_abstime == 0 else { return nil }
        timestamp = DispatchTime.now().uptimeNanoseconds
        startTime = usage.ri_proc_start_abstime
        userTicks = usage.ri_user_time
        systemTicks = usage.ri_system_time
        energyNanojoules = usage.ri_energy_nj
    }

    func rates(since start: Counters, timebase: mach_timebase_info_data_t) -> Rates? {
        guard startTime == start.startTime, timestamp > start.timestamp,
            userTicks >= start.userTicks, systemTicks >= start.systemTicks,
            energyNanojoules >= start.energyNanojoules
        else { return nil }
        let elapsed = Double(timestamp - start.timestamp)
        let ticks =
            Double(userTicks - start.userTicks)
            + Double(systemTicks - start.systemTicks)
        let cpu = cpuNanoseconds(ticks: ticks, timebase: timebase)
        #if arch(arm64)
            let power = Double(energyNanojoules - start.energyNanojoules) / elapsed * 1000
        #else
            let power: Double? = nil
        #endif
        return Rates(milliwatts: power, cpuPercent: cpu / elapsed * 100)
    }
}

struct Snapshot {
    var pids: Set<pid_t> = []
    var counters: [pid_t: Counters] = [:]
}

func snapshots() throws -> [String: Snapshot] {
    let count = proc_listallpids(nil, 0)
    guard count > 0 else { throw BenchmarkError("Could not enumerate processes") }

    var pids = [pid_t](repeating: 0, count: Int(count) + 256)
    let found = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
    guard found > 0, found < pids.count else {
        throw BenchmarkError("Could not get a complete process list")
    }

    var result: [String: Snapshot] = [:]
    var nameBuffer = [CChar](repeating: 0, count: 64)
    for pid in pids.prefix(Int(found)) where pid > 0 {
        let length = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
        guard length > 0 else { continue }
        let name = String(decoding: nameBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard processNames.contains(name) else { continue }
        result[name, default: Snapshot()].pids.insert(pid)
        result[name, default: Snapshot()].counters[pid] = Counters(pid: pid)
    }
    return result
}

struct Rates: Encodable {
    let milliwatts: Double?
    let cpuPercent: Double

    static func sum(_ rates: [Rates]) -> Rates {
        let powers = rates.compactMap(\.milliwatts)
        return Rates(
            milliwatts: powers.count == rates.count ? powers.reduce(0, +) : nil,
            cpuPercent: rates.map(\.cpuPercent).reduce(0, +)
        )
    }
}

struct Reading: Encodable {
    let subject: String
    let pids: [pid_t]
    let status: String
    var rates: Rates? = nil
}

func compare(_ name: String, _ start: Snapshot, _ end: Snapshot, timebase: mach_timebase_info_data_t) -> Reading {
    let pids = start.pids.union(end.pids).sorted()
    guard !pids.isEmpty else { return Reading(subject: name, pids: [], status: "absent") }
    guard start.pids == end.pids else {
        return Reading(subject: name, pids: pids, status: "processes changed")
    }

    var rates: [Rates] = []
    for pid in pids {
        guard let before = start.counters[pid], let after = end.counters[pid] else {
            return Reading(subject: name, pids: pids, status: "counters unavailable")
        }
        guard let delta = after.rates(since: before, timebase: timebase) else {
            return Reading(subject: name, pids: pids, status: "process or counters changed")
        }
        rates.append(delta)
    }
    return Reading(subject: name, pids: pids, status: "ok", rates: Rates.sum(rates))
}

struct Run: Encodable {
    let type = "run"
    let sessionID: UUID
    let label: String
    let run: Int
    let timestamp: Date
    let durationSeconds: Double
    let machine: Machine
    let displayCount: UInt32?
    let powerSource: String
    let endDisplayCount: UInt32?
    let endPowerSource: String
    let environmentMatchesSession: Bool
    let readings: [Reading]
}

struct Summary: Encodable {
    let subject: String
    let milliwatts: Statistics?
    let cpuPercent: Statistics?
}

struct SummaryRecord: Encodable {
    let type = "summary"
    let sessionID: UUID
    let label: String
    let timestamp: Date
    let machine: Machine
    let statistics: [Summary]
}

func append<T: Encodable>(_ value: T, to file: FileHandle, with encoder: JSONEncoder) throws {
    var line = try encoder.encode(value)
    line.append(0x0a)
    try file.write(contentsOf: line)
}

func row(_ values: [String], widths: [Int]) {
    print(
        zip(values, widths).map { value, width in
            value.padding(toLength: max(value.count, width), withPad: " ", startingAt: 0)
        }.joined(separator: "  "))
}

func number(_ value: Double?) -> String {
    value.map { String(format: "%.3f", $0) } ?? "n/a"
}

func benchmark(_ options: Options) throws {
    var timebase = mach_timebase_info_data_t()
    guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.numer > 0, timebase.denom > 0 else {
        throw BenchmarkError("Could not read the Mach timebase")
    }

    let descriptor = open(options.output, O_WRONLY | O_CREAT | O_APPEND, 0o600)
    guard descriptor >= 0 else {
        throw BenchmarkError("Cannot open \(options.output): \(String(cString: strerror(errno)))")
    }
    let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    let machine = Machine()
    let sessionStart = Date()
    let sessionID = UUID()
    let initialDisplays = Machine.displayCount()
    let initialPower = Machine.powerSource()

    print("\(options.label) | \(machine.model) | \(machine.chip) | macOS \(machine.macOS)")
    print("Displays \(initialDisplays.map(String.init) ?? "unknown") | \(initialPower)")
    let runWidths = [4, 21, 12, 12, 0]
    row(["Run", "Process", "mW", "CPU %", "Status"], widths: runWidths)
    fflush(nil)

    var validRates: [String: [Rates]] = [:]
    for index in 1...options.runs {
        let displayCount = Machine.displayCount()
        let powerSource = Machine.powerSource()
        let timestamp = Date()
        let before = try snapshots()
        let started = DispatchTime.now().uptimeNanoseconds
        Thread.sleep(forTimeInterval: options.duration)
        let duration = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
        let after = try snapshots()

        var readings = processNames.map {
            compare($0, before[$0] ?? Snapshot(), after[$0] ?? Snapshot(), timebase: timebase)
        }
        let measured = readings.compactMap(\.rates)
        let complete = readings.allSatisfy { $0.status == "ok" || $0.status == "absent" }
        let total = complete && !measured.isEmpty ? Rates.sum(measured) : nil
        let totalStatus = complete ? (measured.isEmpty ? "absent" : "ok") : "incomplete"
        readings.append(Reading(subject: "Total", pids: readings.flatMap(\.pids).sorted(), status: totalStatus, rates: total))

        let endDisplays = Machine.displayCount()
        let endPower = Machine.powerSource()
        let include =
            displayCount == initialDisplays && endDisplays == initialDisplays
            && powerSource == initialPower && endPower == initialPower
        let run = Run(
            sessionID: sessionID, label: options.label, run: index, timestamp: timestamp,
            durationSeconds: duration, machine: machine, displayCount: displayCount, powerSource: powerSource,
            endDisplayCount: endDisplays, endPowerSource: endPower,
            environmentMatchesSession: include, readings: readings
        )
        try append(run, to: file, with: encoder)

        for reading in readings {
            let status = include ? reading.status : "\(reading.status); environment changed"
            row(
                [
                    String(index), reading.subject, number(reading.rates?.milliwatts),
                    number(reading.rates?.cpuPercent), status,
                ],
                widths: runWidths
            )
            if include, let rates = reading.rates {
                validRates[reading.subject, default: []].append(rates)
            }
        }
        fflush(nil)
    }

    let summaries = subjects.map { subject in
        let rates = validRates[subject, default: []]
        return Summary(
            subject: subject, milliwatts: Statistics(rates.compactMap(\.milliwatts)),
            cpuPercent: Statistics(rates.map(\.cpuPercent))
        )
    }
    print()
    let summaryWidths = [21, 7, 5, 12, 12, 12, 12]
    row(["Process", "Metric", "n", "Median", "Min", "Max", "IQR"], widths: summaryWidths)
    for summary in summaries {
        for (unit, stats) in [("mW", summary.milliwatts), ("CPU %", summary.cpuPercent)] {
            row(
                [
                    summary.subject, unit, String(stats?.count ?? 0), number(stats?.median),
                    number(stats?.min), number(stats?.max), number(stats?.iqr),
                ],
                widths: summaryWidths
            )
        }
    }

    try append(
        SummaryRecord(sessionID: sessionID, label: options.label, timestamp: sessionStart, machine: machine, statistics: summaries),
        to: file, with: encoder
    )
    print("\nResults appended to \(options.output)")
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    switch arguments {
    case ["--help"], ["-h"]:
        print(usage)
    case ["--self-test"]:
        selfTest()
    default:
        try benchmark(Options(arguments))
    }
} catch {
    FileHandle.standardError.write(Data("benchmark-power: \(error)\n".utf8))
    exit(1)
}
