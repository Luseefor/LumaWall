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

        let decoded = StoreIO.readJSON(from: url, as: [String: String].self)

        #expect(decoded == ["key": "value"])
        // A fresh URL: resource values are cached per URL instance.
        let protection = try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.fileProtectionKey]).fileProtection
        #expect(protection == .completeUntilFirstUserAuthentication)
    }
}
