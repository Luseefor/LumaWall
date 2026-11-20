import CryptoKit
import Foundation

/// The lines `dumpMirror` writes for an XPC payload: each value's type and
/// field labels, with only values that can't name a file or a person.
/// A URL or path becomes `…/<last component's hash>.<ext>`, or keeps an
/// entry ID and the app's own file names; other text becomes a hash. An
/// object with no reflected fields shows only its type, since its
/// description could hold anything.
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
        if let data = value as? Data { return "<\(data.count) bytes>" }
        if let flag = value as? Bool { return String(flag) }
        if let number = value as? any BinaryInteger { return "\(number)" }
        if let number = value as? any BinaryFloatingPoint { return "\(number)" }
        let mirror = Mirror(reflecting: value)
        guard mirror.children.isEmpty else { return nil }
        switch mirror.displayStyle {
        case .optional: return "nil"
        case .enum: return caseLabel(String(describing: value))
        default: return ""
        }
    }

    private static func children(of value: Any, depth: Int, indent: Int) -> [String] {
        let pad = String(repeating: "  ", count: indent)
        guard depth > 0 else { return ["\(pad)…"] }
        var lines: [String] = []
        for child in Mirror(reflecting: value).children {
            let head = "\(pad).\(child.label ?? "?"): \(typeName(child.value))"
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
        guard url.isFileURL else { return "<\(url.scheme ?? "?") URL #\(hash(url.absoluteString))>" }
        let name = url.lastPathComponent
        guard !name.isEmpty, name != "/" else { return "/" }
        if UUID(uuidString: name) != nil { return "…/\(name)" }
        if LogRedaction.appFileNames.contains(name) {
            let entry = url.deletingLastPathComponent().lastPathComponent
            return UUID(uuidString: entry) != nil ? "…/\(entry)/\(name)" : "…/\(name)"
        }
        let ext = url.pathExtension.lowercased()
        let keepsExt = !ext.isEmpty && ext.count <= 5 && ext.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return "…/#\(hash(name))" + (keepsExt ? ".\(ext)" : "")
    }

    /// Entry IDs and Apple's or LumaWall's reverse-DNS IDs as they are; a
    /// path or URL as `urlLabel`; anything else as a hash.
    private static func stringLabel(_ string: String) -> String {
        if UUID(uuidString: string) != nil { return string }
        if string.hasPrefix("/") || string.hasPrefix("~") { return urlLabel(URL(fileURLWithPath: string)) }
        if string.contains("://"), let url = URL(string: string) { return urlLabel(url) }
        if string.range(of: #"^(com\.apple|app\.lumawall)(\.[A-Za-z0-9-]+)+$"#, options: .regularExpression) != nil {
            return string
        }
        return "<text #\(hash(string))>"
    }

    /// A payload-less case prints its name, unless a custom description
    /// says something else.
    private static func caseLabel(_ description: String) -> String {
        description.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil
            ? description : "<case #\(hash(description))>"
    }

    /// The first 8 hex digits of the SHA-256, so equal names match across lines.
    private static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }
}
