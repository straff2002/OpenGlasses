import Foundation

// MARK: - The everyday sources, as open loops (Plan LE P1)
//
// Pure mappings from each store's own records to `OpenLoop`, one per row of §2's table. Each one
// applies its row's "counts when"; the collector applies the rules every source shares. The
// readers (`OpenLoopReaders.swift`) are the impure edge that hands the records in, fresh.

/// Reminders: incomplete, due today or overdue.
enum OpenLoopReminders {

    static func id(for reminderID: String) -> String { "reminder:\(reminderID)" }

    /// A reminder with only a date is due at the end of that day: due later today while today
    /// lasts, overdue once the day is gone. One with a time is due at that time.
    static func dueAt(_ reminder: MyDayReminder, calendar: Calendar) -> Date? {
        guard let due = reminder.dueDate else { return nil }
        guard !reminder.hasTime else { return due }
        let start = calendar.startOfDay(for: due)
        return calendar.date(byAdding: DateComponents(day: 1, second: -1), to: start) ?? due
    }

    static func loops(_ reminders: [MyDayReminder], now: Date, calendar: Calendar) -> [OpenLoop] {
        let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
            ?? now.addingTimeInterval(24 * 60 * 60)
        return reminders.compactMap { reminder in
            guard let due = dueAt(reminder, calendar: calendar), due < startOfTomorrow else { return nil }
            return OpenLoop(id: id(for: reminder.id), source: .reminder, title: reminder.title,
                            since: due, dueAt: due, action: .complete(reminderID: reminder.id))
        }
    }
}

/// Goal steps: the next step of an active goal, due today or overdue. A step whose action sets a
/// reminder stands for that reminder (rule 3): the reminder is matched by its text, because the
/// step keeps the words it asked for, not the reminder Reminders made of them.
enum OpenLoopGoalSteps {

    static func id(goalID: UUID, stepID: UUID) -> String {
        "step:\(goalID.uuidString.lowercased()):\(stepID.uuidString.lowercased())"
    }

    static func loops(_ goals: [Goal], reminders: [MyDayReminder], now: Date,
                      calendar: Calendar) -> [OpenLoop] {
        let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
            ?? now.addingTimeInterval(24 * 60 * 60)
        return goals.compactMap { goal in
            guard goal.state == .active, let step = GoalAdvancePolicy.nextStep(in: goal),
                  let due = step.dueAt ?? goal.dueAt, due < startOfTomorrow else { return nil }
            return OpenLoop(id: id(goalID: goal.id, stepID: step.id), source: .goalStep, title: step.title,
                            subject: goal.title, since: goal.createdAt, dueAt: due,
                            action: .stepDone(goalID: goal.id, stepID: step.id),
                            covers: covered(by: step, in: reminders))
        }
    }

    /// The reminder loops a step's reminder action made, by the reminder's text.
    static func covered(by step: GoalStep, in reminders: [MyDayReminder]) -> Set<String> {
        guard case .reminder(let text, _) = step.suggestedAction else { return [] }
        let wanted = normalised(text)
        guard !wanted.isEmpty else { return [] }
        return Set(reminders.filter { normalised($0.title) == wanted }.map { OpenLoopReminders.id(for: $0.id) })
    }

    private static func normalised(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

/// The digest: `actionable` or higher, never seen, not dismissed. Calendar, reminder and goal
/// items have their own rows (as on My Day, `MyDayDigestPolicy`), and a location transition only
/// mattered at the moment it happened. An agent result in the digest stands for the same result
/// still in the queue (rule 3), so it is said once.
enum OpenLoopDigest {

    static func id(for itemID: String) -> String { "digest:\(itemID)" }

    static let excludedSources: Set<DigestSource> = [.calendar, .reminder, .goal, .geofence]

    static func loops(_ items: [DigestItem], now: Date) -> [OpenLoop] {
        // `compose` drops what is retired or stale and collapses repeats, as the glance does.
        DigestComposer.compose(items, now: now, topN: items.count).items.compactMap { item in
            guard item.seenCount == 0, !excludedSources.contains(item.source),
                  DigestRanker.tier(of: item, now: now) <= .actionable else { return nil }
            let covers: Set<String> = item.source == .agent
                ? Set([item.threadKey].compactMap { $0 }.map(OpenLoopAgentResults.id(for:))) : []
            return OpenLoop(id: id(for: item.id), source: .digest, title: OpenLoopText.lead(item.title),
                            since: item.createdAt, action: .open(.digestItem(id: item.id)), covers: covers)
        }
    }
}

/// Agent results: queued and not delivered, and not yet stale by their own priority.
enum OpenLoopAgentResults {

    static func id(for notificationID: String) -> String { "agent:\(notificationID)" }

    static func loops(_ pending: [AgentNotificationQueue.QueuedNotification], now: Date) -> [OpenLoop] {
        pending.compactMap { notification in
            guard !notification.delivered,
                  !notification.priority.isStale(age: now.timeIntervalSince(notification.createdAt)) else {
                return nil
            }
            return OpenLoop(id: id(for: notification.id), source: .agentResult,
                            title: OpenLoopText.lead(notification.message), since: notification.createdAt,
                            action: .open(.agentResult(id: notification.id)))
        }
    }
}

/// Shortening for titles that are someone's sentence rather than a name.
enum OpenLoopText {
    static let titleLength = 80

    /// The first line, at most `titleLength` characters.
    static func lead(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return ActivityEntry.clamp(line, to: titleLength)
    }
}
