import Foundation
import XCTest

@testable import LumaWall

/// WallpaperAgent rewrites its store for a second or so after a display
/// wakes or joins. A restore that lost to it three times in a row moved
/// every display to Safe mode, though waiting would have worked.
@MainActor
final class NativeStoreContentionTests: XCTestCase {
    private typealias Engine = NativeWallpaperEngine
    private typealias AssignmentError = NativeWallpaperAssignmentService.AssignmentError

    func testAStoreThatKeepsChangingIsRetriedAfterAWait() async throws {
        var attempts = 0
        var slept: [Duration] = []
        let result = try await Engine.retryingContention(
            delays: [.seconds(1), .seconds(2), .seconds(4)],
            sleep: { slept.append($0) },
            shouldStop: { false }
        ) {
            attempts += 1
            if attempts < 3 { throw AssignmentError.verificationFailed }
            return "assigned"
        }
        XCTAssertEqual(result, "assigned")
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(slept, [.seconds(1), .seconds(2)])
    }

    func testItGivesUpAfterTheLastWait() async {
        var attempts = 0
        do {
            _ = try await Engine.retryingContention(delays: [.seconds(1)], sleep: { _ in }, shouldStop: { false }) {
                attempts += 1
                throw AssignmentError.verificationFailed
            }
            XCTFail("expected the contention to be reported")
        } catch AssignmentError.verificationFailed {
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(attempts, 2)
    }

    func testOtherFailuresAreNotRetried() async {
        var attempts = 0
        do {
            _ = try await Engine.retryingContention(delays: [.seconds(1)], sleep: { _ in }, shouldStop: { false }) {
                attempts += 1
                throw AssignmentError.unreadableStore
            }
            XCTFail("expected the failure to be reported")
        } catch {}
        XCTAssertEqual(attempts, 1)
    }

    func testNativeModeTurningOffDuringAWaitStopsTheRetry() async {
        var attempts = 0
        var stopped = false
        do {
            _ = try await Engine.retryingContention(
                delays: [.seconds(1)], sleep: { _ in stopped = true }, shouldStop: { stopped }
            ) {
                attempts += 1
                throw AssignmentError.verificationFailed
            }
            XCTFail("expected the retry to stop")
        } catch is CancellationError {
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(attempts, 1)
    }
}
