import EventKit
import Foundation

struct EventKitCalendarRecord: Equatable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
    let location: String?
    let notes: String?
}

struct EventKitReminderRecord: Equatable {
    let id: String
    let title: String
    let dueDate: Date?
    let hasTime: Bool
    let priority: Int
}

@MainActor
final class EventKitDayStore {
    private let eventStore: EKEventStore

    init(eventStore: EKEventStore = EKEventStore()) {
        self.eventStore = eventStore
    }

    var hasCalendarReadAccess: Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(iOS 17.0, *) { return status == .fullAccess }
        return status == .authorized
    }

    /// Scheduled My Day must never trigger a first-use permission sheet. A denied/restricted
    /// source is still resolved: its adapter can report an honest partial-availability state.
    var calendarAuthorizationIsResolved: Bool {
        EKEventStore.authorizationStatus(for: .event) != .notDetermined
    }

    var remindersAuthorizationIsResolved: Bool {
        EKEventStore.authorizationStatus(for: .reminder) != .notDetermined
    }

    func requestCalendarAccess() async throws -> Bool {
        if #available(iOS 17.0, *) {
            switch EKEventStore.authorizationStatus(for: .event) {
            case .fullAccess: return true
            case .notDetermined: return try await eventStore.requestFullAccessToEvents()
            default: return false
            }
        }
        switch EKEventStore.authorizationStatus(for: .event) {
        case .authorized: return true
        case .notDetermined: return try await eventStore.requestAccess(to: .event)
        default: return false
        }
    }

    func requestRemindersAccess() async throws -> Bool {
        if #available(iOS 17.0, *) {
            switch EKEventStore.authorizationStatus(for: .reminder) {
            case .fullAccess: return true
            case .notDetermined: return try await eventStore.requestFullAccessToReminders()
            default: return false
            }
        }
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .authorized: return true
        case .notDetermined: return try await eventStore.requestAccess(to: .reminder)
        default: return false
        }
    }

    func calendarEvents(from start: Date, to end: Date) -> [EventKitCalendarRecord] {
        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
        return eventStore.events(matching: predicate)
            .map { event in
                EventKitCalendarRecord(
                    id: event.eventIdentifier ?? event.calendarItemIdentifier,
                    title: event.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Untitled",
                    startDate: event.startDate,
                    endDate: event.endDate,
                    isAllDay: event.isAllDay,
                    location: event.location?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                    notes: event.notes?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                )
            }
            .sorted {
                if $0.startDate != $1.startDate { return $0.startDate < $1.startDate }
                return $0.id < $1.id
            }
    }

    func saveCalendarEvent(
        title: String,
        startDate: Date,
        endDate: Date,
        location: String?
    ) throws {
        let event = EKEvent(eventStore: eventStore)
        event.title = title
        event.startDate = startDate
        event.endDate = endDate
        event.calendar = eventStore.defaultCalendarForNewEvents
        event.location = location
        event.addAlarm(EKAlarm(relativeOffset: -900))
        try eventStore.save(event, span: .thisEvent)
    }

    func incompleteReminders() async -> [EventKitReminderRecord] {
        let calendars = eventStore.calendars(for: .reminder)
        let predicate = eventStore.predicateForIncompleteReminders(
            withDueDateStarting: nil,
            ending: nil,
            calendars: calendars
        )
        let reminders: [EKReminder] = await withCheckedContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }
        return reminders.map(Self.record(from:))
    }

    func saveReminder(title: String, dueDate: Date?, hasTime: Bool) throws {
        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = title
        reminder.calendar = eventStore.defaultCalendarForNewReminders()
        if let dueDate {
            var components = Calendar.autoupdatingCurrent.dateComponents([.year, .month, .day], from: dueDate)
            if hasTime {
                let time = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: dueDate)
                components.hour = time.hour
                components.minute = time.minute
                reminder.addAlarm(EKAlarm(absoluteDate: dueDate))
            }
            reminder.dueDateComponents = components
        }
        try eventStore.save(reminder, commit: true)
    }

    func completeReminder(id: String) async throws -> String? {
        let reminders = await incompleteEKReminders()
        guard let reminder = reminders.first(where: { $0.calendarItemIdentifier == id }) else { return nil }
        reminder.isCompleted = true
        try eventStore.save(reminder, commit: true)
        return reminder.title
    }

    private func incompleteEKReminders() async -> [EKReminder] {
        let calendars = eventStore.calendars(for: .reminder)
        let predicate = eventStore.predicateForIncompleteReminders(
            withDueDateStarting: nil,
            ending: nil,
            calendars: calendars
        )
        return await withCheckedContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }
    }

    private static func record(from reminder: EKReminder) -> EventKitReminderRecord {
        let components = reminder.dueDateComponents
        let date = components.flatMap { Calendar.autoupdatingCurrent.date(from: $0) }
        return EventKitReminderRecord(
            id: reminder.calendarItemIdentifier,
            title: reminder.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Untitled",
            dueDate: date,
            hasTime: components?.hour != nil,
            priority: reminder.priority
        )
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
