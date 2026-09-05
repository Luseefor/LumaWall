import Foundation

public struct CrashReport: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case uncaughtException
        case signal
        case uncleanShutdown
    }

    public var id: UUID
    public var date: Date
    public var kind: Kind
    /// Signal name (e.g. "SIGSEGV") or exception name.
    public var name: String
    public var reason: String
    public var backtrace: [String]
    public var appVersion: String
    public var osVersion: String

    public init(
        id: UUID = UUID(),
        date: Date = .now,
        kind: Kind,
        name: String,
        reason: String,
        backtrace: [String] = [],
        appVersion: String,
        osVersion: String
    ) {
        self.id = id
        self.date = date
        self.kind = kind
        self.name = name
        self.reason = reason
        self.backtrace = backtrace
        self.appVersion = appVersion
        self.osVersion = osVersion
    }

    public var headline: String {
        switch kind {
        case .uncaughtException: "Exception: \(name)"
        case .signal: "Crash: \(name)"
        case .uncleanShutdown: "Unclean shutdown"
        }
    }

    public var formattedText: String {
        var lines = [
            "LumaWall crash report",
            "Date: \(date.formatted(.iso8601))",
            "Kind: \(headline)",
            "Reason: \(reason)",
            "App: \(appVersion) · macOS \(osVersion)",
        ]
        if !backtrace.isEmpty {
            lines.append("Backtrace:")
            lines.append(contentsOf: backtrace)
        }
        return lines.joined(separator: "\n")
    }
}

/// Local-only crash log store. Reports never leave the Mac; they are written to
/// Application Support and surfaced in Settings for the user to copy or clear.
public final class CrashReportStore: @unchecked Sendable {
    public static let maxReports = 20
    public static let maxDumpNameLength = 64
    public static let maxDumpBacktraceLines = 256

    public let directoryURL: URL
    private let sentinelURL: URL
    private let queue = DispatchQueue(label: "app.lumawall.crashreports")

    public init(rootURL: URL? = nil) throws {
        let base = try StorePaths.appSupportBase(rootURL: rootURL)
        directoryURL = base.appendingPathComponent("CrashReports", isDirectory: true)
        sentinelURL = directoryURL.appendingPathComponent("session.current")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    // MARK: - Session sentinel

    /// Marks the start of a session. If the previous session never ended
    /// cleanly (crash, force quit, kernel kill), returns the crash report a
    /// handler already captured for it, or records and returns a generic
    /// unclean-shutdown report.
    @discardableResult
    public func beginSession(
        appVersion: String,
        osVersion: String,
        now: Date = .now
    ) -> CrashReport? {
        var detected: CrashReport?
        queue.sync {
            if let data = try? Data(contentsOf: sentinelURL),
               let previousStart = try? JSONDecoder.lumaWall.decode(Date.self, from: data) {
                if let captured = unsafeReports().first(where: { $0.date >= previousStart }) {
                    detected = captured
                } else {
                    let report = CrashReport(
                        date: now,
                        kind: .uncleanShutdown,
                        name: "UNCLEAN_EXIT",
                        reason: "Previous session (started \(previousStart.formatted(.iso8601))) ended without a clean shutdown.",
                        appVersion: appVersion,
                        osVersion: osVersion
                    )
                    unsafeSave(report)
                    detected = report
                }
            }
            StoreIO.tryWriteJSON(now, to: sentinelURL)
        }
        return detected
    }

    public func endSessionCleanly() {
        queue.sync {
            try? FileManager.default.removeItem(at: sentinelURL)
        }
    }

    // MARK: - Reports

    public func save(_ report: CrashReport) {
        queue.sync { unsafeSave(report) }
    }

    public func reports() -> [CrashReport] {
        queue.sync { unsafeReports() }
    }

    public func clearAll() {
        queue.sync {
            for url in unsafeReportURLs() {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Converts raw signal-handler stack dumps (plain text, written with
    /// async-signal-safe calls at crash time) into structured reports.
    /// Dump format: line 1 signal name, line 2 unix timestamp, rest backtrace.
    /// Lengths are capped: a corrupt multi-megabyte dump must not inflate a
    /// persisted report or the Settings UI that renders it.
    public func ingestRawDumps(appVersion: String, osVersion: String) {
        queue.sync {
            let dumps = (try? FileManager.default.contentsOfDirectory(
                at: directoryURL, includingPropertiesForKeys: nil
            ))?.filter { $0.pathExtension == "stack" } ?? []
            for url in dumps {
                defer { try? FileManager.default.removeItem(at: url) }
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                guard lines.count >= 2 else { continue }
                let name = lines[0].isEmpty ? "SIGNAL" : String(lines[0].prefix(Self.maxDumpNameLength))
                let date = TimeInterval(lines[1]).map { Date(timeIntervalSince1970: $0) } ?? .now
                let report = CrashReport(
                    date: date,
                    kind: .signal,
                    name: name,
                    reason: "The app was terminated by \(name).",
                    backtrace: Array(lines.dropFirst(2).lazy.filter { !$0.isEmpty }.prefix(Self.maxDumpBacktraceLines)),
                    appVersion: appVersion,
                    osVersion: osVersion
                )
                unsafeSave(report)
            }
        }
    }

    // MARK: - Unsafe (must run on queue)

    private func unsafeSave(_ report: CrashReport) {
        let url = directoryURL.appendingPathComponent("\(report.id.uuidString).crash.json")
        StoreIO.tryWriteJSON(report, to: url)
        unsafePrune()
    }

    private func unsafeReports() -> [CrashReport] {
        unsafeReportURLs()
            .compactMap { url -> CrashReport? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder.lumaWall.decode(CrashReport.self, from: data)
            }
            .sorted { $0.date > $1.date }
    }

    private func unsafeReportURLs() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: directoryURL, includingPropertiesForKeys: nil
        ))?.filter { $0.lastPathComponent.hasSuffix(".crash.json") } ?? []
    }

    private func unsafePrune() {
        let sorted = unsafeReports()
        guard sorted.count > Self.maxReports else { return }
        for stale in sorted.dropFirst(Self.maxReports) {
            let url = directoryURL.appendingPathComponent("\(stale.id.uuidString).crash.json")
            try? FileManager.default.removeItem(at: url)
        }
    }
}
