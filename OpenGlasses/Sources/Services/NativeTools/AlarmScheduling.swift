import Foundation
import SwiftUI
import UserNotifications
#if canImport(AlarmKit)
import AlarmKit
#endif

/// Plan JH — a real alarm.
///
/// `set_alarm` used to schedule a local notification and call it an alarm. A tester asked for
/// seven o'clock, was told it was set, asked whether he would see it in the Clock app, was told
/// yes, found nothing, and asked the assistant to stop claiming alarms it had not set. Apple has
/// no API for an alarm in the Clock app; what it has, from iOS 26, is AlarmKit: an alarm the app
/// owns that the system rings like a Clock alarm — full-screen on the lock screen, through silent
/// mode and Focus, with a Stop button the system draws. That is now the first choice. The
/// notification is the fallback for a wearer who refuses the alarm permission, and every string
/// the model sees says which of the two it got.

/// An alarm the tool wants: a label and the moment it rings.
struct AlarmPlan: Equatable {
    let label: String
    let date: Date
}

/// An alarm that is set, as a backend reports it back.
struct ScheduledAlarm: Equatable {
    let id: String
    let label: String
    let date: Date
}

/// Whether a backend may ring at all.
enum AlarmAuthorization: Equatable {
    case authorized
    case denied
    /// No such backend on this device (below iOS 26.1, where the alert-only alarm appears, or a build without AlarmKit).
    case unavailable
}

/// Which backend a set goes to, from what the first choice answered. Pure.
enum AlarmBackendChoice: Equatable {
    /// AlarmKit: rings like a Clock alarm.
    case alarmKit
    /// A local notification from the app, with the reason the alarm was not AlarmKit's.
    case notification(reason: FallbackReason)

    enum FallbackReason: String, Equatable {
        /// The wearer refused the alarm permission (or has not been asked and refused now).
        case permissionDenied
        /// This device cannot ring a real alarm.
        case unavailable
        /// AlarmKit accepted the permission but refused the alarm (its limit, or an error).
        case schedulingFailed
    }

    static func decide(authorization: AlarmAuthorization) -> AlarmBackendChoice {
        switch authorization {
        case .authorized: return .alarmKit
        case .denied: return .notification(reason: .permissionDenied)
        case .unavailable: return .notification(reason: .unavailable)
        }
    }
}

/// One way of ringing at a time. Two implementations, one seam, so the tool is tested against
/// a fake and the AlarmKit calls are kept where a test never reaches them.
protocol AlarmScheduler: Sendable {
    func authorize() async -> AlarmAuthorization
    /// Schedules the alarm and returns its id.
    func schedule(_ plan: AlarmPlan) async throws -> String
    func pending() async -> [ScheduledAlarm]
    /// Cancels every alarm this backend set; returns how many.
    func cancelAll() async -> Int
}

// MARK: - AlarmKit

#if canImport(AlarmKit)
/// AlarmKit carries no title of its own on the `Alarm` it hands back, so the labels are kept here,
/// keyed by alarm id, for `list`.
enum AlarmLabelStore {
    static let key = "alarmKitLabels"

    static func labels(_ defaults: UserDefaults = .standard) -> [String: String] {
        defaults.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    static func remember(_ label: String, for id: String, in defaults: UserDefaults = .standard) {
        var labels = labels(defaults)
        labels[id] = label
        defaults.set(labels, forKey: key)
    }

    /// Drops every label whose alarm is no longer scheduled.
    static func prune(keeping ids: Set<String>, in defaults: UserDefaults = .standard) {
        let kept = labels(defaults).filter { ids.contains($0.key) }
        defaults.set(kept, forKey: key)
    }
}

/// The alarm's metadata: nothing yet. AlarmKit requires a type.
struct AvenkinAlarmMetadata: AlarmMetadata {}

@available(iOS 26.1, *)
struct AlarmKitScheduler: AlarmScheduler {
    func authorize() async -> AlarmAuthorization {
        let manager = AlarmManager.shared
        switch manager.authorizationState {
        case .authorized: return .authorized
        case .denied: return .denied
        case .notDetermined:
            let state = (try? await manager.requestAuthorization()) ?? .denied
            return state == .authorized ? .authorized : .denied
        @unknown default:
            return .denied
        }
    }

