import Foundation
import LumaWallCore
import Testing

struct ExtensionHealthTests {
    private let awake = ExtensionHealth.Conditions(
        nativeActive: true, sessionLocked: false, displaysAsleep: false, screenSaverRunning: false)

    private func reply(_ sequence: UInt64, serving served: Set<UInt32>, pid: Int32 = 100) -> ExtensionHealth.Reply {
        .init(pid: pid, sequence: sequence, served: served)
    }

    /// A monitor past its launch grace that has heard the extension once.
    private func settled(watching displays: Set<UInt32> = [1, 2]) -> ExtensionHealth {
        var health = ExtensionHealth(now: 0)
        health.probeSent(at: ExtensionHealth.grace, previous: nil)
        #expect(health.probeFinished(reply: reply(1, serving: displays), watching: displays, at: settledAt).isEmpty)
        return health
    }

    /// When `settled()` heard its first reply.
    private let settledAt = ExtensionHealth.grace + 3

    @Test func probesOnlyWhenSomeoneCanSeeANativeDesktop() {
        #expect(awake.allowsProbing)
        var conditions = awake
        conditions.sessionLocked = true
        #expect(!conditions.allowsProbing)
        conditions = awake
        conditions.displaysAsleep = true
        #expect(!conditions.allowsProbing)
        conditions = awake
        conditions.screenSaverRunning = true
        #expect(!conditions.allowsProbing)
        conditions = awake
        conditions.nativeActive = false
        #expect(!conditions.allowsProbing)
    }

    @Test func waitsOutTheGraceAfterLaunchAndDisturbances() {
        var health = ExtensionHealth(now: 0)
        #expect(!health.canProbe(awake, at: ExtensionHealth.grace - 1))
        #expect(health.canProbe(awake, at: ExtensionHealth.grace))
        health.disturb(at: 100)
        #expect(!health.canProbe(awake, at: 100 + ExtensionHealth.grace - 1))
        #expect(health.canProbe(awake, at: 100 + ExtensionHealth.grace))
    }

    @Test func fallsBackADisplayMissingForTheTimeout() {
        var health = settled()
        var now = settledAt
        var sent = now + ExtensionHealth.healthyInterval
        health.probeSent(at: sent, previous: reply(1, serving: [1, 2]))
        #expect(health.probeFinished(reply: reply(2, serving: [1]), watching: [1, 2], at: sent + 3).isEmpty)
        #expect(health.missingSince[2] == sent)
        let firstMiss = sent
        // Suspect displays are probed sooner.
        #expect(health.nextProbeDelay == ExtensionHealth.suspectInterval)
        var seq: UInt64 = 2
        var fellBack: Set<UInt32> = []
        while fellBack.isEmpty {
            now = sent + 3
            sent = now + health.nextProbeDelay
            health.probeSent(at: sent, previous: reply(seq, serving: [1]))
            seq += 1
            fellBack = health.probeFinished(reply: reply(seq, serving: [1]), watching: [1, 2], at: sent + 3)
            #expect(sent + 3 - firstMiss < ExtensionHealth.timeout + ExtensionHealth.suspectInterval + 3)
        }
        #expect(fellBack == [2])
        #expect(sent + 3 - firstMiss >= ExtensionHealth.timeout)
        // Reported once: the display isn't tracked any more.
        #expect(health.missingSince[2] == nil)
    }

    @Test func aDisplayServedAgainIsForgiven() {
        var health = settled()
        let now = settledAt
        health.probeSent(at: now + 10, previous: reply(1, serving: [1, 2]))
        _ = health.probeFinished(reply: reply(2, serving: [1]), watching: [1, 2], at: now + 13)
        health.probeSent(at: now + 17, previous: reply(2, serving: [1]))
        #expect(health.probeFinished(reply: reply(3, serving: [1, 2]), watching: [1, 2], at: now + 20).isEmpty)
        #expect(health.missingSince.isEmpty)
        #expect(health.nextProbeDelay == ExtensionHealth.healthyInterval)
    }

