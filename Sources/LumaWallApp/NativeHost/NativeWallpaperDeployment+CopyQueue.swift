import Foundation

extension NativeWallpaperDeployment {
    /// Runs copy encodes one at a time at utility priority.
    ///
    /// Each time it picks a job it asks `readiness`: the ready job with the
    /// lowest rank runs next, held jobs wait for `wake()`, and dropped jobs
    /// are forgotten. A running 1440p export is cancelled and queued again
    /// when a better-ranked job is waiting or the 1440p copy stops being
    /// ready, since playback may be waiting on the other copy.
    ///
    /// A copy that fails waits `firstRetryDelay`, doubling each time, and
    /// stops after `maxAttempts` tries for the session. Retries happen on the
    /// next request for the copy; nothing is scheduled.
    ///
    /// Jobs that share a source run from one private copy of it.
    /// `finishedSource` is called with the last job run for a source once
    /// no ready job for that source waits and the queue picks another
    /// source's job, or once the queue stops, however that job ended. A
    /// source another one interrupts keeps its copy for its remaining jobs.
    actor VariantEncodeQueue {
        struct Job: Sendable, Equatable {
            let entryID: String
            let sourceURL: URL
            /// Hash of the source this copy is made from; a redeploy with a
            /// different file makes the job stale.
            let contentHash: String
            let spec: VariantSpec
            var key: String { sourceKey + "/" + spec.filename }
            /// Same for every copy made from one deployed source.
            var sourceKey: String { entryID + "/" + contentHash }
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
        private let finishedSource: @Sendable (Job) -> Void
        /// The last job run for each source `finishedSource` hasn't been
        /// called for yet, oldest first.
        private var liveSources: [Job] = []
        private var prepared = false
        private var pending: [Job] = []
        /// Stopped with `.notNow`; back in `pending` on the next `wake()`.
        private var parked: [Job] = []
        private var running: (job: Job, task: Task<Outcome, Never>, preempted: Bool, removed: Bool)?
        private var worker: Task<Void, Never>?
        /// Counts `wake()` calls, so a job that stops with `.notNow` after a
        /// wake arrived mid-attempt is checked again instead of parked.
        private var wakes = 0
        private var failures: [String: (count: Int, retryAfter: Date)] = [:]
        private var removedEntries: Set<String> = []

        init(
            readiness: @escaping @Sendable (Job) -> Readiness,
            encode: @escaping @Sendable (Job) async -> Outcome,
            now: @escaping @Sendable () -> Date = { Date() },
            prepare: @escaping @Sendable () -> Void = {},
            finishedSource: @escaping @Sendable (Job) -> Void = { _ in }
        ) {
            self.readiness = readiness
            self.encode = encode
            self.now = now
            self.prepare = prepare
            self.finishedSource = finishedSource
        }

        /// Runs `prepare` once, before any encode starts.
        func prepareIfNeeded() {
            guard !prepared else { return }
            prepared = true
            prepare()
        }

        func enqueue(_ jobs: [Job]) {
            prepareIfNeeded()
            for job in jobs
            where !removedEntries.contains(job.entryID) && job.key != running?.job.key
                && !(pending + parked).contains(where: { $0.key == job.key })
            {
                pending.append(job)
            }
            wake()
        }

        /// Re-evaluates waiting jobs and the running one. Call when power,
        /// tiers, or displays change.
        func wake() {
            wakes += 1
            pending += parked
            parked.removeAll()
            preemptIfNeeded()
            if worker == nil, !pending.isEmpty {
                worker = Task(priority: .utility) { await drain() }
            }
        }

        /// Forgets every job for `entryID`, cancels its running encode,
        /// whatever kind, without queueing it again, and refuses its later
        /// jobs. For a removed wallpaper.
        func cancel(entryID: String) {
            // Entry IDs are UUIDs and never come back, so late enqueues from
            // a deploy that raced the removal are refused for the session.
            removedEntries.insert(entryID)
            pending.removeAll { $0.entryID == entryID }
            parked.removeAll { $0.entryID == entryID }
            if running?.job.entryID == entryID {
                running?.removed = true
                running?.task.cancel()
            }
        }

        /// Whether the running job has been cancelled for another. For tests.
        var runningJobWasPreempted: Bool { running?.preempted ?? false }

        /// Returns once nothing is running. For tests.
        func drained() async {
            while let worker { await worker.value }
        }

        /// Cancels a running job that was dropped (native mode turned off, or
        /// its wallpaper went away), and a running 1440p export that is no
        /// longer ready or that a waiting job outranks. Other battery encodes
        /// finish: they are short next to a 4K export and redoing one wastes
        /// more than it saves.
        private func preemptIfNeeded() {
            guard let current = running, !current.preempted else { return }
            if case .drop = readiness(current.job) {
                cancelRunning()
                return
            }
            guard current.job.spec.forFullQuality else { return }
            guard case .ready(let rank) = readiness(current.job) else {
                cancelRunning()
                return
            }
            let outranked = pending.contains { job in
                guard !isBackingOff(job), case .ready(let other) = readiness(job) else { return false }
                return other < rank
            }
            if outranked { cancelRunning() }
        }

        private func cancelRunning() {
            running?.preempted = true
            running?.task.cancel()
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
                releaseSources(except: job.sourceKey)
                liveSources.removeAll { $0.sourceKey == job.sourceKey }
                liveSources.append(job)
                let encode = self.encode
                let task = Task(priority: .utility) { await encode(job) }
                let wakesAtStart = wakes
                running = (job, task, false, false)
                let outcome = await task.value
                let preempted = running?.preempted ?? false
                let removed = running?.removed ?? false
                running = nil
                if removed { continue }
                switch outcome {
                case .done:
                    failures[job.key] = nil
                case _ where preempted, .notNow where wakes != wakesAtStart:
                    pending.insert(job, at: 0)
                case .notNow:
                    parked.append(job)
                case .failed:
                    let count = (failures[job.key]?.count ?? 0) + 1
                    let delay = Self.firstRetryDelay * pow(2, Double(count - 1))
                    failures[job.key] = (count, now().addingTimeInterval(delay))
                }
            }
            for job in liveSources { finishedSource(job) }
            liveSources.removeAll()
            worker = nil
        }

        /// Calls `finishedSource` for every live source other than `kept`
        /// with no job waiting that could run now. A held or backing-off job
        /// doesn't keep a source: it may wait for hours.
        private func releaseSources(except kept: String) {
            liveSources.removeAll { last in
                guard last.sourceKey != kept else { return false }
                let waiting = pending.contains { job in
                    guard job.sourceKey == last.sourceKey, !isBackingOff(job), case .ready = readiness(job) else { return false }
                    return true
                }
                if !waiting { finishedSource(last) }
                return !waiting
            }
        }
    }
}