    func schedule(_ plan: AlarmPlan) async throws -> String {
        let title = LocalizedStringResource(String.LocalizationValue(plan.label))
        let alert = AlarmPresentation.Alert(title: title)
        let attributes = AlarmAttributes<AvenkinAlarmMetadata>(
            presentation: AlarmPresentation(alert: alert), tintColor: AccentColors.aiCoral)
        let configuration = AlarmManager.AlarmConfiguration<AvenkinAlarmMetadata>.alarm(
            schedule: .fixed(plan.date), attributes: attributes)
        let id = UUID()
        _ = try await AlarmManager.shared.schedule(id: id, configuration: configuration)
        AlarmLabelStore.remember(plan.label, for: id.uuidString)
        return id.uuidString
    }

    func pending() async -> [ScheduledAlarm] {
        let labels = AlarmLabelStore.labels()
        let alarms: [ScheduledAlarm] = ((try? AlarmManager.shared.alarms) ?? []).compactMap { alarm in
            guard case .fixed(let date) = alarm.schedule else { return nil }
            return ScheduledAlarm(id: alarm.id.uuidString,
                                  label: labels[alarm.id.uuidString] ?? "Alarm", date: date)
        }
        AlarmLabelStore.prune(keeping: Set(alarms.map(\.id)))
        return alarms.sorted { $0.date < $1.date }
    }

    func cancelAll() async -> Int {
        let manager = AlarmManager.shared
        var cancelled = 0
        for alarm in (try? manager.alarms) ?? [] where (try? manager.cancel(id: alarm.id)) != nil {
            cancelled += 1
        }
        AlarmLabelStore.prune(keeping: [])
        return cancelled
    }
}
#endif

// MARK: - Local notification (the fallback)

/// The alarm the tool always had: a time-sensitive local notification. It does not ring through
/// silent mode and no Apple app lists it, which is why it is the fallback now.
struct NotificationAlarmScheduler: AlarmScheduler {
    static let idPrefix = "alarm-"

    func authorize() async -> AlarmAuthorization {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .authorized
        case .denied: return .denied
        case .notDetermined:
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            return granted ? .authorized : .denied
        @unknown default: return .denied
        }
    }

    func schedule(_ plan: AlarmPlan) async throws -> String {
        let content = UNMutableNotificationContent()
        content.title = plan.label
        content.body = String(localized: "Alarm: \(plan.label)")
        content.sound = .defaultCritical
        content.interruptionLevel = .timeSensitive
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: plan.date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let id = "\(Self.idPrefix)\(UUID().uuidString)"
        try await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: id, content: content, trigger: trigger))
        return id
    }

    func pending() async -> [ScheduledAlarm] {
        let requests = await UNUserNotificationCenter.current().pendingNotificationRequests()
        return requests.compactMap { request in
            guard request.identifier.hasPrefix(Self.idPrefix),
                  let trigger = request.trigger as? UNCalendarNotificationTrigger,
                  let date = trigger.nextTriggerDate() else { return nil }
            return ScheduledAlarm(id: request.identifier, label: request.content.title, date: date)
        }.sorted { $0.date < $1.date }
    }

    func cancelAll() async -> Int {
        let center = UNUserNotificationCenter.current()
        let ids = await center.pendingNotificationRequests()
            .map(\.identifier).filter { $0.hasPrefix(Self.idPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: ids)
        return ids.count
    }
}

/// The backends this device offers, first choice first.
enum AlarmSchedulers {
    /// AlarmKit where it exists, else nil: the tool then goes straight to the notification.
    static var realAlarm: (any AlarmScheduler)? {
        #if canImport(AlarmKit)
        if #available(iOS 26.1, *) { return AlarmKitScheduler() }
        #endif
        return nil
    }

    static var notification: any AlarmScheduler { NotificationAlarmScheduler() }
}
