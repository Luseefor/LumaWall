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
        let composition = DisplayComposition(
            contentMode: .fit,
            focalPoint: CGPoint(x: 0.25, y: 0.75),
            scale: 1.35,
            rotationDegrees: 12,
            offset: CGPoint(x: -48, y: 24)
        )
        try await store.upsert(
            DisplayAssignment(displayID: display, wallpaperID: wallpaper, composition: composition)
        )
        let reloaded = try AssignmentStore(rootURL: root)
        #expect(await reloaded.assignment(for: display)?.wallpaperID == wallpaper)
        #expect(await reloaded.assignment(for: display)?.composition == composition)
    }
}
