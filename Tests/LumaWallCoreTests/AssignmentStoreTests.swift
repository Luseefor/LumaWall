import Foundation
import Testing
@testable import LumaWallCore

@Suite
struct AssignmentStoreTests {
    @Test
    func persistsAssignmentsPerDisplay() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AssignmentStore(rootURL: root)
        let display = DisplayID(rawValue: "display-a")
        let wallpaper = WallpaperID()
        try await store.upsert(DisplayAssignment(displayID: display, wallpaperID: wallpaper))
        let reloaded = try AssignmentStore(rootURL: root)
        #expect(await reloaded.assignment(for: display)?.wallpaperID == wallpaper)
    }
}
