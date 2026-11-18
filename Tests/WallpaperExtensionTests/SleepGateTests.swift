import XCTest

/// Display sleep is a hard gate: while the displays sleep, no policy update
/// (power, prefs, or an agent update) may restart decoding (issue #10).
final class SleepGateTests: XCTestCase {
    func testPolicyUpdateDuringSleepStaysPaused() {
        // Sleep paused the renderer; then the user unplugs power and the new
        // tier arrives while the displays are still asleep.
        for tier in [PlaybackPolicy.full, .reduced, .minimal] {
            for animated in [false, true] {
                let step = PlaybackPolicy.transition(from: .paused, to: tier, animated: animated, displayAsleep: true)
                XCTAssertEqual(step.policy, .paused, "\(tier) animated=\(animated)")
                XCTAssertEqual(step.action, .none, "\(tier) animated=\(animated)")
            }
        }
    }

    func testPlayingRendererPausesAtOnceWhenAsleep() {
        // A renderer that missed the sleep pause is stopped by the next update,
        // without a ramp: a ramp keeps decoding for seconds in the dark.
        let step = PlaybackPolicy.transition(from: .full, to: .full, animated: true, displayAsleep: true)
        XCTAssertEqual(step.policy, .paused)
        XCTAssertEqual(step.action, .pause)
    }

    func testWakeResumesTheRequestedTier() {
        XCTAssertEqual(
            PlaybackPolicy.transition(from: .paused, to: .reduced, animated: false, displayAsleep: false),
            .init(policy: .reduced, action: .resume),
        )
        XCTAssertEqual(
            PlaybackPolicy.transition(from: .paused, to: .full, animated: true, displayAsleep: false),
            .init(policy: .full, action: .rampUp),
        )
    }

    func testAwakeTransitionsAreUnchanged() {
        XCTAssertEqual(
            PlaybackPolicy.transition(from: .full, to: .paused, animated: true, displayAsleep: false),
            .init(policy: .paused, action: .rampDown),
        )
        XCTAssertEqual(
            PlaybackPolicy.transition(from: .full, to: .paused, animated: false, displayAsleep: false),
            .init(policy: .paused, action: .pause),
        )
        XCTAssertEqual(
            PlaybackPolicy.transition(from: .full, to: .full, animated: false, displayAsleep: false),
            .init(policy: .full, action: .none),
        )
    }
}
