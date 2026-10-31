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
            "search": ["type": "string", "description": "Title to resolve for complete when no stable ID is available."],
            "offset": ["type": "integer", "description": "For list: how many reminders to skip, when the previous reply said there are more."]
        ],
        "required": ["action"]
    ]

    private let eventStore: EventKitDayStore
    private let now: () -> Date
    /// The wearer's words for this call's turn, when there are any to check against.
    private let utterance: () -> String?

    @MainActor
    convenience init() {
        self.init(eventStore: EventKitDayStore())
    }

    @MainActor
    init(eventStore: EventKitDayStore, now: @escaping () -> Date = Date.init,
         utterance: @escaping () -> String? = RelativeTimeGuard.utteranceForCurrentCall) {
        self.eventStore = eventStore
        self.now = now
        self.utterance = utterance
    }

    func execute(args: [String: Any]) async throws -> String {
        guard try await eventStore.requestRemindersAccess() else {
            return "Reminders access denied. Please enable it in iPhone Settings > Privacy & Security > Reminders."
        }

        switch (args["action"] as? String ?? "create").lowercased() {
        case "create", "add", "set": return try createReminder(args: args)
        case "list", "show": return await listReminders(offset: args["offset"] as? Int ?? 0)
        case "complete", "done", "finish": return await completeReminder(args: args)
        default: return "Unknown action. Use: create, list, or complete."
        }
    }

    private func createReminder(args: [String: Any]) throws -> String {
        guard let title = (args["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return "No reminder text provided."
        }

        let currentTime = now()
        let due: Date?
        // "In 15 minutes" in the wearer's own words beats the model's arithmetic (see
        // `RelativeTimeGuard`); otherwise the model's absolute value is validated as before.
        switch ReminderDueResolution.resolve(modelDueAt: args["due_at"] as? String,
                                             utterance: utterance(), now: currentTime) {
        case .parsed(let date, let disagreement):
            RelativeTimeGuard.logOverride(tool: name, disagreement)
            due = date
        case .model(let dueAt):
            switch ReminderDuePolicy.validate(dueAt, now: currentTime) {
            case .valid(let date): due = date
            case .invalidISO8601:
                return "The due_at value must be an absolute ISO-8601 date and time."
            case .past:
                return "That due date is in the past. Choose a future date or time."
            }
        }

        try eventStore.saveReminder(title: title, dueDate: due, hasTime: due != nil)
        var response = "Reminder set: '\(title)'"
        if let due {
            response += " due \(formatDueDate(due, hasTime: true))"
            response += ". You'll get a notification at that time"
        }
        return response + "."
    }

    private func listReminders(offset: Int) async -> String {
        let reminders = await eventStore.incompleteReminders().sorted(by: Self.reminderOrder)
        let descriptions = reminders.map { reminder -> String in
            guard let due = reminder.dueDate else { return reminder.title }
            return "\(reminder.title) (due \(formatDueDate(due, hasTime: reminder.hasTime)))"
        }
        return ReminderListPolicy.reply(descriptions, offset: offset)
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
        guard let date = parse(text) else { return .invalidISO8601 }
        guard date > now else { return .past }
        return .valid(date)
    }

    /// An absolute ISO-8601 date and time, with or without fractional seconds.
    static func parse(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

enum ReminderListPolicy {
    /// Titles in one reply. It goes to the model, which says what was asked for, so this bounds
    /// the request rather than what is spoken; anything past it is reached with `offset`.
    static let pageSize = 50

    static func reply(_ descriptions: [String], offset: Int) -> String {
        let total = descriptions.count
        guard total > 0 else { return "No incomplete reminders." }
        let start = max(0, offset)
        guard start < total else { return "There are only \(total) incomplete reminders." }
        let end = min(start + pageSize, total)
        let lead = start == 0
            ? "\(total) reminder\(total == 1 ? "" : "s")"
            : "Reminders \(start + 1) to \(end) of \(total)"
        var result = "\(lead): \(descriptions[start..<end].joined(separator: ". "))."
        if end < total { result += " Plus \(total - end) more: list again with offset \(end)." }
        return result
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
