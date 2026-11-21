import Foundation
import UserNotifications

// Plan MY §6, Decision 11 — the weekly count reminder: a local notification on the day and time the
// clinic chooses, off until it is chosen.
//
// **Content-free.** Title "Stock", body "The weekly stock count is due." Nothing about the stock — no
// line, lot, figure or name — goes into it, and its `userInfo` is empty. It is one repeating weekly
// request under one identifier, so changing the day or time replaces it and switching it off removes
// it; nothing has to be topped up.

/// The clinic's choice: whether the reminder is on, and on which weekday and minute of the day.
struct StockCountReminderSettings: Codable, Equatable, Sendable {
    var enabled = false
    /// 1 is Sunday, 7 is Saturday, as `Calendar` numbers them.
    var weekday = 2
    /// Minutes after midnight.
    var minute = 9 * 60

    private static let defaultsKey = "vaccineStockCountReminder"

    static func stored(_ defaults: UserDefaults = .standard) -> StockCountReminderSettings {
        defaults.data(forKey: defaultsKey)
            .flatMap { try? JSONDecoder().decode(StockCountReminderSettings.self, from: $0) } ?? StockCountReminderSettings()
    }

    func store(_ defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

/// One weekly request, as the phone holds it.
struct StockCountReminderRequest: Equatable, Sendable {
    let identifier: String
    /// Weekday, hour and minute: what a repeating calendar trigger fires on.
    let fireAt: DateComponents
}

enum StockCountReminderPolicy {

    static let identifier = "stock.weekly-count"

    static var title: String {
        String(localized: "Stock", comment: "Notification title for the weekly stock count reminder.")
    }

    /// The one body the reminder ever has. It names nothing on the list.
    static var body: String {
        String(localized: "The weekly stock count is due.",
               comment: "Notification: the clinic's chosen day and time for its weekly stock count.")
    }

    /// The request the phone should hold: none while the reminder is off (the default), otherwise
    /// one on the chosen weekday and time, with both kept in range.
    static func wanted(_ settings: StockCountReminderSettings) -> StockCountReminderRequest? {
        guard settings.enabled else { return nil }
        let weekday = min(7, max(1, settings.weekday))
        let minute = min(23 * 60 + 59, max(0, settings.minute))
        var parts = DateComponents()
        parts.weekday = weekday
        parts.hour = minute / 60
        parts.minute = minute % 60
        return StockCountReminderRequest(identifier: identifier, fireAt: parts)
    }

    /// "Mondays at 09:00", in English for the model, as every stock sentence is (the screen shows
    /// the system's own weekday names).
    static func describe(_ settings: StockCountReminderSettings) -> String {
        guard settings.enabled else { return "off" }
        let names = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        let weekday = min(7, max(1, settings.weekday))
        let name = names[weekday - 1]
        let minute = min(23 * 60 + 59, max(0, settings.minute))
        return String(format: "%@s at %02d:%02d", name, minute / 60, minute % 60)
    }
}

/// What the scheduler needs from the notification centre; the tests use a fake.
@MainActor
protocol StockCountReminderCentering: AnyObject {
    func pendingIdentifiers() async -> [String]
    func add(_ request: StockCountReminderRequest) async
    func remove(_ identifiers: [String])
    /// Whether the phone lets the app notify, asking once when `askIfNeeded`.
    func mayNotify(askIfNeeded: Bool) async -> Bool
}

@MainActor
final class SystemStockCountReminderCenter: StockCountReminderCentering {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func pendingIdentifiers() async -> [String] {
        await center.pendingNotificationRequests().map(\.identifier)
    }

    func add(_ request: StockCountReminderRequest) async {
        let content = UNMutableNotificationContent()
        content.title = StockCountReminderPolicy.title
        content.body = StockCountReminderPolicy.body
        content.sound = .default
        let trigger = UNCalendarNotificationTrigger(dateMatching: request.fireAt, repeats: true)
        try? await center.add(UNNotificationRequest(identifier: request.identifier, content: content, trigger: trigger))
    }

    func remove(_ identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func mayNotify(askIfNeeded: Bool) async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            guard askIfNeeded else { return false }
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        case .denied:
            return false
        @unknown default:
            return false
        }
    }
}

/// Keeps the phone's one weekly request in step with the clinic's choice.
@MainActor
final class StockCountReminderScheduler {
    static let shared = StockCountReminderScheduler()

    private let center: StockCountReminderCentering
    private let defaults: UserDefaults

    init(center: StockCountReminderCentering? = nil, defaults: UserDefaults = .standard) {
        self.center = center ?? SystemStockCountReminderCenter()
        self.defaults = defaults
    }

    var settings: StockCountReminderSettings { StockCountReminderSettings.stored(defaults) }

    /// Save the choice and bring the phone's request in line with it. False when it was switched on
    /// and the phone does not let the app notify; the choice is kept, and no request is added.
    @discardableResult
    func apply(_ settings: StockCountReminderSettings, askIfNeeded: Bool = true) async -> Bool {
        settings.store(defaults)
        return await reconcile(askIfNeeded: askIfNeeded)
    }

    @discardableResult
    func reconcile(askIfNeeded: Bool = false) async -> Bool {
        let pending = await center.pendingIdentifiers().filter { $0 == StockCountReminderPolicy.identifier }
        // Removed first, so a changed day or time never leaves the old one behind.
        center.remove(pending)
        guard let wanted = StockCountReminderPolicy.wanted(settings) else { return true }
        guard await center.mayNotify(askIfNeeded: askIfNeeded) else { return false }
        await center.add(wanted)
        return true
    }
}
