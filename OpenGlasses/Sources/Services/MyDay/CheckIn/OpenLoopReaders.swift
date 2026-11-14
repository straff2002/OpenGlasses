import Foundation

// MARK: - The readers (Plan LE P1)
//
// One `OpenLoopSourceReading` per store, each reading fresh when the check-in asks and handing its
// records to the pure mapping for its row. Every store is reached through a closure, so a test
// gives each reader a fake and nothing here touches a `.shared` service by itself. A store that
// cannot be read reports `unavailable` — never an empty list in its place (§1).

/// Approvals, over the activity trail. Nil from `entries` means the trail could not be opened
/// (protected data before the first unlock).
@MainActor
final class ApprovalLoopReader: OpenLoopSourceReading {
    let sources: [OpenLoopSource] = [.approval]
    private let entries: @MainActor () -> [ActivityEntry]?

    init(entries: @escaping @MainActor () -> [ActivityEntry]?) {
        self.entries = entries
    }

    /// The production reader, over `ActivityStore`.
    convenience init(store: @escaping @MainActor () -> ActivityStore) {
        self.init(entries: { let trail = store(); return trail.isUnreadable ? nil : trail.entries })
    }

    func readOpenLoops(now: Date, calendar: Calendar) async -> OpenLoopReading {
        guard let entries = entries() else { return .unavailable }
        return .read(OpenLoopApprovals.loops(from: entries, now: now, calendar: calendar))
    }
}

/// Reminders, through My Day's own reminders source (`RemindersDaySource`, `EventKitDayStore` in
/// the app) rather than a second EventKit path. Reminders switched off in My Day's sources are
/// not the check-in's to read either: that is the wearer's choice, not a failure.
@MainActor
final class ReminderLoopReader: OpenLoopSourceReading {
    let sources: [OpenLoopSource] = [.reminder]
    private let source: any RemindersDaySource
    private let included: @MainActor () -> Bool

    init(source: any RemindersDaySource,
         included: @escaping @MainActor () -> Bool = { MyDaySourceSelection.current.reminders }) {
        self.source = source
        self.included = included
    }

    func readOpenLoops(now: Date, calendar: Calendar) async -> OpenLoopReading {
        guard included() else { return .read([]) }
        let load = await source.loadReminders()
        guard load.state.availability == .available else { return .unavailable }
        return .read(OpenLoopReminders.loops(load.value, now: now, calendar: calendar))
    }
}

/// Goal steps, over the wearer's goals. Nil from `goals` means the goals file could not be read.
/// The reminders source, when there is one, is read only when a step's action is a reminder, to
/// find the reminder that step stands for (rule 3).
@MainActor
final class GoalStepLoopReader: OpenLoopSourceReading {
    let sources: [OpenLoopSource] = [.goalStep]
    private let goals: @MainActor () -> [Goal]?
    private let reminders: (any RemindersDaySource)?
    private let included: @MainActor () -> Bool

    init(goals: @escaping @MainActor () -> [Goal]?, reminders: (any RemindersDaySource)? = nil,
         included: @escaping @MainActor () -> Bool = { MyDaySourceSelection.current.goals }) {
        self.goals = goals
        self.reminders = reminders
        self.included = included
    }

    /// The production reader, over `GoalStore`.
    convenience init(store: @escaping @MainActor () -> GoalStore, reminders: (any RemindersDaySource)?) {
        self.init(goals: { let goals = store(); return goals.isUnreadable ? nil : goals.goals },
                  reminders: reminders)
    }

    func readOpenLoops(now: Date, calendar: Calendar) async -> OpenLoopReading {
        guard included() else { return .read([]) }
        guard let goals = goals() else { return .unavailable }
        let wantsReminders = goals.contains { goal in
            guard let step = GoalAdvancePolicy.nextStep(in: goal) else { return false }
            if case .reminder = step.suggestedAction { return true }
            return false
        }
        var reminderList: [MyDayReminder] = []
        if wantsReminders, let reminders {
            let load = await reminders.loadReminders()
            if load.state.availability == .available { reminderList = load.value }
        }
        return .read(OpenLoopGoalSteps.loops(goals, reminders: reminderList, now: now, calendar: calendar))
    }
}

/// The notification digest's items.
@MainActor
final class DigestLoopReader: OpenLoopSourceReading {
    let sources: [OpenLoopSource] = [.digest]
    private let items: @MainActor () -> [DigestItem]

    init(items: @escaping @MainActor () -> [DigestItem]) {
        self.items = items
    }

    func readOpenLoops(now: Date, calendar: Calendar) async -> OpenLoopReading {
        .read(OpenLoopDigest.loops(items(), now: now))
    }
}

/// Agent results queued and not delivered (`AgentNotificationQueue.pendingNotifications`).
@MainActor
final class AgentResultLoopReader: OpenLoopSourceReading {
    let sources: [OpenLoopSource] = [.agentResult]
    private let pending: @MainActor () -> [AgentNotificationQueue.QueuedNotification]

    init(pending: @escaping @MainActor () -> [AgentNotificationQueue.QueuedNotification]) {
        self.pending = pending
    }

    func readOpenLoops(now: Date, calendar: Calendar) async -> OpenLoopReading {
        .read(OpenLoopAgentResults.loops(pending(), now: now))
    }
}

/// The five §10 rows, over the field sessions and the send queue together. With Field Assist off
/// there is no job to read and the rows are empty, not unreadable. Nil from `facts` means the
/// job records could not be gathered.
@MainActor
final class JobLoopReader: OpenLoopSourceReading {
    let sources: [OpenLoopSource] = [.jobReport, .jobCloseHeld, .partsRequest, .deferredTask, .expertOrEscalation]
    private let fieldAssistOn: @MainActor () -> Bool
    private let facts: @MainActor () -> OpenLoopJobFacts?

    init(fieldAssistOn: @escaping @MainActor () -> Bool = { Config.fieldAssistActive },
         facts: @escaping @MainActor () -> OpenLoopJobFacts?) {
        self.fieldAssistOn = fieldAssistOn
        self.facts = facts
    }

    func readOpenLoops(now: Date, calendar: Calendar) async -> OpenLoopReading {
        guard fieldAssistOn() else { return .read([]) }
        guard let facts = facts() else { return .unavailable }
        return .read(OpenLoopJobLoops.loops(facts, now: now, calendar: calendar))
    }

    /// The production facts: the open job and the history from `FieldSessionService`, each
    /// finished job's report state off its own log (today's only — the rows read no others), and
    /// the send queue — what `JobDayFeed` reads, read here at the moment the check-in asks.
    static func facts(sessions: FieldSessionService, queue: [QueuedSend], now: Date,
                      calendar: Calendar) -> OpenLoopJobFacts {
        let startOfToday = calendar.startOfDay(for: now)
        var gathered: [OpenLoopJobSession] = []
        for session in sessions.history where session.id != sessions.activeSession?.id {
            let today = (session.endedAt ?? .distantPast) >= startOfToday
            gathered.append(OpenLoopJobSession(
                session: session,
                reportSent: today ? sessions.reportWasSent(sessionId: session.id) : true))
        }
        if let open = sessions.activeSession {
            gathered.append(OpenLoopJobSession(
                session: open,
                reportSent: open.endedAt == nil ? false : sessions.reportWasSent(sessionId: open.id)))
        }
        return OpenLoopJobFacts(sessions: gathered, queue: queue,
                                signOffRequired: sessions.customerSignOffRequired)
    }
}
