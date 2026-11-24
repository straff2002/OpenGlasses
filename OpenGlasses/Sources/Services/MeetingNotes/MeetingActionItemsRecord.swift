import Foundation

/// A saved meeting's action items, and which of them the wearer has added to Reminders (Plan MX
/// P5). Kept with the saved note, as one JSON string under `noteKey`, so "Added" survives a
/// relaunch and an item is added once. Pure.
struct MeetingActionItemsRecord: Codable, Equatable, Sendable {

    struct Entry: Codable, Equatable, Sendable {
        var item: MeetingActionItem
        var addedToReminders: Bool
    }

    /// The saved note's keys: the meeting id, these items, and whose notes they are.
    static let noteKey = "actionItems"
    static let meetingIdKey = "meetingId"
    static let sourceKey = "notesSource"

    var entries: [Entry]

    init(items: [MeetingActionItem]) {
        entries = items.map { Entry(item: $0, addedToReminders: false) }
    }

    init(entries: [Entry]) {
        self.entries = entries
    }

    var isEmpty: Bool { entries.isEmpty }

    /// Whether the item at `index` can still be added.
    func canAdd(_ index: Int) -> Bool {
        entries.indices.contains(index) && !entries[index].addedToReminders
    }

    /// Mark the item at `index` added. False when it already was, or there is none.
    @discardableResult
    mutating func markAdded(_ index: Int) -> Bool {
        guard canAdd(index) else { return false }
        entries[index].addedToReminders = true
        return true
    }

    /// The items notes written later bring, with what was already added kept: an added item the
    /// new notes still have (same task) stays added, and one they dropped stays listed as added,
    /// since its reminder exists.
    func replacingItems(with items: [MeetingActionItem]) -> MeetingActionItemsRecord {
        let added = entries.filter(\.addedToReminders)
        let addedTasks = Set(added.map { $0.item.task.lowercased() })
        var next = items.map { Entry(item: $0, addedToReminders: addedTasks.contains($0.task.lowercased())) }
        let kept = Set(next.filter(\.addedToReminders).map { $0.item.task.lowercased() })
        next.append(contentsOf: added.filter { !kept.contains($0.item.task.lowercased()) })
        return MeetingActionItemsRecord(entries: next)
    }

    func encoded() -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode(_ string: String?) -> MeetingActionItemsRecord? {
        guard let data = string?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(MeetingActionItemsRecord.self, from: data)
    }
}

/// One reminder made from one action item (Plan MX P5). The title is the task; the owner and the
/// due go in the reminder's notes as they were said. A due becomes the reminder's date only when
/// it reads as an exact date and time (`ReminderDuePolicy.parse`, the Reminders tool's parser) in
/// the future: "Friday" said in a meeting last week is not a date the phone can be sure of.
struct MeetingReminderDraft: Equatable, Sendable {
    let title: String
    let notes: String?
    let dueDate: Date?

    static func make(item: MeetingActionItem, meetingTitle: String?, now: Date) -> MeetingReminderDraft {
        var lines: [String] = []
        if let owner = item.owner, !owner.isEmpty {
            lines.append(String(localized: "Owner: \(owner)"))
        }
        var dueDate: Date?
        if let due = item.due, !due.isEmpty {
            if let parsed = ReminderDuePolicy.parse(due), parsed > now {
                dueDate = parsed
            } else {
                lines.append(String(localized: "Due: \(due)"))
            }
        }
        if let meetingTitle, !meetingTitle.isEmpty {
            lines.append(String(localized: "From the meeting: \(meetingTitle)"))
        }
        return MeetingReminderDraft(title: item.task, notes: lines.isEmpty ? nil : lines.joined(separator: "\n"),
                                    dueDate: dueDate)
    }
}
