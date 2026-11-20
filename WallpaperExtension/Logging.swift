import Foundation

/// The extension's log: Documents/extension.log, rotated at 1 MB with two
/// older copies kept.
private let logFile: LogFile = {
    let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return LogFile(url: dir.appendingPathComponent("extension.log"), maxSize: 1_024 * 1_024, rotatedCopies: 2)
}()

/// Cached formatter, `ISO8601DateFormatter` is thread-safe with immutable config.
/// `nonisolated(unsafe)` because ISO8601DateFormatter doesn't conform to Sendable,
/// but it's effectively immutable after initialization (no properties are mutated).
private nonisolated(unsafe) let logDateFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]  // millisecond precision for timing
    return f
}()

/// Recursively dump an object's Mirror for debugging XPC types.
func dumpMirror(_ obj: Any, label: String = "root", depth: Int = 3, indent: Int = 0) {
    let prefix = String(repeating: "  ", count: indent)
    let mirror = Mirror(reflecting: obj)
    extensionLog("\(prefix)[\(label)] type=\(type(of: obj)) children=\(mirror.children.count)")
    guard depth > 0 else { return }
    for child in mirror.children {
        let childLabel = child.label ?? "?"
        let childValue = child.value
        let desc = String(describing: childValue).prefix(200)
        extensionLog("\(prefix)  .\(childLabel) = \(desc)")
        // Recurse into non-primitive types
        let childMirror = Mirror(reflecting: childValue)
        if childMirror.children.count > 0, !(childValue is String), !(childValue is Data), !(childValue is URL) {
            dumpMirror(childValue, label: childLabel, depth: depth - 1, indent: indent + 2)
        }
    }
}

/// When true, high-volume per-switch/per-frame diagnostics (`traceLog`) are written too.
/// OFF by default so normal logs stay focused on switches, state changes, and errors.
/// Enable for deep debugging by creating a `VERBOSE_LOG` marker file in the container
/// Documents dir and relaunching (`killall WallpaperAgent`). Evaluated once at launch.
let verboseLoggingEnabled: Bool = {
    let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/VERBOSE_LOG")
    return FileManager.default.fileExists(atPath: url.path)
}()

/// Trace-level log, only written when `verboseLoggingEnabled`. Use for the noisy internal
/// diagnostics (renderer restart steps, feed ticks, per-connection churn, snapshots). The
/// `@autoclosure` means the string isn't even built when tracing is off.
func traceLog(_ message: @autoclosure () -> String) {
    guard verboseLoggingEnabled else { return }
    extensionLog(message())
}

func extensionLog(_ message: String) {
    logFile.append("[\(logDateFormatter.string(from: Date()))] \(message)\n")
}
