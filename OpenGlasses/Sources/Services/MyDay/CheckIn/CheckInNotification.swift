import Foundation
import UIKit
import UserNotifications

// Plan LE §5 (P2) — the Evening Check-in's notification, for when the app isn't running at the time.
//
// **Content-free, always.** Title "My Day", body "Your evening check-in is ready." It is scheduled in
// advance, so anything in it would be stale, and the list can name other people (§5, §9). Nothing
// about the list — no count, no title, no name — ever goes into a notification, and the `userInfo`
// carries only the evening's day key.
//
// **One per evening, not one repeating request.** §5 sketched a single repeating notification, but a
// repeating request cannot lose one evening: removing it removes every evening, and a calendar
// trigger cannot be told to start tomorrow. So the scheduler keeps a rolling window of single
// requests, one per evening for the next `daysAhead` days, each named by its day key and time
// (`my-day.check-in.2026-11-15.1260`). Removing tonight's is then removing one identifier, and a
// changed time or switch is a different set of identifiers. The window is topped up whenever the
// app comes to the front, the settings change, the check-in runs, and in the shared background wake
// (`BackgroundRefreshCoordinator`), so it lapses only after a week with none of those.
//
// **Who owns which notification.** This file owns every notification the check-in puts on the phone:
// the scheduled ones and the one left after a check-in that ran with the app alive but was not
// spoken. `MyDayScheduledDeliveryService`'s delivery notification (`onDelivery`) keeps the morning
// and evening briefings and no longer posts for the check-in, so there is never a second banner for
// the same evening.

/// One evening's notification, as the phone holds it.
struct CheckInNotificationRequest: Equatable, Sendable {
    let identifier: String
    let dayKey: String
    /// Year, month, day, hour and minute in the wearer's calendar — what the trigger fires on.
    let fireAt: DateComponents
}

/// What to do with tonight's notification once the check-in has run with the app alive.
enum CheckInAfterRun: Equatable, Sendable {
    /// Take tonight's off the phone, pending or delivered: it was heard, or there was nothing to say.
    case remove(identifiers: [String])
    /// It was shown and not spoken (driving, the glasses off): leave one notification now, under
    /// tonight's identifier, so it replaces the scheduled one rather than adding to it.
    case postNow(identifier: String, dayKey: String)
}

enum CheckInNotificationPolicy {

    static let identifierPrefix = "my-day.check-in."
    /// The `userInfo` key a tap reads: the evening's day key, nothing else.
    static let dayKeyInfoKey = "og_check_in_day"
    /// Evenings scheduled ahead.
    static let daysAhead = 7
    /// The notification fires this long after the check-in's time, so a process that is alive
    /// delivers first (its timer looks once a minute) and takes tonight's away before it shows.
    static let delayMinutes = 2

    static var title: String {
        String(localized: "My Day", comment: "Notification title for a ready My Day card.")
    }

    /// The one body the check-in's notification ever has (decision 3). It names nothing.
    static var body: String {
        String(localized: "Your evening check-in is ready.",
               comment: "Notification: the evening check-in was delivered; names nothing in it.")
    }

    static func identifier(dayKey: String, minutes: Int) -> String {
        "\(identifierPrefix)\(dayKey).\(minutes)"
    }

    static func isCheckIn(identifier: String) -> Bool {
        identifier.hasPrefix(identifierPrefix)
    }

    /// The day key an identifier was scheduled for.
    static func dayKey(of identifier: String) -> String? {
        guard isCheckIn(identifier: identifier) else { return nil }
        let rest = identifier.dropFirst(identifierPrefix.count)
        guard let dot = rest.firstIndex(of: ".") else { return String(rest) }
        return String(rest[..<dot])
    }

    /// Whether a tapped notification is the check-in's, and for which evening.
    static func dayKey(from userInfo: [AnyHashable: Any]) -> String? {
        userInfo[dayKeyInfoKey] as? String
    }

    /// The evenings that should have a notification waiting: none while My Day or the check-in is
    /// off; otherwise one for each of the next `daysAhead` evenings, starting today unless today's
    /// notification time has passed or today's check-in has already run, and never one that would
    /// fire inside quiet hours (the check-in itself would only defer there).
    static func wanted(now: Date, calendar: Calendar, settings: MyDayDeliverySettings,
                       lastCheckInDayKey: String) -> [CheckInNotificationRequest] {
        guard settings.myDayEnabled, settings.checkInEnabled else { return [] }
        let minutes = min(23 * 60 + 59, max(0, settings.resolvedCheckInMinutes))
        let fireMinute = min(23 * 60 + 59, minutes + delayMinutes)
        if settings.quietHoursEnabled,
           MyDayDeliveryPolicy.isQuiet(minute: fireMinute,
                                       start: min(23 * 60 + 59, max(0, settings.quietStartMinutes)),
                                       end: min(23 * 60 + 59, max(0, settings.quietEndMinutes))) {
            return []
        }
        let today = calendar.startOfDay(for: now)
        var requests: [CheckInNotificationRequest] = []
        for offset in 0..<daysAhead {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  let fire = calendar.date(bySettingHour: fireMinute / 60, minute: fireMinute % 60,
                                           second: 0, of: day) else { continue }
            let dayKey = MyDayDeliveryPolicy.dayKey(for: day, calendar: calendar)
            if offset == 0, fire <= now || dayKey == lastCheckInDayKey { continue }
            let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
            requests.append(CheckInNotificationRequest(identifier: identifier(dayKey: dayKey, minutes: minutes),
                                                       dayKey: dayKey, fireAt: parts))
        }
        return requests
    }

