import Foundation
import UserNotifications

/// Plan NH §4 — the notification a refusal posts when the app is not in front (Siri, the Watch,
/// CarPlay, a shortcut, the widget, a Live Activity button, a locked phone). A tap opens the
/// subscription sheet. Nothing waits on it: the line has already been said or returned, and a
/// notification that did not appear must not hold anything up — the same rule as the cloud-sharing
/// consent gate.
enum AllowanceNotification {

    /// One identifier, so a second refusal replaces the first rather than stacking.
    static let identifier = "avenkin.daily-allowance"
    /// The `userInfo` key that says "open the subscription sheet".
    static let openKey = "og_open_subscription"

    static var title: String { String(localized: "Today's free minutes are used") }
    static var body: String {
        String(localized: "Tap to see Standard, with no daily limit. The free minutes come back at midnight.")
    }

    /// Whether a tapped notification asks for the subscription sheet. Pure, for the router.
    static func opensSubscription(_ userInfo: [AnyHashable: Any]) -> Bool {
        userInfo[openKey] as? Bool == true
    }

    /// Post it if notifications are allowed. Never asks for permission: a refusal is not the moment
    /// to put a system prompt in front of someone.
    @MainActor
    static func post(center: UNUserNotificationCenter = .current()) {
        Task { @MainActor in
            let settings = await center.notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: break
            default: return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.userInfo = [openKey: true]
            try? await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
        }
    }
}
