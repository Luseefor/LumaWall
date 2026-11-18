import Foundation

/// Runs `operation` and returns when it finishes or `timeout` passes, whichever
/// comes first. An operation that is still running keeps going in the
/// background; this only stops waiting for it. Meant for work that must not hold
/// up app termination.
public func awaitWithDeadline(
    _ timeout: Duration,
    _ operation: @escaping @Sendable () async -> Void
) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        let pending = NSLock()
        nonisolated(unsafe) var waiting: CheckedContinuation<Void, Never>? = continuation
        let finish: @Sendable () -> Void = {
            pending.lock()
            let next = waiting
            waiting = nil
            pending.unlock()
            next?.resume()
        }
        Task {
            await operation()
            finish()
        }
        Task {
            try? await Task.sleep(for: timeout)
            finish()
        }
    }
}
