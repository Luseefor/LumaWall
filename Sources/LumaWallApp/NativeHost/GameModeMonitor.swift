import Foundation
import notify

@MainActor
final class GameModeMonitor {
    private static let name = "com.apple.gamepolicy.currentGameplayState"
    private var token = NOTIFY_TOKEN_INVALID
    private(set) var isActive = false
    var onChange: (() -> Void)?

    func start() {
        guard token == NOTIFY_TOKEN_INVALID else { return }
        var registered = NOTIFY_TOKEN_INVALID
        let status = notify_register_dispatch(Self.name, &registered, DispatchQueue.main) { [weak self] token in
            self?.update(token: token)
        }
        guard status == NOTIFY_STATUS_OK else { return }
        token = registered
        update(token: registered)
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
