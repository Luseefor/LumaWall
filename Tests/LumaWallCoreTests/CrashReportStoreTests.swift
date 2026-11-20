import Foundation
import LumaWallCore
import Testing

@Suite struct CrashReportStoreTests {
    private func makeStore() throws -> CrashReportStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumawall-crash-tests-\(UUID().uuidString)", isDirectory: true)
        return try CrashReportStore(rootURL: root)
    }

    @Test func saveAndLoadRoundTripsSortedByDate() throws {
        let store = try makeStore()
        let older = CrashReport(
            date: .now.addingTimeInterval(-100),
            kind: .signal, name: "SIGSEGV", reason: "old",
            appVersion: "1.0", osVersion: "26.0"
        )
        let newer = CrashReport(
            date: .now,
            kind: .uncaughtException, name: "NSRangeException", reason: "new",
            backtrace: ["frame 0", "frame 1"],
            appVersion: "1.0", osVersion: "26.0"
        )
        store.save(older)
        store.save(newer)

        let loaded = store.reports()
        #expect(loaded.count == 2)
        // ISO8601 persistence drops sub-second precision, so compare by id.
        #expect(loaded[0].id == newer.id)
        #expect(loaded[1].id == older.id)
        #expect(loaded[0].backtrace == ["frame 0", "frame 1"])
    }

    @Test func prunesToMaxReports() throws {
        let store = try makeStore()
        for index in 0..<(CrashReportStore.maxReports + 5) {
            store.save(
                CrashReport(
                    date: .now.addingTimeInterval(Double(index)),
                    kind: .signal, name: "SIGABRT", reason: "\(index)",
                    appVersion: "1.0", osVersion: "26.0"
                ))
        }
        #expect(store.reports().count == CrashReportStore.maxReports)
        // Newest reports survive the prune.
        #expect(store.reports().first?.reason == "\(CrashReportStore.maxReports + 4)")
    }

    @Test func cleanSessionsDetectNothing() throws {
        let store = try makeStore()
        #expect(store.beginSession(appVersion: "1.0", osVersion: "26.0") == nil)
        store.endSessionCleanly()
        #expect(store.beginSession(appVersion: "1.0", osVersion: "26.0") == nil)
    }

    @Test func staleSentinelProducesUncleanShutdownReport() throws {
        let store = try makeStore()
        store.beginSession(appVersion: "1.0", osVersion: "26.0")
        // No endSessionCleanly: simulates a crash or force quit.
        let detected = store.beginSession(appVersion: "1.0", osVersion: "26.0")
        #expect(detected?.kind == .uncleanShutdown)
        #expect(store.reports().contains { $0.kind == .uncleanShutdown })
    }

    @Test func capturedCrashSuppressesGenericUncleanReport() throws {
        let store = try makeStore()
        store.beginSession(appVersion: "1.0", osVersion: "26.0")
        let crash = CrashReport(
            kind: .uncaughtException, name: "NSGenericException", reason: "boom",
            appVersion: "1.0", osVersion: "26.0"
        )
        store.save(crash)
        let detected = store.beginSession(appVersion: "1.0", osVersion: "26.0")
        #expect(detected?.id == crash.id)
        #expect(!store.reports().contains { $0.kind == .uncleanShutdown })
    }

    @Test func ingestsRawSignalDumps() throws {
        let store = try makeStore()
        let dump = "SIGSEGV\n1700000000\n0  LumaWall  0x0000 frame0\n1  LumaWall  0x0001 frame1\n"
        try dump.write(
            to: store.directoryURL.appendingPathComponent("pending.stack"),
            atomically: true, encoding: .utf8
        )

        store.ingestRawDumps(appVersion: "1.0", osVersion: "26.0")

        let reports = store.reports()
        #expect(reports.count == 1)
        #expect(reports[0].kind == .signal)
        #expect(reports[0].name == "SIGSEGV")
        #expect(reports[0].date == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(reports[0].backtrace.count == 2)
        // Dump file is consumed.
        let remaining = try FileManager.default.contentsOfDirectory(
            at: store.directoryURL, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "stack" }
        #expect(remaining.isEmpty)
    }

    private func mode(of url: URL) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    @Test func diagnosticsAreReadableOnlyByTheUser() throws {
        // Crash reports carry backtraces and paths; they were created 0644
        // in a 0755 folder.
        let store = try makeStore()
        store.save(CrashReport(kind: .signal, name: "SIGSEGV", reason: "x", appVersion: "1", osVersion: "26"))
        _ = store.beginSession(appVersion: "1", osVersion: "26")
        #expect(try mode(of: store.directoryURL) == 0o700)
        let files = try FileManager.default.contentsOfDirectory(at: store.directoryURL, includingPropertiesForKeys: nil)
        #expect(files.count == 2)
        for file in files { #expect(try mode(of: file) == 0o600) }
    }

    @Test func aReportIsNeverWrittenThroughASymlink() throws {
        let store = try makeStore()
        let victim = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: victim) }
        try Data("keep".utf8).write(to: victim)
        try FileManager.default.createSymbolicLink(
            at: store.directoryURL.appendingPathComponent("session.current"), withDestinationURL: victim)
        _ = store.beginSession(appVersion: "1", osVersion: "26")
        #expect(try Data(contentsOf: victim) == Data("keep".utf8))
    }

    @Test func ingestDoesNotFollowASymlinkedDump() throws {
        // A pending.stack symlinked to another file copied that file into a
        // report shown in Settings.
        let store = try makeStore()
        let secret = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: secret) }
        try "SIGSEGV\n1700000000\nsecret-token\n".write(to: secret, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: store.directoryURL.appendingPathComponent("pending.stack"), withDestinationURL: secret)

        store.ingestRawDumps(appVersion: "1.0", osVersion: "26.0")
        #expect(store.reports().isEmpty)
        #expect(FileManager.default.fileExists(atPath: secret.path))
    }

    @Test func formattedTextCarriesKeyFields() {
        let report = CrashReport(
            kind: .signal, name: "SIGBUS", reason: "The app was terminated by SIGBUS.",
            backtrace: ["0 LumaWall frame"],
            appVersion: "0.4.0 (12)", osVersion: "26.1"
        )
        let text = report.formattedText
        #expect(text.contains("Crash: SIGBUS"))
        #expect(text.contains("0.4.0 (12)"))
        #expect(text.contains("0 LumaWall frame"))
    }

    @Test func clearAllDropsPersistedReports() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumawall-crash-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CrashReportStore(rootURL: root)
        store.save(CrashReport(kind: .signal, name: "SIGSEGV", reason: "x", appVersion: "1.0", osVersion: "26.0"))
        #expect(store.reports().count == 1)
        store.clearAll()
        #expect(store.reports().isEmpty)

        let reopened = try CrashReportStore(rootURL: root)
        #expect(reopened.reports().isEmpty)
    }

    @Test func ingestTruncatesOversizedDumpFields() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumawall-crash-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CrashReportStore(rootURL: root)
        let longName = String(repeating: "S", count: 500)
        let frames = (0..<300).map { "frame \($0)" }.joined(separator: "\n")
        let dump = "\(longName)\n1700000000\n\(frames)\n"
        try dump.write(
            to: store.directoryURL.appendingPathComponent("raw.stack"),
            atomically: true, encoding: .utf8
        )

        store.ingestRawDumps(appVersion: "1.0", osVersion: "26.0")
        let reports = store.reports()
        #expect(reports.count == 1)
        #expect(reports[0].name.count <= CrashReportStore.maxDumpNameLength)
        #expect(reports[0].backtrace.count <= CrashReportStore.maxDumpBacktraceLines)
        // The dump file is consumed either way.
        #expect(
            !FileManager.default.fileExists(
                atPath: store.directoryURL.appendingPathComponent("raw.stack").path
            ))
    }
}
