import AppKit
import UserNotifications

/// Posts the macOS notification when native mode fails on a display, with
/// a Restore Original Wallpaper action. Permission is asked the first time
/// there is something to say, not at launch.
@MainActor
final class NativeFailureNotifier: NSObject {
    nonisolated static let categoryID = "app.lumawall.native-failure"
    nonisolated static let restoreActionID = "app.lumawall.restore-original"

    var onRestore: (() -> Void)?
    var onOpen: (() -> Void)?

    /// Sets the delegate early, so an action picked while the app was not
    /// running reaches it after launch.
    func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let restore = UNNotificationAction(
            identifier: Self.restoreActionID, title: "Restore Original Wallpaper", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.categoryID, actions: [restore], intentIdentifiers: [])
        ])
    }

    func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = Self.categoryID
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        Task {
            let center = UNUserNotificationCenter.current()
            do {
                guard try await center.requestAuthorization(options: [.alert]) else { return }
                try await center.add(request)
            } catch {
                nativeHostLog.notice("notification not posted: \(LogRedaction.code(of: error), privacy: .public)")
            }
        }
    }
}

extension NativeFailureNotifier: UNUserNotificationCenterDelegate {
    /// The in-app banner shows too; the notification still appears so it
    /// isn't missed when the window is closed.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let action = response.actionIdentifier
        guard response.notification.request.content.categoryIdentifier == Self.categoryID else { return }
        await MainActor.run {
            switch action {
            case Self.restoreActionID: onRestore?()
            case UNNotificationDefaultActionIdentifier:
                NSApp.activate(ignoringOtherApps: true)
                onOpen?()
            default: break
            }
        }
    }
}
