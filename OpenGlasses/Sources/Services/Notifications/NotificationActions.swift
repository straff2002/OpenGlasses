import Foundation
import UserNotifications

/// Plan LM P2 — buttons on a notification.
///
/// The app's categories are declared here as values and registered once at launch:
/// `setNotificationCategories` replaces the whole set, so this file is the only place that calls
/// it. A plan that needs a different set of buttons adds a category here; a plan that posts one
/// sets the category and, in `userInfo`, `og_subject` — an opaque id the posting plan owns (a
/// reminder's id, never its text).

/// One button.
struct NotificationActionSpec: Equatable, Sendable {
    let id: String
    let title: String
    /// Whether pressing it brings the app to the front. The buttons here answer without opening it.
    let opensApp: Bool
    let destructive: Bool
}

/// One set of buttons.
struct NotificationCategorySpec: Equatable, Sendable {
    let id: String
    let actions: [NotificationActionSpec]
}

enum NotificationActionCatalog {

    /// The `userInfo` key carrying the posting plan's own id for what the notification is about.
    static let subjectKey = "og_subject"

    /// Done / Stop for today — Plan LG's keep-asking reminders and Plan LE's fallback notification.
    static let askUntilDone = NotificationCategorySpec(
        id: "avenkin.ask-until-done",
        actions: [
            NotificationActionSpec(id: "avenkin.done", title: String(localized: "Done"),
                                   opensApp: false, destructive: false),
            NotificationActionSpec(id: "avenkin.stop-today", title: String(localized: "Stop for today"),
                                   opensApp: false, destructive: false),
        ]
    )

    /// Every category the app registers.
    static let all: [NotificationCategorySpec] = [askUntilDone, NotificationButtonTest.category]

    static func category(id: String) -> NotificationCategorySpec? {
        all.first { $0.id == id }
    }

    /// The system's form of `all`.
    static func systemCategories() -> Set<UNNotificationCategory> {
        Set(all.map { spec in
            UNNotificationCategory(
                identifier: spec.id,
                actions: spec.actions.map { action in
                    var options: UNNotificationActionOptions = []
                    if action.opensApp { options.insert(.foreground) }
                    if action.destructive { options.insert(.destructive) }
                    return UNNotificationAction(identifier: action.id, title: action.title, options: options)
                },
                intentIdentifiers: [],
                options: []
            )
        })
    }

    /// Register the categories. Called once, where the app sets its notification delegate.
    static func register(center: UNUserNotificationCenter = .current()) {
        center.setNotificationCategories(systemCategories())
    }
}

/// A button press, as the plan that registered for its category receives it.
struct NotificationActionPress: Equatable, Sendable {
    let categoryID: String
    let actionID: String
    /// The posting plan's own id, from `og_subject`, if it set one.
    let subject: String?
}

/// What a notification response was. Pure, so the routing rule is a value test.
enum NotificationActionResponse: Equatable, Sendable {
    /// A custom button.
    case press(NotificationActionPress)
    /// The notification itself was tapped — today's routing (`og_open_tab`) applies.
    case tap
    /// Dismissed (only reported for a category that asks for it; none here does).
    case dismiss

    static func parse(actionIdentifier: String, categoryIdentifier: String,
                      userInfo: [AnyHashable: Any]) -> NotificationActionResponse {
        switch actionIdentifier {
        case UNNotificationDefaultActionIdentifier:
            return .tap
        case UNNotificationDismissActionIdentifier:
            return .dismiss
        default:
            let subject = userInfo[NotificationActionCatalog.subjectKey] as? String
            return .press(NotificationActionPress(categoryID: categoryIdentifier, actionID: actionIdentifier,
                                                  subject: subject))
        }
    }
}

/// Where a press goes: the handler a plan registered for the press's category. A press with no
/// handler is dropped quietly — the hub never guesses what a button meant.
@MainActor
final class NotificationActionHub {
    static let shared = NotificationActionHub()

    private var handlers: [String: (NotificationActionPress) -> Void] = [:]

    func register(categoryID: String, handler: @escaping (NotificationActionPress) -> Void) {
        handlers[categoryID] = handler
    }

    func unregister(categoryID: String) {
        handlers[categoryID] = nil
    }

    /// Hand `press` to its category's handler. False when no plan registered for it.
    @discardableResult
    func route(_ press: NotificationActionPress) -> Bool {
        guard let handler = handlers[press.categoryID] else {
            PrivacyLog.agent(.notifications, .notificationActionUnhandled, reason: PrivacyToken(press.categoryID))
            return false
        }
        handler(press)
        PrivacyLog.agent(.notifications, .notificationActionRouted, reason: PrivacyToken(press.categoryID))
        return true
    }
}