    @Test func noFreshReplyCountsAsMissingOnceTheExtensionAnswered() {
        var health = settled()
        var now = settledAt
        let stale = reply(1, serving: [1, 2])
        var fellBack: Set<UInt32> = []
        for _ in 0..<10 where fellBack.isEmpty {
            now += 5
            health.probeSent(at: now, previous: stale)
            // The file still holds the last answer: the extension is gone.
            fellBack = health.probeFinished(reply: stale, watching: [1, 2], at: now + 3)
            now += 3
        }
        #expect(fellBack == [1, 2])
    }

    @Test func anExtensionThatNeverAnsweredIsNotBlamed() {
        // An older extension, still running after an update, has no reply.
        var health = ExtensionHealth(now: 0)
        var now = ExtensionHealth.grace
        for _ in 0..<20 {
            health.probeSent(at: now, previous: nil)
            #expect(health.probeFinished(reply: nil, watching: [1], at: now + 3).isEmpty)
            now += 10
        }
    }

    @Test func silenceCountsFromTheStartWhenThisBuildAnsweredBefore() {
        // The extension never starts after launch.
        var health = ExtensionHealth(now: 0, heardBefore: true)
        var now = ExtensionHealth.grace
        var fellBack: Set<UInt32> = []
        for _ in 0..<10 where fellBack.isEmpty {
            health.probeSent(at: now, previous: nil)
            fellBack = health.probeFinished(reply: nil, watching: [1], at: now + 3)
            now += 7
        }
        #expect(fellBack == [1])
    }

    @Test func aRelaunchedExtensionCountsAsFresh() {
        var health = settled(watching: [1])
        let now = settledAt
        health.probeSent(at: now + 10, previous: reply(9, serving: [1]))
        // New process, sequence restarted.
        let relaunched = reply(1, serving: [1], pid: 200)
        #expect(health.probeFinished(reply: relaunched, watching: [1], at: now + 13).isEmpty)
        #expect(health.missingSince.isEmpty)
    }

    @Test func aDisturbanceCancelsTheProbeInFlightAndResetsMisses() {
        var health = settled()
        let now = settledAt
        health.probeSent(at: now + 10, previous: reply(1, serving: [1, 2]))
        _ = health.probeFinished(reply: reply(2, serving: [1]), watching: [1, 2], at: now + 13)
        #expect(!health.missingSince.isEmpty)
        health.probeSent(at: now + 17, previous: reply(2, serving: [1]))
        // A Space switch lands before the reply is read.
        health.disturb(at: now + 18)
        #expect(health.probeFinished(reply: reply(3, serving: []), watching: [1, 2], at: now + 20).isEmpty)
        #expect(health.missingSince.isEmpty)
        #expect(!health.canProbe(awake, at: now + 20))
    }

    @Test func displaysNoLongerWatchedAreDropped() {
        var health = settled()
        let now = settledAt
        health.probeSent(at: now + 10, previous: reply(1, serving: [1, 2]))
        _ = health.probeFinished(reply: reply(2, serving: [1]), watching: [1, 2], at: now + 13)
        // Display 2 went to sleep or was disconnected.
        health.probeSent(at: now + 17, previous: reply(2, serving: [1]))
        #expect(health.probeFinished(reply: reply(3, serving: [1]), watching: [1], at: now + 20).isEmpty)
        #expect(health.missingSince.isEmpty)
    }

    @Test func aFinishWithoutAProbeChangesNothing() {
        var health = settled()
        let now = settledAt
        #expect(health.probeFinished(reply: reply(5, serving: []), watching: [1, 2], at: now + 1).isEmpty)
        #expect(health.missingSince.isEmpty)
    }

    @Test func decodesTheExtensionsReplyFile() throws {
        let data = Data(#"{"pid":42,"sequence":7,"served":[3,1]}"#.utf8)
        #expect(ExtensionHealth.Reply.decode(data) == reply(7, serving: [1, 3], pid: 42))
        #expect(ExtensionHealth.Reply.decode(Data("nope".utf8)) == nil)
        // The extension can write its container: an oversized file is ignored.
        #expect(ExtensionHealth.Reply.decode(Data(count: ExtensionHealth.Reply.maxFileSize + 1)) == nil)
    }
}
