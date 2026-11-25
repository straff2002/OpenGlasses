import Foundation
import UserNotifications

/// How the actions held while the wearer was away reach them when they come back: a quiet
/// notification, never speech.
///
/// Field report (b770): the held line was spoken through the phone speaker. "Back" is read from
/// motion and the wake word as well as the open app, so it fired with the phone locked on the
/// table beside the wearer, in meetings. The phone's own mic then heard the line, took it as a
/// request and asked to run the held Shortcut. A notification can't be overheard and can't be
/// heard back as a request.
///
/// One notification, replacing itself, so a long stretch away is one line. Passive and silent: a
/// held action waits for the wearer and is never urgent. With the app open it is still shown as a
/// banner (see `JobSendNotificationRouter.presentation(identifier:)`), and a tap opens the
/// assistant.
enum HeldRecommendationNotification {

    static let identifier = "presence.held-while-away"

    static var title: String {
        String(localized: "Held while you were away",
               comment: "Notification title: actions the assistant held, not run, while the user was away.")
    }

    /// The notification's content: the drained summary line as the body.
    static func content(body: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = nil
        content.interruptionLevel = .passive
        content.userInfo = [JobSendNotifications.openTabKey: MainTab.voice.rawValue]
        return content
    }

    /// Post it, asking for permission the first time and giving up quietly if refused: the held
    /// actions are still on the activity trail and under My Day's Waiting on you.
    @MainActor
    static func post(body: String, center: UNUserNotificationCenter = .current()) {
        Task { @MainActor in
            let settings = await center.notificationSettings()
            do {
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral:
                    break
                case .notDetermined:
                    guard try await center.requestAuthorization(options: [.alert, .sound]) else { return }
                case .denied:
                    return
                @unknown default:
                    return
                }
                let request = UNNotificationRequest(identifier: identifier,
                                                    content: content(body: body), trigger: nil)
                try await center.add(request)
            } catch {
                // The activity trail still carries every held action.
            }
        }
    }
}
