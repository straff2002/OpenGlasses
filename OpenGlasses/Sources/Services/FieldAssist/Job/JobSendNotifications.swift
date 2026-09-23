import Foundation
import UserNotifications

/// The one notification the staged-send queue posts (Plan FO §6, P3b).
///
/// A report staged in the car is useless if the technician does not know it is waiting when they
/// stop. So the phone says so — once, replacing itself as the count changes, never a badge per
/// report.
///
/// **Permission is asked for only when it is first needed**, and a refusal costs nothing: the card
/// at the top of the Job tab carries the same fact, so a technician who has said no to
/// notifications has a complete flow and simply does not get a tap on the lock screen.
enum JobSendNotifications {

    /// One identifier, so the notification replaces itself rather than stacking.
    static let identifier = "field-assist.staged-sends"
    /// The key that says "open the Job tab" to whatever handles a tap.
    static let openTabKey = "og_open_tab"

    /// What the notification says for a given number of staged reports.
    static func body(stagedCount: Int) -> String {
        stagedCount == 1
            ? "One report is ready to send. One tap when you stop."
            : "\(stagedCount) reports are ready to send. One tap each when you stop."
    }

    static let title = "Ready to send"

    /// Post it, asking for permission the first time and giving up quietly if refused.
    ///
    /// Nothing here waits on the result: a staged send is already queued and already on the Job
    /// tab, and a notification that did not appear must not hold up the sentence the app is about
    /// to speak.
    @MainActor
    static func post(stagedCount: Int, center: UNUserNotificationCenter = .current()) {
        guard stagedCount > 0 else {
            center.removePendingNotificationRequests(withIdentifiers: [identifier])
            center.removeDeliveredNotifications(withIdentifiers: [identifier])
            return
        }
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                deliver(stagedCount: stagedCount, center: center)
            case .notDetermined:
                // Asked at the moment it is first useful, which is the only moment a technician
                // can judge the request.
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    guard granted else { return }
                    deliver(stagedCount: stagedCount, center: center)
                }
            case .denied:
                break
            @unknown default:
                break
            }
        }
    }

    private static func deliver(stagedCount: Int, center: UNUserNotificationCenter) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body(stagedCount: stagedCount)
        content.sound = .default
        content.userInfo = [openTabKey: MainTab.job.rawValue]
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }
}

/// Routes a tap on the staged-send notification to the Job tab.
///
/// Deliberately minimal: it implements **only** `didReceive`, so the app's foreground behaviour
/// for every other notification — timers, alarms, geofences, the digest — is exactly what it was
/// before this existed. A delegate that also answered `willPresent` would have changed all of them.
@MainActor
final class JobSendNotificationRouter: NSObject, UNUserNotificationCenterDelegate {

    /// Where a tap lands. Injected so the routing is provable without an app.
    private let openTab: (MainTab) -> Void

    init(openTab: @escaping (MainTab) -> Void) {
        self.openTab = openTab
        super.init()
    }

    /// Whether this notification asks for a tab, and which. Pure, so the test is a value test.
    static func requestedTab(from userInfo: [AnyHashable: Any]) -> MainTab? {
        guard let raw = userInfo[JobSendNotifications.openTabKey] as? String else { return nil }
        return MainTab(rawValue: raw)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        Task { @MainActor in
            if let tab = Self.requestedTab(from: userInfo) { self.openTab(tab) }
            completionHandler()
        }
    }
}
