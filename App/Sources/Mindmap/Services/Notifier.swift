import Foundation
import UserNotifications

/// macOS notifications for the updater. A click on an "update ready" one asks whether to install it.
/// Only an installed app posts them: `UNUserNotificationCenter` needs a bundle (not `swift run`).
final class Notifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = Notifier()
    private static let updateCategory = "update"
    /// What a click on an update notification does (set once, at launch).
    private var onInstall: (@MainActor () -> Void)?

    @MainActor
    func start(onInstall: @escaping @MainActor () -> Void) {
        guard Updater.canUpdate else { return }
        self.onInstall = onInstall
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String, update: Bool = false) {
        guard Updater.canUpdate else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if update { content.categoryIdentifier = updateCategory }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // Shown even while the app is in front (a menu bar app nearly always is, once its menu is open).
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.notification.request.content.categoryIdentifier == Self.updateCategory,
           response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            DispatchQueue.main.async { MainActor.assumeIsolated { self.onInstall?() } }
        }
        completionHandler()
    }
}
