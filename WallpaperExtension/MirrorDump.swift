import CryptoKit
import Foundation

/// The lines `dumpMirror` writes for an XPC payload: each value's type and
/// field labels, with only values that can't name a file or a person.
/// A URL or path becomes `…/<last component's hash>` plus a media
/// extension, or keeps an entry ID and the app's file names inside an
/// entry; other text becomes a hash unless it's an entry ID. An object with
/// no reflected fields, or a case with its own description, shows only its
/// type. A custom mirror's labels are replaced by positions.
enum MirrorDump {
    static func lines(_ value: Any, label: String = "root", depth: Int = 3) -> [String] {
        let head = "[\(label)] \(typeName(value))"
        if let leaf = leaf(value) { return [leaf.isEmpty ? head : "\(head) = \(leaf)"] }
        return [head] + children(of: value, depth: depth, indent: 1)
    }

    /// A value with nothing to recurse into, as the dump shows it; empty
    /// when only its type is shown. Nil for a value with fields.
    static func leaf(_ value: Any) -> String? {
        if let url = value as? URL { return urlLabel(url) }
        if let string = value as? String { return stringLabel(string) }
        if let string = value as? any StringProtocol { return stringLabel(String(string)) }
        if let data = value as? Data { return "<\(data.count) bytes>" }
        if let flag = value as? Bool { return String(flag) }
        if let number = value as? any BinaryInteger { return "\(number)" }
        if let number = value as? any BinaryFloatingPoint { return "\(number)" }
        let mirror = Mirror(reflecting: value)
        guard mirror.children.isEmpty else { return nil }
        switch mirror.displayStyle {
        case .optional: return "nil"
        case .enum: return caseLabel(value)
        default: return ""
        }
    }

    private static func children(of value: Any, depth: Int, indent: Int) -> [String] {
        let pad = String(repeating: "  ", count: indent)
        guard depth > 0 else { return ["\(pad)…"] }
        // Field names from the runtime are code; a custom mirror's could be
        // anything, a file name included.
        let custom = value is any CustomReflectable
        var lines: [String] = []
        for (index, child) in Mirror(reflecting: value).children.enumerated() {
            let label = custom ? "#\(index)" : (child.label ?? "#\(index)")
            let head = "\(pad).\(label): \(typeName(child.value))"
            if let leaf = leaf(child.value) {
                lines.append(leaf.isEmpty ? head : "\(head) = \(leaf)")
            } else {
                lines.append(head)
                lines += children(of: child.value, depth: depth - 1, indent: indent + 1)
            }
        }
        return lines
    }

    private static func typeName(_ value: Any) -> String {
        String(describing: type(of: value))
    }

    private static func urlLabel(_ url: URL) -> String {
        guard url.isFileURL else { return "<URL #\(hash(url.absoluteString))>" }
        let name = url.lastPathComponent
        guard !name.isEmpty, name != "/" else { return "/" }
        if UUID(uuidString: name) != nil { return "…/\(name)" }
        let entry = url.deletingLastPathComponent().lastPathComponent
        if LogRedaction.appFileNames.contains(name), UUID(uuidString: entry) != nil { return "…/\(entry)/\(name)" }
        let ext = url.pathExtension.lowercased()
        return "…/#\(hash(name))" + (mediaExtensions.contains(ext) ? ".\(ext)" : "")
    }

    /// Extensions a library or wallpaper file normally has. Any other
    /// extension is part of a name the user chose.
    private static let mediaExtensions: Set = [
        "mov", "mp4", "m4v", "heic", "heif", "jpg", "jpeg", "png", "tif", "tiff", "gif", "json", "plist",
    ]

    /// Entry IDs as they are, a path or URL as `urlLabel`, anything else
    /// as a hash: a file can be named like an ID or a bundle identifier.
    private static func stringLabel(_ string: String) -> String {
        if UUID(uuidString: string) != nil { return string }
        if string.hasPrefix("/") || string.hasPrefix("~") { return urlLabel(URL(fileURLWithPath: string)) }
        if string.contains("://"), let url = URL(string: string) { return urlLabel(url) }
        return "<text #\(hash(string))>"
    }

    /// A payload-less case by the name the runtime prints. A type with its
    /// own description could print anything, so it shows only its type.
    private static func caseLabel(_ value: Any) -> String {
        guard !(value is any CustomStringConvertible), !(value is any CustomDebugStringConvertible) else { return "" }
        let name = String(describing: value)
        return name.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil ? name : ""
    }

    /// The first 8 hex digits of the SHA-256, so equal names match across lines.
    private static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }
}
