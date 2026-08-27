import Darwin
import Foundation
import LumaWallCore

/// Installs process-wide crash handlers. Uncaught exceptions are written as
/// structured reports immediately; fatal signals write a plain-text stack dump
/// with async-signal-safe calls, which `CrashReportStore.ingestRawDumps`
/// converts into a report on the next launch. Everything stays on disk —
/// LumaWall never uploads diagnostics.
enum CrashMonitor {
    private nonisolated(unsafe) static var store: CrashReportStore?
    private nonisolated(unsafe) static var appVersion = ""
    private nonisolated(unsafe) static var osVersion = ""
    private nonisolated(unsafe) static var dumpPath: [CChar] = []

    private static let fatalSignals: [Int32] = [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP]

    static func install(store: CrashReportStore, appVersion: String, osVersion: String) {
        self.store = store
        self.appVersion = appVersion
        self.osVersion = osVersion
        dumpPath = Array(
            store.directoryURL.appendingPathComponent("pending.stack").path.utf8CString
        )

        NSSetUncaughtExceptionHandler { exception in
            let report = CrashReport(
                kind: .uncaughtException,
                name: exception.name.rawValue,
                reason: exception.reason ?? "No reason provided.",
                backtrace: exception.callStackSymbols,
                appVersion: CrashMonitor.appVersion,
                osVersion: CrashMonitor.osVersion
            )
            CrashMonitor.store?.save(report)
        }

        for sig in fatalSignals {
            signal(sig, handleFatalSignal)
        }
    }

    static func markCleanShutdown() {
        store?.endSessionCleanly()
    }
}

/// Runs at crash time: only async-signal-safe calls (open/write/backtrace),
/// then restores the default action and re-raises so macOS still records the
/// standard .ips crash log.
private func handleFatalSignal(_ sig: Int32) {
    CrashMonitor.writeSignalDump(sig)
    signal(sig, SIG_DFL)
    raise(sig)
}

extension CrashMonitor {
    fileprivate static func writeSignalDump(_ sig: Int32) {
        guard !dumpPath.isEmpty else { return }
        let fd = open(dumpPath, O_CREAT | O_WRONLY | O_TRUNC, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }

        writeLine(fd, signalName(sig))
        writeLine(fd, unsignedString(UInt(time(nil))))

        var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 64)
        let count = backtrace(&frames, Int32(frames.count))
        if count > 0 {
            backtrace_symbols_fd(&frames, count, fd)
        }
    }

    private static func writeLine(_ fd: Int32, _ text: StaticString) {
        text.withUTF8Buffer { buffer in
            _ = write(fd, buffer.baseAddress, buffer.count)
        }
        var newline: UInt8 = 0x0A
        _ = write(fd, &newline, 1)
    }

    private static func writeLine(_ fd: Int32, _ bytes: [UInt8]) {
        _ = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
        var newline: UInt8 = 0x0A
        _ = write(fd, &newline, 1)
    }

    private static func signalName(_ sig: Int32) -> StaticString {
        switch sig {
        case SIGABRT: "SIGABRT"
        case SIGSEGV: "SIGSEGV"
        case SIGBUS: "SIGBUS"
        case SIGILL: "SIGILL"
        case SIGFPE: "SIGFPE"
        case SIGTRAP: "SIGTRAP"
        default: "SIGNAL"
        }
    }

    /// Integer-to-ASCII without allocation (Swift string interpolation is not
    /// async-signal-safe).
    private static func unsignedString(_ value: UInt) -> [UInt8] {
        guard value > 0 else { return [0x30] }
        var digits: [UInt8] = []
        var rest = value
        while rest > 0 {
            digits.append(UInt8(0x30 + rest % 10))
            rest /= 10
        }
        return digits.reversed()
    }
}
