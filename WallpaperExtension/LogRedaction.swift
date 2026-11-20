import Foundation

/// Strips account names from extension.log lines. Paths reach the log in
/// URLs, NSError descriptions and Mirror dumps, so every line is redacted
/// on its way to the file: `/Users/<name>` becomes `~`. `/Users/Shared`
/// names no account and is kept.
enum LogRedaction {
    static func redact(_ message: String) -> String {
        // Most lines have no path; those skip the regex. Built per call so
        // its Sendable status (which differs across SDKs) doesn't matter.
        guard message.contains("/Users/"),
            let homePath = try? NSRegularExpression(pattern: #"/Users/(?!Shared(?:/|\b))[^/\s"',;:\]\)]+"#)
        else { return message }
        let range = NSRange(message.startIndex..., in: message)
        return homePath.stringByReplacingMatches(in: message, range: range, withTemplate: "~")
    }
}
