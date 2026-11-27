import AppKit
import UserNotifications

/// Posts the macOS notification when native mode fails on a display, with
/// a Restore Original Wallpaper action. Permission is asked while native
/// mode is on and the app is in use: a failure often comes right after an
/// unlock or wake, when macOS refused the prompt and the notice was lost.
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

    /// Whether to ask for notification permission now.
    nonisolated static func asksForPermission(nativeModeOn: Bool, status: UNAuthorizationStatus) -> Bool {
        nativeModeOn && status == .notDetermined
    }

    /// Asks for permission if `nativeModeOn` still holds and nobody has
    /// answered. It's checked again after reading the settings, so turning
    /// native mode off meanwhile cancels the prompt.
    func askForPermissionIfNeeded(nativeModeOn: @escaping @MainActor () -> Bool) {
        guard nativeModeOn() else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            let status = await center.notificationSettings().authorizationStatus
            guard Self.asksForPermission(nativeModeOn: nativeModeOn(), status: status) else { return }
            do {
                let granted = try await center.requestAuthorization(options: [.alert])
                nativeHostLog.info("notification permission \(granted ? "granted" : "declined", privacy: .public)")
            } catch {
                nativeHostLog.notice("notification permission not asked: \(LogRedaction.code(of: error), privacy: .public)")
            }
        }
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
                // Asking is left to `askForPermissionIfNeeded`, which waits
                // for the native-mode warning to be answered.
                let status = await center.notificationSettings().authorizationStatus
                guard status == .authorized || status == .provisional else { return }
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
