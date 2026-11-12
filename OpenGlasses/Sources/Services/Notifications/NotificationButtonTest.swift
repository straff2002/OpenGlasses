import Foundation
import UIKit
import UserNotifications

/// Plan LM P4, check 5 — do a notification's buttons reach the hub with the app killed?
///
/// Nothing posts a notification with buttons until Plans LE and LG land, so the Developer panel
/// posts one: the same Done / Stop for today buttons under their own category, so a later plan's
/// handler for `avenkin.ask-until-done` never receives a test press. Each press is recorded with
/// the app's state when it arrived and how long after launch, which is the evidence: a press that
/// arrives `background` a few seconds after launch woke the app for it.
enum NotificationButtonTest {

    /// The same buttons as `askUntilDone`, under ids of their own (the catalog keeps every action id
    /// unique), so the test exercises exactly the presses LE and LG will receive.
    static let category = NotificationCategorySpec(
        id: "avenkin.developer-test",
        actions: NotificationActionCatalog.askUntilDone.actions.map { action in
            NotificationActionSpec(id: "avenkin.developer-test." + action.id.replacingOccurrences(of: "avenkin.", with: ""),
                                   title: action.title, opensApp: action.opensApp, destructive: action.destructive)
        }
    )

    /// Seconds after the press that the test notification fires — long enough to kill the app.
    static let delaySeconds: TimeInterval = 20

    private static let requestID = "avenkin.developer-test.notification"

    /// Set when the hub handler is registered at launch.
    @MainActor private(set) static var launchedAt: Date?

    /// Register the press handler. Called at launch beside the catalog's registration, so a press
    /// that launches the app finds it.
    @MainActor
    static func registerHandler(hub: NotificationActionHub = .shared, recorder: NotificationButtonTestLog = .shared) {
        launchedAt = Date()
        hub.register(categoryID: category.id) { press in
            let now = Date()
            recorder.append(NotificationButtonTestPress(
                pressedAt: now,
                actionID: press.actionID,
                appState: appStateToken(UIApplication.shared.applicationState),
                secondsSinceLaunch: launchedAt.map { now.timeIntervalSince($0) }
            ))
        }
    }

    /// Ask for permission if needed, then schedule the test notification. False when notifications
    /// are not allowed.
    @MainActor
    static func post(center: UNUserNotificationCenter = .current()) async -> Bool {
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else { return false }
        let content = UNMutableNotificationContent()
        content.title = "Notification button test"
        content.body = "Press Done or Stop for today. Kill the app first to test a cold launch."
        content.categoryIdentifier = category.id
        content.userInfo = [NotificationActionCatalog.subjectKey: "developer-test"]
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delaySeconds, repeats: false)
        do {
            try await center.add(UNNotificationRequest(identifier: requestID, content: content, trigger: trigger))
            return true
        } catch {
            return false
        }
    }

    static func appStateToken(_ state: UIApplication.State) -> String {
        switch state {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }
}

/// One test press: when, which button, the app's state and how long after launch. No wearer content.
struct NotificationButtonTestPress: Codable, Equatable, Sendable {
    let pressedAt: Date
    let actionID: String
    let appState: String
    let secondsSinceLaunch: TimeInterval?

    static let maxKept = 10

    static func appending(_ press: NotificationButtonTestPress,
                          to presses: [NotificationButtonTestPress]) -> [NotificationButtonTestPress] {
        Array((presses + [press]).suffix(maxKept))
    }

    /// `2026-11-12 21:04:10 · avenkin.done · background · 3.2s after launch`
    func line(calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let launch = secondsSinceLaunch.map { String(format: "%.1fs after launch", $0) } ?? "launch unknown"
        return "\(formatter.string(from: pressedAt)) · \(actionID) · \(appState) · \(launch)"
    }
}

/// The last ten test presses, for the Developer panel. Developer evidence only.
@MainActor
final class NotificationButtonTestLog: ObservableObject {
    static let shared = NotificationButtonTestLog()
    static let key = "developerNotificationButtonPresses"

    @Published private(set) var presses: [NotificationButtonTestPress]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        presses = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode([NotificationButtonTestPress].self, from: $0) } ?? []
    }

    func append(_ press: NotificationButtonTestPress) {
        presses = NotificationButtonTestPress.appending(press, to: presses)
        if let data = try? JSONEncoder().encode(presses) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