    /// What to change so the phone holds exactly `wanted`: add the missing ones, remove every other
    /// check-in identifier pending. Identifiers that are not the check-in's are never touched.
    static func reconcile(wanted: [CheckInNotificationRequest],
                          pending: [String]) -> (add: [CheckInNotificationRequest], remove: [String]) {
        let pendingOurs = Set(pending.filter(isCheckIn(identifier:)))
        let wantedIDs = Set(wanted.map(\.identifier))
        let add = wanted.filter { !pendingOurs.contains($0.identifier) }
        let remove = pendingOurs.subtracting(wantedIDs).sorted()
        return (add, remove)
    }

    /// Tonight's check-in has run with the app alive. Spoken, or with nothing to say: tonight's
    /// notification goes (§5). Shown and not spoken: one stays, so the wearer finds it.
    static func afterRun(dayKey: String, minutes: Int, delivered: Bool, spoke: Bool,
                         known: [String]) -> CheckInAfterRun {
        let tonight = known.filter { self.dayKey(of: $0) == dayKey }.sorted()
        if delivered && !spoke {
            // The scheduled identifier when there is one, so the post replaces it in place.
            return .postNow(identifier: tonight.first ?? identifier(dayKey: dayKey, minutes: minutes), dayKey: dayKey)
        }
        return .remove(identifiers: tonight)
    }
}

// MARK: - The seam over UNUserNotificationCenter

/// What the scheduler needs from the notification centre. The app's is `SystemCheckInNotificationCenter`;
/// the tests use a fake, so nothing here needs the system.
@MainActor
protocol CheckInNotificationCentering: AnyObject {
    func pendingIdentifiers() async -> [String]
    func deliveredIdentifiers() async -> [String]
    /// Add one request: at its time, or now when `immediately`.
    func add(_ request: CheckInNotificationRequest, immediately: Bool) async
    func remove(pending: [String], delivered: [String])
    /// Whether the phone lets the app notify — asking the wearer once, only when `askIfNeeded`.
    func mayNotify(askIfNeeded: Bool) async -> Bool
}

@MainActor
final class SystemCheckInNotificationCenter: CheckInNotificationCentering {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func pendingIdentifiers() async -> [String] {
        await center.pendingNotificationRequests().map(\.identifier)
    }

    func deliveredIdentifiers() async -> [String] {
        await center.deliveredNotifications().map(\.request.identifier)
    }

    func add(_ request: CheckInNotificationRequest, immediately: Bool) async {
        let content = UNMutableNotificationContent()
        content.title = CheckInNotificationPolicy.title
        content.body = CheckInNotificationPolicy.body
        content.sound = .default
        content.userInfo = [CheckInNotificationPolicy.dayKeyInfoKey: request.dayKey]
        let trigger = immediately ? nil : UNCalendarNotificationTrigger(dateMatching: request.fireAt, repeats: false)
        try? await center.add(UNNotificationRequest(identifier: request.identifier, content: content, trigger: trigger))
    }

    func remove(pending: [String], delivered: [String]) {
        if !pending.isEmpty { center.removePendingNotificationRequests(withIdentifiers: pending) }
        if !delivered.isEmpty { center.removeDeliveredNotifications(withIdentifiers: delivered) }
    }

    func mayNotify(askIfNeeded: Bool) async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            // Asked only in the foreground, right after the wearer turned the check-in on: the one
            // moment they can judge the request.
            guard askIfNeeded else { return false }
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        case .denied:
            return false
        @unknown default:
            return false
        }
    }
}

// MARK: - The scheduler

/// Keeps the phone holding exactly the check-in notifications the policy wants. Stores nothing of its
/// own: the notification centre is the record.
@MainActor
final class CheckInNotificationScheduler {

    /// The participant id in the shared background wake. A literal: it is logged.
    static let backgroundID = "check-in-notifications"
    /// How often a background wake tops the window up.
    static let backgroundInterval: TimeInterval = 24 * 60 * 60

    var settings: @MainActor () -> MyDayDeliverySettings = { .current }
    var lastCheckInDayKey: @MainActor () -> String = { Config.myDayLastCheckInDeliveryDay }
    var calendar: @MainActor () -> Calendar = { .autoupdatingCurrent }
    var now: @MainActor () -> Date = Date.init
    /// Whether a missing permission may be asked for now (the app is in front). Asked only on the
    /// reconcile that follows the wearer switching the check-in on.
    var mayAsk: @MainActor () -> Bool = { UIApplication.shared.applicationState == .active }

