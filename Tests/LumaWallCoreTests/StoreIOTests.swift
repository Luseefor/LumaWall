import Foundation
import LumaWallCore
import Testing

struct StoreIOTests {
    /// Stores are read while the screen is locked (schedules, lock-screen
    /// playback). The "unless open" class makes an existing file unreadable
    /// once the Mac locks, so loads came back empty; files must stay readable
    /// after the first unlock since boot.
    @Test func storeFilesStayReadableWhileTheScreenIsLocked() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("store.json")

        try StoreIO.writeJSON(["key": "value"], to: url)

        // A fresh URL: resource values are cached per URL instance.
        let protection = try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.fileProtectionKey]).fileProtection
        #expect(protection == .completeUntilFirstUserAuthentication)
    }

    /// Files written by older builds keep the old class until rewritten,
    /// and some stores rarely change; a successful read upgrades them.
    @Test func readingAnOlderStoreFileUpgradesItsProtection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("store.json")
        try Data(#"{"key":"value"}"#.utf8).write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        // A locked Mac refuses to open an "unless open" file at all, so the
        // upgrade can only be exercised while unlocked.
        guard (try? Data(contentsOf: url)) != nil else { return }

        let decoded = StoreIO.readJSON(from: url, as: [String: String].self)

        #expect(decoded == ["key": "value"])
        // A fresh URL: resource values are cached per URL instance.
        let protection = try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.fileProtectionKey]).fileProtection
        #expect(protection == .completeUntilFirstUserAuthentication)
    }

    /// A store that exists but can't be read (protected while locked, or
    /// unreadable) must never be replaced: callers would have loaded it as
    /// empty, and saving would erase the real data.
    @Test func writeRefusesToReplaceAStoreItCannotRead() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            _ = chmod(root.appendingPathComponent("store.json").path, 0o600)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("store.json")
        try StoreIO.writeJSON(["library": "full"], to: url)
        #expect(chmod(url.path, 0o000) == 0)

        #expect(throws: (any Error).self) { try StoreIO.writeJSON(["library": "empty"], to: url) }

        #expect(chmod(url.path, 0o600) == 0)
        #expect(StoreIO.readJSON(from: url, as: [String: String].self) == ["library": "full"])
    }
}
