import Foundation
import LumaWallCore
import Testing

struct AsyncDeadlineTests {
    @Test func returnsAtTheDeadlineWhenTheOperationIsSlow() async {
        let started = ContinuousClock.now
        await awaitWithDeadline(.milliseconds(100)) {
            try? await Task.sleep(for: .seconds(5))
        }
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    @Test func returnsWhenTheOperationFinishesFirst() async {
        let started = ContinuousClock.now
        let finished = FinishedFlag()
        await awaitWithDeadline(.seconds(5)) { finished.set() }
        #expect(finished.value)
        #expect(ContinuousClock.now - started < .seconds(2))
    }
}

private final class FinishedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}
