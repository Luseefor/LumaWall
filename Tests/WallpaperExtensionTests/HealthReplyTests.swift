import XCTest

/// The answer to the app's health ping (ADR 0003).
final class HealthReplyTests: XCTestCase {
    func testAnswersCarryARisingSequence() throws {
        var answers = HealthAnswers(pid: 42)
        let first = try XCTUnwrap(answers.next(served: [2, 1], at: 0))
        let second = try XCTUnwrap(answers.next(served: [1], at: 5))
        let decoded = try JSONSerialization.jsonObject(with: first) as? [String: Any]
        XCTAssertEqual(decoded?["pid"] as? Int, 42)
        XCTAssertEqual(decoded?["sequence"] as? Int, 1)
        XCTAssertEqual(decoded?["served"] as? [Int], [1, 2])
        let next = try JSONSerialization.jsonObject(with: second) as? [String: Any]
        XCTAssertEqual(next?["sequence"] as? Int, 2)
    }

    func testABurstOfPingsGetsOneAnswerASecond() {
        // Any process can post the ping.
        var answers = HealthAnswers(pid: 1)
        XCTAssertNotNil(answers.next(served: [], at: 10))
        XCTAssertNil(answers.next(served: [], at: 10.5))
        XCTAssertNotNil(answers.next(served: [], at: 11))
    }
}
