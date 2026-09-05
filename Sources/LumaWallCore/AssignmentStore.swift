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
        let base = try StorePaths.appSupportBase(rootURL: rootURL)
        self.fileURL = base.appendingPathComponent("Assignments.json")
        if let decoded: AssignmentSnapshot = StoreIO.readJSON(from: fileURL, as: AssignmentSnapshot.self) {
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
        try upsert([assignment])
    }

    public func upsert(_ assignments: [DisplayAssignment]) throws {
        guard !assignments.isEmpty else { return }
        var values = Dictionary(uniqueKeysWithValues: snapshot.assignments.map { ($0.displayID, $0) })
        for assignment in assignments {
            values[assignment.displayID] = assignment
        }
        snapshot.assignments = values.values.sorted { $0.displayID.rawValue < $1.displayID.rawValue }
        snapshot.updatedAt = .now
        try persist()
    }

    public func replaceAll(with assignments: [DisplayAssignment]) throws {
        snapshot.assignments = assignments.sorted { $0.displayID.rawValue < $1.displayID.rawValue }
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
        try StoreIO.writeJSON(snapshot, to: fileURL)
    }
}
