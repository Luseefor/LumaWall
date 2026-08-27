import Foundation
import os

/// Runs every native shuffle surface, including custom playlists. State is kept
/// per choice identifier so separate displays can rotate different playlists at
/// different frequencies without sharing a decoder choice or timer.
final class ShuffleController: @unchecked Sendable {
    static let shared = ShuffleController()

    private let queue = DispatchQueue(label: "app.lumawall.personal.shuffle")
    private let lock = OSAllocatedUnfairLock(initialState: State())
    private var timers: [String: any DispatchSourceTimer] = [:]

    private struct ChoiceState: Sendable {
        var active = false
        var pick: String?
        var previousPick: String?
        var frequency: ShuffleFrequencyID = .onWakeup
        var lastAdvance: Date?
        var pendingAdvance = false
        var advancedThisLaunch = false
    }

    private struct State: Sendable {
        var choices: [String: ChoiceState] = [:]
    }

    private enum Keys {
        static let picks = "shufflePicksByChoice"
        static let lastAdvances = "shuffleLastAdvancesByChoice"
    }

    private init() {
        let defaults = UserDefaults.standard
        let picks = defaults.dictionary(forKey: Keys.picks) as? [String: String] ?? [:]
        let timestamps = defaults.dictionary(forKey: Keys.lastAdvances) as? [String: Double] ?? [:]
        lock.withLock { state in
            for (choiceID, pick) in picks {
                var choice = ChoiceState()
                choice.pick = pick
                choice.lastAdvance = timestamps[choiceID].map(Date.init(timeIntervalSince1970:))
                state.choices[choiceID] = choice
            }
        }
    }

    var isActive: Bool {
        lock.withLock { $0.choices.values.contains(where: \.active) }
    }

    func resolveChoice(_ choice: String?) -> String? {
        guard let choice, ExtensionPlaylistLibrary.isShuffleChoice(choice) else { return choice }
        return currentOrNewPick(for: choice)
    }

    func noteAcquire(choice: String?, frequencyID: String?) {
        guard let choice, ExtensionPlaylistLibrary.isShuffleChoice(choice) else {
            queue.asyncAfter(deadline: .now() + 1.0) { [self] in syncActiveWithContexts() }
            return
        }

        let frequency = frequencyID.flatMap(ShuffleFrequencyID.init(rawValue:))
        let (becameActive, frequencyChanged) = lock.withLock { state -> (Bool, Bool) in
            var item = state.choices[choice] ?? ChoiceState()
            let wasActive = item.active
            let oldFrequency = item.frequency
            item.active = true
            if let frequency { item.frequency = frequency }
            state.choices[choice] = item
            return (!wasActive, item.frequency != oldFrequency)
        }

        if becameActive || frequencyChanged {
            armTimerIfNeeded(for: choice)
            extensionLog("[Shuffle] active choice=\(choice), frequency=\(frequencyForChoice(choice).rawValue)")
        }

        let advanceForLogin = lock.withLock { state -> Bool in
            guard var item = state.choices[choice],
                  item.frequency == .onLogin,
                  !item.advancedThisLaunch
            else { return false }
            item.advancedThisLaunch = true
            state.choices[choice] = item
            return true
        }
        if advanceForLogin {
            queue.async { [self] in advance(choiceID: choice, reason: "login") }
        }
    }

    /// The current XPC update callback supplies a frequency but not the choice id.
    /// Apply it to every active shuffle surface; an acquire for each surface will
    /// subsequently reassert its own stored option value.
    func noteFrequencyChange(_ frequencyID: String?) {
        guard let frequency = frequencyID.flatMap(ShuffleFrequencyID.init(rawValue:)) else { return }
        let activeChoices = lock.withLock { state -> [String] in
            var changed: [String] = []
            for (id, var item) in state.choices where item.active {
                if item.frequency != frequency {
                    item.frequency = frequency
                    state.choices[id] = item
                    changed.append(id)
                }
            }
            return changed
        }
        for choice in activeChoices { armTimerIfNeeded(for: choice) }
    }

    func syncActiveWithContexts() {
        let knownChoices = lock.withLock { Array($0.choices.keys) }
        let stopped = lock.withLock { state -> [String] in
            var result: [String] = []
            for id in knownChoices {
                guard var item = state.choices[id] else { continue }
                let stillActive = WallpaperState.shared.hasContext(forVideoID: id)
                if item.active, !stillActive { result.append(id) }
                item.active = stillActive
                state.choices[id] = item
            }
            return result
        }
        for choice in stopped {
            queue.async { [self] in stopTimer(for: choice) }
            extensionLog("[Shuffle] deactivated choice=\(choice)")
        }
    }

    func noteWake() {
        let choicesToAdvance = lock.withLock { state -> [(String, String)] in
            var result: [(String, String)] = []
            for (id, item) in state.choices where item.active {
                switch item.frequency {
                case .onWakeup:
                    result.append((id, "wake"))
                case .onLogin:
                    break
                default:
                    if item.pendingAdvance {
                        result.append((id, "pending tick"))
                    } else if let interval = item.frequency.interval,
                              let last = item.lastAdvance,
                              Date().timeIntervalSince(last) > interval {
                        result.append((id, "elapsed during sleep"))
                    }
                }
            }
            return result
        }
        for (choice, reason) in choicesToAdvance {
            queue.async { [self] in advance(choiceID: choice, reason: reason) }
        }
    }

