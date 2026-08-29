import Foundation

/// Creates, lists, and completes Apple Reminders through the shared EventKit day store.
/// My Day uses stable reminder IDs; conversational completion resolves a unique title and asks
/// when multiple reminders match instead of silently completing the first substring.
final class AppleRemindersTool: NativeTool, @unchecked Sendable {
    let name = "reminder"
    let description = "Create, list, or complete Apple Reminders. Creation accepts an absolute ISO-8601 due_at value; completion can target an exact reminder ID or an unambiguous title."
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": ["type": "string", "description": "Action: 'create', 'list', or 'complete'."],
            "title": ["type": "string", "description": "Reminder text for create, or an exact title for complete."],
            "due_at": [
                "type": "string",
                "description": "Optional absolute ISO-8601 due date/time for create, e.g. '2026-08-30T17:00:00+12:00'. Convert the user's words to this absolute value before calling the tool."
            ],
            "id": ["type": "string", "description": "Stable reminder ID for exact completion."],
            "search": ["type": "string", "description": "Title to resolve for complete when no stable ID is available."]
        ],
        "required": ["action"]
    ]

    private let eventStore: EventKitDayStore
    private let now: () -> Date

    @MainActor
    convenience init() {
        self.init(eventStore: EventKitDayStore())
    }

    @MainActor
    init(eventStore: EventKitDayStore, now: @escaping () -> Date = Date.init) {
        self.eventStore = eventStore
        self.now = now
    }

    func execute(args: [String: Any]) async throws -> String {
        guard try await eventStore.requestRemindersAccess() else {
            return "Reminders access denied. Please enable it in Settings > Privacy > Reminders."
        }

        switch (args["action"] as? String ?? "create").lowercased() {
        case "create", "add", "set": return try createReminder(args: args)
        case "list", "show": return await listReminders()
        case "complete", "done", "finish": return await completeReminder(args: args)
        default: return "Unknown action. Use: create, list, or complete."
        }
    }

    private func createReminder(args: [String: Any]) throws -> String {
        guard let title = (args["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return "No reminder text provided."
        }

        let due: Date?
        switch ReminderDuePolicy.validate(args["due_at"] as? String, now: now()) {
        case .valid(let date): due = date
        case .invalidISO8601:
            return "The due_at value must be an absolute ISO-8601 date and time."
        case .past:
            return "That due date is in the past. Choose a future date or time."
        }

        try eventStore.saveReminder(title: title, dueDate: due, hasTime: due != nil)
        var response = "Reminder set: '\(title)'"
        if let due {
            response += " due \(formatDueDate(due, hasTime: true))"
            response += ". You'll get a notification at that time"
        }
        return response + "."
    }

    private func listReminders() async -> String {
        let reminders = await eventStore.incompleteReminders().sorted(by: Self.reminderOrder)
        guard !reminders.isEmpty else { return "No incomplete reminders." }

        let descriptions = reminders.prefix(10).map { reminder -> String in
            guard let due = reminder.dueDate else { return reminder.title }
            return "\(reminder.title) (due \(formatDueDate(due, hasTime: reminder.hasTime)))"
        }
        var result = "\(reminders.count) reminder\(reminders.count == 1 ? "" : "s"): \(descriptions.joined(separator: ". "))."
        if reminders.count > 10 { result += " Plus \(reminders.count - 10) more." }
        return result
    }

    private func completeReminder(args: [String: Any]) async -> String {
        if let id = (args["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
            return await completeExact(id: id)
        }
        guard let search = ((args["search"] as? String) ?? (args["title"] as? String))?
            .trimmingCharacters(in: .whitespacesAndNewlines), !search.isEmpty else {
            return "Tell me which reminder to complete."
        }

        let reminders = await eventStore.incompleteReminders()
        switch ReminderMatchPolicy.resolve(search: search, reminders: reminders) {
        case .match(let id, _): return await completeExact(id: id)
        case .ambiguous(let titles):
            return "More than one reminder matches '\(search)': \(titles.joined(separator: ", ")). Say the exact title."
        case .notFound: return "No incomplete reminder matching '\(search)'."
        }
    }

    private func completeExact(id: String) async -> String {
        do {
            guard let title = try await eventStore.completeReminder(id: id) else {
                return "That reminder is no longer available."
            }
            return "Marked '\(title)' as complete."
        } catch {
            return "Couldn't complete reminder: \(error.localizedDescription)"
        }
    }

    private func formatDueDate(_ date: Date, hasTime: Bool) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = hasTime ? "EEEE, MMM d 'at' h:mm a" : "EEEE, MMM d"
        return formatter.string(from: date)
    }

    private static func reminderOrder(_ lhs: EventKitReminderRecord, _ rhs: EventKitReminderRecord) -> Bool {
        if lhs.dueDate != rhs.dueDate {
            return (lhs.dueDate ?? .distantFuture) < (rhs.dueDate ?? .distantFuture)
        }
        if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
        return lhs.id < rhs.id
    }
}

enum ReminderMatchResult: Equatable {
    case match(id: String, title: String)
    case ambiguous(titles: [String])
    case notFound
}

enum ReminderDueValidation: Equatable {
    case valid(Date?)
    case invalidISO8601
    case past
}

enum ReminderDuePolicy {
    static func validate(_ value: String?, now: Date) -> ReminderDueValidation {
        guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return .valid(nil)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = formatter.date(from: text)
        if date == nil {
            formatter.formatOptions = [.withInternetDateTime]
            date = formatter.date(from: text)
        }
        guard let date else { return .invalidISO8601 }
        guard date > now else { return .past }
        return .valid(date)
    }
}

enum ReminderMatchPolicy {
    static func resolve(search: String, reminders: [EventKitReminderRecord]) -> ReminderMatchResult {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !term.isEmpty else { return .notFound }

        let exact = reminders.filter { $0.title.lowercased() == term }
        if exact.count == 1, let match = exact.first { return .match(id: match.id, title: match.title) }
        if exact.count > 1 { return .ambiguous(titles: exact.map(\.title).sorted()) }

        let partial = reminders.filter { $0.title.lowercased().contains(term) }
        if partial.count == 1, let match = partial.first { return .match(id: match.id, title: match.title) }
        if partial.count > 1 { return .ambiguous(titles: partial.map(\.title).sorted()) }
        return .notFound
    }
}
