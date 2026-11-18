import Foundation

extension NativeWallpaperDeployment {
    /// Runs copy encodes one at a time at utility priority.
    ///
    /// Each time it picks a job it asks `readiness`: the ready job with the
    /// lowest rank runs next, held jobs wait for `wake()`, and dropped jobs
    /// are forgotten. A running 1440p export is cancelled and queued again
    /// when a battery copy becomes ready or the 1440p copy stops being
    /// wanted, since playback may be waiting on the battery copy.
    ///
    /// A copy that fails waits `firstRetryDelay`, doubling each time, and
    /// stops after `maxAttempts` tries for the session. Retries happen on the
    /// next request for the copy; nothing is scheduled.
    actor VariantEncodeQueue {
        struct Job: Sendable, Equatable {
            let entryID: String
            let sourceURL: URL
            /// Hash of the source this copy is made from; a redeploy with a
            /// different file makes the job stale.
            let contentHash: String
            let spec: VariantSpec
            var key: String { entryID + "/" + contentHash + "/" + spec.filename }
        }

        enum Readiness: Equatable, Sendable {
            /// Can run now; lower ranks run first.
            case ready(rank: Int)
            /// Wanted, but not under current conditions (power, for example).
            case hold
            /// Done, stale, or no longer wanted.
            case drop
        }

        enum Outcome: Sendable {
            case done, failed
            /// Stopped before finishing because conditions changed; waits for
            /// `wake()` without counting as a failure.
            case notNow
        }

        static let maxAttempts = 4
        static let firstRetryDelay: TimeInterval = 5 * 60

        private let readiness: @Sendable (Job) -> Readiness
        private let encode: @Sendable (Job) async -> Outcome
        private let now: @Sendable () -> Date
        private let prepare: @Sendable () -> Void
        private var prepared = false
        private var pending: [Job] = []
        /// Stopped with `.notNow`; back in `pending` on the next `wake()`.
        private var parked: [Job] = []
        private var running: (job: Job, task: Task<Outcome, Never>, preempted: Bool)?
        private var worker: Task<Void, Never>?
        private var failures: [String: (count: Int, retryAfter: Date)] = [:]

        init(
            readiness: @escaping @Sendable (Job) -> Readiness,
            encode: @escaping @Sendable (Job) async -> Outcome,
            now: @escaping @Sendable () -> Date = { Date() },
            prepare: @escaping @Sendable () -> Void = {}
        ) {
            self.readiness = readiness
            self.encode = encode
            self.now = now
            self.prepare = prepare
        }

        /// Runs `prepare` once, before any encode starts.
        func prepareIfNeeded() {
            guard !prepared else { return }
            prepared = true
            prepare()
        }

        func enqueue(_ jobs: [Job]) {
            prepareIfNeeded()
            for job in jobs where job.key != running?.job.key && !(pending + parked).contains(where: { $0.key == job.key }) {
                pending.append(job)
            }
            wake()
        }

        /// Re-evaluates waiting jobs and the running one. Call when power,
        /// tiers, or displays change.
        func wake() {
            pending += parked
            parked.removeAll()
            preemptIfNeeded()
            if worker == nil, !pending.isEmpty {
                worker = Task(priority: .utility) { await drain() }
            }
        }

        /// Returns once nothing is running. For tests.
        func drained() async {
            while let worker { await worker.value }
        }

        private func preemptIfNeeded() {
            guard let current = running, current.job.spec.forFullQuality, !current.preempted else { return }
            let stillWanted = if case .ready = readiness(current.job) { true } else { false }
            let batteryWaiting = pending.contains { job in
                guard !job.spec.forFullQuality, !isBackingOff(job) else { return false }
                if case .ready = readiness(job) { return true }
                return false
            }
            guard !stillWanted || batteryWaiting else { return }
            running?.preempted = true
            current.task.cancel()
        }

        private func isBackingOff(_ job: Job) -> Bool {
            guard let failure = failures[job.key] else { return false }
            return failure.count >= Self.maxAttempts || now() < failure.retryAfter
        }

        /// Removes and returns the best ready job, dropping stale ones and
        /// ones still backing off (the next request brings those back).
        private func next() -> Job? {
            var best: (index: Int, rank: Int)?
            var index = 0
            while index < pending.count {
                let job = pending[index]
                let state = isBackingOff(job) ? .drop : readiness(job)
                switch state {
                case .drop:
                    pending.remove(at: index)
                    continue
                case .hold:
                    break
                case .ready(let rank):
                    if best.map({ rank < $0.rank }) ?? true { best = (index, rank) }
                }
                index += 1
            }
            return best.map { pending.remove(at: $0.index) }
        }

        private func drain() async {
            while let job = next() {
                let encode = self.encode
                let task = Task(priority: .utility) { await encode(job) }
                running = (job, task, false)
                let outcome = await task.value
                let preempted = running?.preempted ?? false
                running = nil
                switch outcome {
                case .done:
                    failures[job.key] = nil
                case _ where preempted:
                    pending.insert(job, at: 0)
                case .notNow:
                    parked.append(job)
                case .failed:
                    let count = (failures[job.key]?.count ?? 0) + 1
                    let delay = Self.firstRetryDelay * pow(2, Double(count - 1))
                    failures[job.key] = (count, now().addingTimeInterval(delay))
                }
            }
            worker = nil
        }
    }
}