    func skip() -> Bool {
        let activeChoices = lock.withLock {
            $0.choices.filter { $0.value.active }.map(\.key)
        }
        guard !activeChoices.isEmpty else { return false }
        for choice in activeChoices {
            queue.async { [self] in advance(choiceID: choice, reason: "skip") }
        }
        return true
    }

    func previous() -> Bool {
        let choices = lock.withLock {
            $0.choices.compactMap { id, item in item.active && item.previousPick != nil ? id : nil }
        }
        guard !choices.isEmpty else { return false }
        for choice in choices { queue.async { [self] in restorePrevious(choiceID: choice) } }
        return true
    }

    private func currentOrNewPick(for choiceID: String) -> String? {
        let available = ExtensionPlaylistLibrary.videoIDs(forChoiceID: choiceID)
        guard !available.isEmpty else { return nil }
        if let existing = lock.withLock({ $0.choices[choiceID]?.pick }), available.contains(existing) {
            return existing
        }
        let fresh = available[0]
        setPick(fresh, for: choiceID)
        return fresh
    }

    private func setPick(_ pick: String, for choiceID: String) {
        lock.withLock { state in
            var item = state.choices[choiceID] ?? ChoiceState()
            item.pick = pick
            item.lastAdvance = Date()
            item.pendingAdvance = false
            state.choices[choiceID] = item
        }
        persistState()
    }

    private func persistState() {
        let values = lock.withLock { state -> ([String: String], [String: Double]) in
            var picks: [String: String] = [:]
            var timestamps: [String: Double] = [:]
            for (id, item) in state.choices {
                if let pick = item.pick { picks[id] = pick }
                if let last = item.lastAdvance { timestamps[id] = last.timeIntervalSince1970 }
            }
            return (picks, timestamps)
        }
        UserDefaults.standard.set(values.0, forKey: Keys.picks)
        UserDefaults.standard.set(values.1, forKey: Keys.lastAdvances)
    }

    private func frequencyForChoice(_ choiceID: String) -> ShuffleFrequencyID {
        lock.withLock { $0.choices[choiceID]?.frequency ?? .onWakeup }
    }

    private func armTimerIfNeeded(for choiceID: String) {
        queue.async { [self] in
            stopTimer(for: choiceID)
            guard let interval = frequencyForChoice(choiceID).interval else { return }
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now() + interval, repeating: interval)
            source.setEventHandler { [weak self] in self?.tick(choiceID: choiceID) }
            timers[choiceID] = source
            source.resume()
        }
    }

    private func stopTimer(for choiceID: String) {
        timers.removeValue(forKey: choiceID)?.cancel()
    }

    private func tick(choiceID: String) {
        guard lock.withLock({ $0.choices[choiceID]?.active ?? false }) else { return }
        if WallpaperState.shared.isDisplayAsleep {
            lock.withLock { state in
                guard var item = state.choices[choiceID] else { return }
                item.pendingAdvance = true
                state.choices[choiceID] = item
            }
            return
        }
        advance(choiceID: choiceID, reason: "timer")
    }

    private func advance(choiceID: String, reason: String) {
        let available = ExtensionPlaylistLibrary.videoIDs(forChoiceID: choiceID)
        guard available.count >= 2 else { return }
        let current = lock.withLock { $0.choices[choiceID]?.pick }
        let ordered = ExtensionPlaylistLibrary.playlist(forChoiceID: choiceID)?.shuffle == false

        let next: String
        if ordered {
            let index = current.flatMap { available.firstIndex(of: $0) } ?? -1
            next = available[(index + 1) % available.count]
        } else {
            var candidate = available.randomElement() ?? available[0]
            if candidate == current {
                let index = available.firstIndex(of: candidate) ?? 0
                candidate = available[(index + 1) % available.count]
            }
            next = candidate
        }

        guard let url = VideoLibrary.shared.videoURL(for: next) else { return }
        lock.withLock { state in
            var item = state.choices[choiceID] ?? ChoiceState()
            item.previousPick = item.pick
            state.choices[choiceID] = item
        }
        setPick(next, for: choiceID)

        let renderers = WallpaperState.shared.renderers(forVideoID: choiceID)
        for renderer in renderers {
            renderer.variantSelector = makeVariantSelector(choice: next, fallback: url)
            renderer.switchVideo(to: url)
        }
        LumaWallExtension.recomputeAndApplyPolicy()
        WallpaperState.shared.currentVideoID = next
        WallpaperPrefs.shared.updateCurrentVideo()
        extensionLog("[Shuffle] advanced choice=\(choiceID) to \(next) on \(renderers.count) renderer(s) (\(reason))")
    }

    private func restorePrevious(choiceID: String) {
        let pair = lock.withLock { state -> (String, String?)? in
            guard var item = state.choices[choiceID], let previous = item.previousPick else { return nil }
            let current = item.pick
            item.pick = previous
            item.previousPick = current
            item.lastAdvance = Date()
            state.choices[choiceID] = item
            return (previous, current)
        }
        guard let pair, let url = VideoLibrary.shared.videoURL(for: pair.0) else { return }
        persistState()
        let renderers = WallpaperState.shared.renderers(forVideoID: choiceID)
        for renderer in renderers {
            renderer.variantSelector = makeVariantSelector(choice: pair.0, fallback: url)
            renderer.switchVideo(to: url)
        }
        LumaWallExtension.recomputeAndApplyPolicy()
        WallpaperState.shared.currentVideoID = pair.0
        WallpaperPrefs.shared.updateCurrentVideo()
        extensionLog("[Shuffle] restored previous choice=\(choiceID) to \(pair.0)")
    }
}
