import Foundation

extension NativeWallpaperDeployment {
    /// Runs copy encodes one at a time at utility priority. Battery copies go
    /// ahead of queued 1440p copies, since a battery tier may be waiting to
    /// play them. Before each 1440p export it checks power again, and a copy
    /// that fails waits `firstRetryDelay`, doubling, and stops after
    /// `maxAttempts` tries for the session. Retries happen on the next request
    /// (apply, restore, tier switch); nothing is scheduled.
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

        static let maxAttempts = 4
        static let firstRetryDelay: TimeInterval = 5 * 60

        private let canMakeOptionalCopies: @Sendable () -> Bool
        private let isDone: @Sendable (Job) -> Bool
        private let encode: @Sendable (Job) async -> Bool
        private let now: @Sendable () -> Date
        private let prepare: @Sendable () -> Void
        private var prepared = false
        private var pending: [Job] = []
        private var runningKey: String?
        private var worker: Task<Void, Never>?
        private var failures: [String: (count: Int, retryAfter: Date)] = [:]

        init(
            canMakeOptionalCopies: @escaping @Sendable () -> Bool,
            isDone: @escaping @Sendable (Job) -> Bool,
            encode: @escaping @Sendable (Job) async -> Bool,
            now: @escaping @Sendable () -> Date = { Date() },
            prepare: @escaping @Sendable () -> Void = {}
        ) {
            self.canMakeOptionalCopies = canMakeOptionalCopies
            self.isDone = isDone
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
            let ordered = jobs.filter { !$0.spec.forFullQuality } + jobs.filter(\.spec.forFullQuality)
            for job in ordered where job.key != runningKey && !pending.contains(where: { $0.key == job.key }) {
                if job.spec.forFullQuality {
                    pending.append(job)
                } else {
                    pending.insert(job, at: pending.firstIndex { $0.spec.forFullQuality } ?? pending.endIndex)
                }
            }
            if worker == nil, !pending.isEmpty {
                worker = Task(priority: .utility) { await drain() }
            }
        }

        /// Returns once the queue is empty. For tests.
        func drained() async {
            while let worker { await worker.value }
        }

        private func drain() async {
            while !pending.isEmpty {
                let job = pending.removeFirst()
                guard shouldRun(job) else { continue }
                runningKey = job.key
                let succeeded = await encode(job)
                runningKey = nil
                if succeeded {
                    failures[job.key] = nil
                } else {
                    let count = (failures[job.key]?.count ?? 0) + 1
                    let delay = Self.firstRetryDelay * pow(2, Double(count - 1))
                    failures[job.key] = (count, now().addingTimeInterval(delay))
                }
            }
            worker = nil
        }

        private func shouldRun(_ job: Job) -> Bool {
            if job.spec.forFullQuality, !canMakeOptionalCopies() { return false }
            if let failure = failures[job.key], failure.count >= Self.maxAttempts || now() < failure.retryAfter {
                return false
            }
            return !isDone(job)
        }
    }
}
