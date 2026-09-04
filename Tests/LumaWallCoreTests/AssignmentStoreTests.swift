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

    @Test
    func persistsTopologyAssignmentsAsOneSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AssignmentStore(rootURL: root)
        let wallpaper = WallpaperID()
        let assignments = (0..<8).map {
            DisplayAssignment(
                displayID: DisplayID(rawValue: "display-\($0)"),
                wallpaperID: wallpaper,
                composition: DisplayComposition(offset: CGPoint(x: CGFloat($0) * 10, y: 0))
            )
        }

        try await store.upsert(assignments)

        let reloaded = try AssignmentStore(rootURL: root)
        let snapshot = await reloaded.current()
        #expect(snapshot.assignments.count == 8)
        #expect(Set(snapshot.assignments.map(\.displayID)) == Set(assignments.map(\.displayID)))
    }

    @Test
    func migratesAssignmentsCreatedBeforeSpanningSupport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let snapshot = AssignmentSnapshot(assignments: [
            DisplayAssignment(
                displayID: DisplayID(rawValue: "legacy-display"),
                wallpaperID: WallpaperID(),
                composition: DisplayComposition(contentMode: .fit, scale: 1.2)
            )
        ])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var json = try #require(JSONSerialization.jsonObject(with: encoder.encode(snapshot)) as? [String: Any])
        var assignments = try #require(json["assignments"] as? [[String: Any]])
        var composition = try #require(assignments[0]["composition"] as? [String: Any])
        composition.removeValue(forKey: "spanningCanvas")
        assignments[0]["composition"] = composition
        json["assignments"] = assignments
        try JSONSerialization.data(withJSONObject: json).write(
            to: root.appendingPathComponent("Assignments.json"), options: .atomic
        )

        let store = try AssignmentStore(rootURL: root)
        let restored = await store.assignment(for: DisplayID(rawValue: "legacy-display"))
        #expect(restored?.composition.contentMode == .fit)
        #expect(restored?.composition.spanningCanvas == nil)
    }

    @Test
    func replaceAllSwapsSnapshotSorted() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AssignmentStore(rootURL: root)
        try await store.upsert(DisplayAssignment(displayID: DisplayID(rawValue: "old")))
        try await store.replaceAll(with: [
            DisplayAssignment(displayID: DisplayID(rawValue: "b")),
            DisplayAssignment(displayID: DisplayID(rawValue: "a")),
        ])

        let snapshot = await store.current()
        #expect(snapshot.assignments.map(\.displayID.rawValue) == ["a", "b"])
        #expect(await store.assignment(for: DisplayID(rawValue: "old")) == nil)
    }

    @Test
    func clearDropsSingleDisplayAndAll() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AssignmentStore(rootURL: root)
        try await store.upsert([
            DisplayAssignment(displayID: DisplayID(rawValue: "keep")),
            DisplayAssignment(displayID: DisplayID(rawValue: "drop")),
        ])
        try await store.clear(displayID: DisplayID(rawValue: "drop"))
        #expect(await store.assignment(for: DisplayID(rawValue: "drop")) == nil)
        #expect(await store.assignment(for: DisplayID(rawValue: "keep")) != nil)

        try await store.clearAll()
        #expect(await store.current().assignments.isEmpty)
    }
}
