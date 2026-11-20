import Foundation

/// Keeps account names, home paths and user-chosen file names out of
/// extension.log. Paths reach the log in URLs, NSError descriptions and
/// Mirror dumps, so `extensionLog` redacts every line: a home directory
/// becomes `~`. Call sites log entry IDs, app-named basenames
/// (`fileLabel`) and error codes (`describe`) instead of titles and paths.
enum LogRedaction {
    /// The account's real home (the sandbox's `NSHomeDirectory` is the
    /// container), for homes outside /Users.
    static let accountHome: String? = getpwuid(getuid()).flatMap { $0.pointee.pw_dir.map { String(cString: $0) } }

    private static let stop = #"/\s"',;:\]\)"#
    private static let patterns = [
        // /Users/<name>, but not the exact /Users/Shared folder.
        #"/Users/(?!Shared(?=$|[\#(stop)]))[^\#(stop)]+"#,
        // The same, percent-encoded.
        #"(?i)%2FUsers%2F(?!Shared(?=$|%2F))[^%\#(stop)]+"#,
        // ~name/ (another account's home); leaves ~/ alone.
        #"~[A-Za-z_][A-Za-z0-9_.-]*(?=/)"#,
    ]

    static func redact(_ message: String) -> String {
        redact(message, home: accountHome)
    }

    static func redact(_ message: String, home: String?) -> String {
        var result = message
        if let home, home.count > 1, !home.hasPrefix("/Users/") {
            // The home as written, URL-path encoded and fully encoded, each
            // only as a whole path component (not /x/alice-backup).
            let forms = [
                home, home.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                home.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
            ]
            for form in Set(forms.compactMap { $0 }) {
                let pattern = "(?i)" + NSRegularExpression.escapedPattern(for: form) + #"(?=$|[\#(stop)]|%2F)"#
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "~")
            }
        }
        // Most lines have none of these; they skip the regexes. Each is
        // built per call so its Sendable status (which differs across SDKs)
        // doesn't matter.
        guard result.contains("Users") || result.contains("~") || result.localizedCaseInsensitiveContains("%2FUsers") else {
            return result
        }
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "~")
        }
        return result
    }

    /// A library file as the log names it: the app's own names
    /// (`Wallpaper.mp4`, `Wallpaper.qhd.mov`, ...) as they are, anything
    /// else as `<entry ID>/video.<ext>`, since a recovered or added file
    /// keeps whatever name the user gave it.
    static func fileLabel(_ url: URL) -> String {
        let name = url.lastPathComponent
        if appFileNames.contains(name) { return name }
        let ext = url.pathExtension.lowercased()
        let generic = ext.isEmpty ? "file" : "video.\(ext)"
        let entry = url.deletingLastPathComponent().lastPathComponent
        return UUID(uuidString: entry) != nil ? "\(entry)/\(generic)" : generic
    }

    /// The names the app gives library files: the imported original
    /// (MediaImporter) and its tier copies.
    static let appFileNames = Set(
        ["Wallpaper.mov", "Wallpaper.mp4", "Wallpaper.m4v"] + ["qhd", "reduced", "minimal", "battery"].map { "Wallpaper.\($0).mov" })

    /// An error as the log records it: domain and code. Descriptions and
    /// userInfo carry file paths and names.
    static func describe(_ error: any Error) -> String {
        let error = error as NSError
        return "\(error.domain) \(error.code)"
    }
}
