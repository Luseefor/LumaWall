import Foundation
import os

/// Answers to the app's health ping (ADR 0003, `ExtensionHealth` in the
/// app). Each answer has this process's pid and a sequence that rises on
/// every answer, so the app can tell a new one from the last.
struct HealthAnswers {
    static let pingName = "app.lumawall.personal.healthPing"
    static let fileName = "lumawall-health.json"
    /// Any process can post the ping; a burst gets one answer a second.
    static let minimumSpacing: TimeInterval = 1

    private struct Answer: Encodable {
        var pid: Int32
        var sequence: UInt64
        var served: [UInt32]
    }

    let pid: Int32
    private var sequence: UInt64 = 0
    private var lastAnswerAt: TimeInterval?

    init(pid: Int32) {
        self.pid = pid
    }

    /// The file contents to write, or nil when the last answer was too recent.
    /// `now` is monotonic seconds.
    mutating func next(served: Set<UInt32>, at now: TimeInterval) -> Data? {
        if let lastAnswerAt, now - lastAnswerAt < Self.minimumSpacing { return nil }
        lastAnswerAt = now
        sequence += 1
        return try? JSONEncoder().encode(Answer(pid: pid, sequence: sequence, served: served.sorted()))
    }
}

/// Writes the answer for the displays `served` returns. Called from the
/// Darwin notification callback.
enum HealthReply {
    private static let answers = OSAllocatedUnfairLock(
        initialState: HealthAnswers(pid: ProcessInfo.processInfo.processIdentifier))

    static func answer(documents: URL, served: () -> Set<UInt32>) {
        let displays = served()
        let now = ProcessInfo.processInfo.systemUptime
        guard let data = answers.withLock({ $0.next(served: displays, at: now) }) else { return }
        // Atomic: replaces whatever is at the path, a symlink included.
        try? data.write(to: documents.appendingPathComponent(HealthAnswers.fileName), options: .atomic)
    }
}
