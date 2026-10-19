import Foundation
import notify

@MainActor
final class GameModeMonitor {
    /// gamepolicyd state-carrying Darwin notification name. The extension host
    /// historically used `com.apple.gamepolicy.game-mode-session`; keep both
    /// registered so a wrong guess on either side fails open instead of
    /// silently never pausing for Game Mode.
    private static let names = [
        "com.apple.gamepolicy.currentGameplayState",
        "com.apple.gamepolicy.game-mode-session",
    ]
    private var tokens: [Int32] = []
    private(set) var isActive = false
    var onChange: (() -> Void)?

    func start() {
        guard tokens.isEmpty else { return }
        for name in Self.names {
            var registered = NOTIFY_TOKEN_INVALID
            // notify_register_dispatch invokes the block off-actor. Hop back to
            // MainActor before touching isActive/onChange (Swift 6 race otherwise).
            let status = notify_register_dispatch(name, &registered, DispatchQueue.main) { [weak self] token in
                Task { @MainActor in self?.update(token: token) }
            }
            guard status == NOTIFY_STATUS_OK else { continue }
            tokens.append(registered)
            update(token: registered)
        }
    }

    /// Cancel the notify registrations. Call on teardown; also guards `deinit`.
    func stop() {
        for token in tokens {
            notify_cancel(token)
        }
        tokens.removeAll()
    }

    deinit {
        for token in tokens {
            notify_cancel(token)
        }
    }

    private func update(token: Int32) {
        var state: UInt64 = 0
        notify_get_state(token, &state)
        let active = state != 0
        guard active != isActive else { return }
        isActive = active
        onChange?()
    }
}
