import Foundation

/// Filesystem input validation for library entry IDs and filenames.
///
/// Pure `Foundation` logic shared via `LumaWallCore` so it is unit-testable.
/// The wallpaper extension carries an identical copy
/// (`WallpaperExtension/PathSafety.swift`) because an appex cannot import the
/// app's Core framework — keep the two in sync; `PathSafetyTests` pins this
/// side.
///
/// Threat model: entry IDs and filenames originate from `metadata.json` files
/// that live in a shared container. A corrupt or hand-edited file must never
/// steer a delete/copy (`removeItem`, `copyItem`) outside the library tree.
public enum PathSafety {
    /// True for well-formed UUID strings — the only form a library entry
    /// directory ever takes. Rejects `..`, absolute paths, and stray files.
    public static func isValidEntryID(_ id: String) -> Bool { UUID(uuidString: id) != nil }

    /// True for a safe single path component: a plain basename with no
    /// directory separators, no `.`/`..`, and no control characters.
    public static func isSafeComponent(_ name: String) -> Bool {
        if name.isEmpty || name == "." || name == ".." { return false }
        if name.contains("/") || name.contains("\\") { return false }
        if name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) { return false }
        return (name as NSString).lastPathComponent == name
    }

    /// Returns true only if `child`, after standardizing `..` and symlinks, is
    /// `base` itself or a descendant. Final gate before any filesystem
    /// mutation derived from untrusted metadata.
    public static func contained(_ child: URL, in base: URL) -> Bool {
        let basePath = base.standardizedFileURL.resolvingSymlinksInPath().path
        let childPath = child.standardizedFileURL.resolvingSymlinksInPath().path
        return childPath == basePath || childPath.hasPrefix(basePath + "/")
    }
}