    private let center: CheckInNotificationCentering
    private(set) var lastReconciledAt: Date?
    /// Whether the check-in was on at the last reconcile in this process: the permission is asked
    /// for only when it has just been switched on, never because some other setting moved.
    private var wasOn: Bool?
    private var observers: [NSObjectProtocol] = []
    private var pendingReconcile: Task<Void, Never>?

    init(center: CheckInNotificationCentering) {
        self.center = center
    }

    /// Reconcile now, and again on every foreground and settings change (debounced).
    func start() {
        guard observers.isEmpty else { return }
        let notifications = NotificationCenter.default
        observers.append(notifications.addObserver(forName: UIApplication.willEnterForegroundNotification,
                                                   object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.reconcile() }
        })
        observers.append(notifications.addObserver(forName: UserDefaults.didChangeNotification,
                                                   object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reconcileSoon() }
        })
        Task { @MainActor [weak self] in await self?.reconcile() }
    }

    /// The settings write many keys at once; reconcile once they settle.
    private func reconcileSoon() {
        pendingReconcile?.cancel()
        pendingReconcile = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.reconcile()
        }
    }

    /// Make the pending check-in notifications exactly what the policy wants. True when it changed
    /// anything.
    @discardableResult
    func reconcile() async -> Bool {
        let now = self.now()
        lastReconciledAt = now
        let current = settings()
        let isOn = current.myDayEnabled && current.checkInEnabled
        let justTurnedOn = wasOn == false && isOn
        wasOn = isOn
        let wanted = CheckInNotificationPolicy.wanted(now: now, calendar: calendar(), settings: current,
                                                      lastCheckInDayKey: lastCheckInDayKey())
        let pending = await center.pendingIdentifiers()
        let plan = CheckInNotificationPolicy.reconcile(wanted: wanted, pending: pending)
        var add = plan.add
        let remove = plan.remove
        if wanted.isEmpty {
            // Off: delivered ones go too, so a switched-off check-in leaves nothing on the phone.
            let delivered = await center.deliveredIdentifiers().filter(CheckInNotificationPolicy.isCheckIn(identifier:))
            center.remove(pending: remove, delivered: delivered)
            return !remove.isEmpty || !delivered.isEmpty
        }
        if !add.isEmpty, !(await center.mayNotify(askIfNeeded: justTurnedOn && mayAsk())) { add = [] }
        center.remove(pending: remove, delivered: [])
        for request in add { await center.add(request, immediately: false) }
        return !add.isEmpty || !remove.isEmpty
    }

    /// Tonight's check-in ran with the app alive (§5): `delivered` is whether it had anything to say,
    /// `spoke` whether it was said aloud.
    func checkInRan(dayKey: String, delivered: Bool, spoke: Bool) async {
        let pending = await center.pendingIdentifiers()
        let shown = await center.deliveredIdentifiers()
        let known = (pending + shown).filter(CheckInNotificationPolicy.isCheckIn(identifier:))
        switch CheckInNotificationPolicy.afterRun(dayKey: dayKey, minutes: settings().resolvedCheckInMinutes,
                                                  delivered: delivered, spoke: spoke, known: known) {
        case .remove(let identifiers):
            center.remove(pending: identifiers.filter(pending.contains), delivered: identifiers.filter(shown.contains))
        case .postNow(let identifier, let dayKey):
            // Replaces tonight's scheduled one in place (same identifier); never asks for permission.
            guard await center.mayNotify(askIfNeeded: false) else { return }
            center.remove(pending: [identifier].filter(pending.contains), delivered: [])
            await center.add(CheckInNotificationRequest(identifier: identifier, dayKey: dayKey,
                                                        fireAt: DateComponents()), immediately: true)
        }
    }

    /// When the window next wants topping up: nil while the check-in is off.
    func nextBackgroundWake(now: Date) -> Date? {
        let current = settings()
        guard current.myDayEnabled, current.checkInEnabled else { return nil }
        guard let last = lastReconciledAt else { return now }
        return last.addingTimeInterval(Self.backgroundInterval)
    }

    /// The shared background wake's participant (Plan LM): tops the window up, so a week without
    /// opening the app still leaves the evenings scheduled. Nothing is said or read from the list.
    func backgroundParticipant() -> BackgroundWorkParticipant {
        BackgroundWorkParticipant(
            id: Self.backgroundID,
            minimumSeconds: 2,
            nextWake: { [weak self] now in self?.nextBackgroundWake(now: now) },
            run: { [weak self] _ in
                guard let self else { return .nothingToDo }
                let current = self.settings()
                guard current.myDayEnabled, current.checkInEnabled else { return .notDue }
                return await self.reconcile() ? .didWork : .nothingToDo
            }
        )
    }
}
