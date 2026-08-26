import Foundation

public struct AssignmentSnapshot: Codable, Equatable, Sendable {
    public var assignments: [DisplayAssignment]
    public var updatedAt: Date

    public init(assignments: [DisplayAssignment] = [], updatedAt: Date = .now) {
        self.assignments = assignments
        self.updatedAt = updatedAt
    }
}

public actor AssignmentStore {
    private let fileURL: URL
    private var snapshot: AssignmentSnapshot

    public init(rootURL: URL? = nil) throws {
        let base = rootURL ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("LumaWall", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.fileURL = base.appendingPathComponent("Assignments.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder.lumaWall.decode(AssignmentSnapshot.self, from: data) {
            snapshot = decoded
        } else {
            snapshot = AssignmentSnapshot()
        }
    }

    public func current() -> AssignmentSnapshot { snapshot }

    public func assignment(for displayID: DisplayID) -> DisplayAssignment? {
        snapshot.assignments.first { $0.displayID == displayID }
    }

    public func upsert(_ assignment: DisplayAssignment) throws {
        if let index = snapshot.assignments.firstIndex(where: { $0.displayID == assignment.displayID }) {
            snapshot.assignments[index] = assignment
        } else {
            snapshot.assignments.append(assignment)
        }
        snapshot.updatedAt = .now
        try persist()
    }

    public func clear(displayID: DisplayID) throws {
        snapshot.assignments.removeAll { $0.displayID == displayID }
        snapshot.updatedAt = .now
        try persist()
    }

    public func clearAll() throws {
        snapshot.assignments.removeAll()
        snapshot.updatedAt = .now
        try persist()
    }

    private func persist() throws {
        let data = try JSONEncoder.lumaWall.encode(snapshot)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUnlessOpen])
    }
}
