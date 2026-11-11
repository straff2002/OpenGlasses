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
    /// The event's people (Plan KT §9.3), mapped by `CalendarAttendeeMapper`.
    var attendees: [CalendarPerson] = []
}

struct EventKitReminderRecord: Equatable {
    let id: String
    let title: String
    let dueDate: Date?
    let hasTime: Bool
    let priority: Int
    /// `EKReminder.calendar.title` — the Reminders list the item lives on.
    let listName: String?

    init(id: String, title: String, dueDate: Date?, hasTime: Bool, priority: Int,
         listName: String? = nil) {
        self.id = id
        self.title = title
        self.dueDate = dueDate
        self.hasTime = hasTime
        self.priority = priority
        self.listName = listName
    }
}

@MainActor
final class EventKitDayStore {
    private let eventStore: EKEventStore

    init(eventStore: EKEventStore = EKEventStore()) {
        self.eventStore = eventStore
    }

    var hasCalendarReadAccess: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
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
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return true
        case .notDetermined: return try await eventStore.requestFullAccessToEvents()
        default: return false
        }
    }

    func requestRemindersAccess() async throws -> Bool {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: return true
        case .notDetermined: return try await eventStore.requestFullAccessToReminders()
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
                    notes: event.notes?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                    attendees: CalendarAttendeeMapper.people(
                        organizer: event.organizer.map(EventKitParticipantRecord.init),
                        attendees: (event.attendees ?? []).map(EventKitParticipantRecord.init))
                )
            }
            .sorted {
                if $0.startDate != $1.startDate { return $0.startDate < $1.startDate }
                return $0.id < $1.id
            }
    }

    /// The calendar accounts iOS Calendar holds, for `GoogleCalendarPresence` (Plan KT §9.1).
    func calendarSources() -> [CalendarSourceRecord] {
        eventStore.sources.map { source in
            CalendarSourceRecord(title: source.title, kind: CalendarSourceRecord.Kind(source.sourceType))
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
            priority: reminder.priority,
            listName: reminder.calendar?.title.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        )
    }
}

extension EventKitParticipantRecord {
    /// Copies what the mapper needs out of EventKit.
    init(_ participant: EKParticipant) {
        let kind: Kind
        switch participant.participantType {
        case .person: kind = .person
        case .room: kind = .room
        case .resource: kind = .resource
        case .group: kind = .group
        default: kind = .unknown
        }
        let role: Role
        switch participant.participantRole {
        case .required: role = .required
        case .optional: role = .optional
        case .chair: role = .chair
        case .nonParticipant: role = .nonParticipant
        default: role = .unknown
        }
        let status: Status
        switch participant.participantStatus {
        case .accepted: status = .accepted
        case .declined: status = .declined
        case .tentative: status = .tentative
        case .pending: status = .pending
        case .delegated: status = .delegated
        case .completed: status = .completed
        case .inProcess: status = .inProcess
        default: status = .unknown
        }
        self.init(name: participant.name, url: participant.url, kind: kind, role: role,
                  status: status, isCurrentUser: participant.isCurrentUser)
    }
}

extension CalendarSourceRecord.Kind {
    init(_ type: EKSourceType) {
        switch type {
        case .local: self = .local
        case .exchange: self = .exchange
        case .calDAV: self = .calDAV
        case .mobileMe: self = .mobileMe
        case .subscribed: self = .subscribed
        case .birthdays: self = .birthdays
        @unknown default: self = .unknown
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
