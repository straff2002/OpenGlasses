import Foundation

/// "What have you done today?" and "what's next?" (Plan IW P1).
///
/// Reads the activity trail — the assistant's own actions, never a transcript and never a read —
/// and answers through `ActivityPhraser`: counts by kind, a few entries in time order, then what is
/// waiting on the wearer, inside 35 seconds of speech. "What's next" merges the next step of each
/// goal, scheduled tasks due within a day and anything waiting on the wearer. Reads only.
@MainActor
final class ActivityTool: NativeTool {
    let name = "activity"
    let description = """
    What the assistant has done for the wearer, what is coming up, and what is still waiting on \
    them. Use it for "what have you done today?", "what did you do this morning?", "what have you \
    done since I left?", "what's next?", and "what's waiting on me?", "what do I still need to do \
    today?", "anything I haven't answered?". Actions: 'today', 'this_morning', 'since' (pass \
    'time': ISO 8601, or HH:mm for today), 'next' (goal steps, scheduled tasks due within a day, \
    and anything waiting on the wearer), and 'waiting' (everything from today still waiting on the \
    wearer: held approvals, reminders due or overdue, goal steps, unheard updates and results, and \
    with Field Assist a job's unsent report, held close, unsent parts, put-off tasks and unanswered \
    hand-offs). It lists the assistant's own actions — things added, sent, held back or refused — \
    never what was said or looked up. It approves, sends and completes nothing. Read the answer \
    back as given.
    """

    var parametersSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "action": ["type": "string", "enum": ["today", "this_morning", "since", "next", "waiting"]],
                "time": ["type": "string",
                         "description": "since: when from — ISO 8601, or HH:mm meaning today."],
            ],
            "required": ["action"],
        ]
    }

    private let activity: @MainActor () -> ActivityStore
    private let goals: @MainActor () -> GoalStore
    var scheduledTasks: () -> [AgentScheduler.ScheduledTask] = { AgentScheduler.savedTasks() }
    var agentModeEnabled: () -> Bool = { Config.agentModeEnabled }
    var clock: () -> Date = Date.init
    var timeZone: () -> TimeZone = { TimeZone.current }
    /// The Evening Check-in, for `waiting` (Plan LE P1). The registry wires it.
    var checkIn: @MainActor () -> EveningCheckInService? = { nil }

    init(activity: @escaping @MainActor () -> ActivityStore = { ActivityStore.shared },
         goals: @escaping @MainActor () -> GoalStore = { GoalStore.shared }) {
        self.activity = activity
        self.goals = goals
    }

    func execute(args: [String: Any]) async throws -> String {
        let action = (args["action"] as? String ?? "today").trimmingCharacters(in: .whitespaces).lowercased()
        let now = clock()
        let phraser = ActivityPhraser(now: now, timeZone: timeZone())
        let entries = activity().entries

        switch action {
        case "today":
            return phraser.summary(of: entries, window: .today)
        case "this_morning", "morning":
            return phraser.summary(of: entries, window: .thisMorning)
        case "since":
            guard let raw = args["time"] as? String,
                  let start = Self.start(raw, now: now, calendar: phraser.calendar) else {
                return "Since when? Give me a time, like 09:30."
            }
            return phraser.summary(of: entries, window: .since(start))
        case "next":
            let recentWaiting = entries.filter {
                $0.isAwaitingWearer && now.timeIntervalSince($0.at) <= ActivityPhraser.scheduledHorizon
            }
            return phraser.whatsNext(goals: goals().goals.filter { $0.state == .active },
                                     scheduled: upcoming(now: now, calendar: phraser.calendar),
                                     entries: recentWaiting)
        case "waiting", "waiting_on_me":
            guard let checkIn = checkIn() else {
                return String(localized: "I couldn't check what's waiting on you just now.",
                              comment: "Spoken: the 'what's waiting on me?' answer could not be put together.")
            }
            return await checkIn.askedText(now: now)
        default:
            return "Unknown action '\(action)'. Use: today, this_morning, since, next or waiting."
        }
    }

    /// Scheduled tasks and when each next runs. Only while Agent Mode is on: with it off the
    /// scheduler runs nothing, and saying otherwise would be a promise it cannot keep.
    private func upcoming(now: Date, calendar: Calendar) -> [UpcomingScheduledTask] {
        guard agentModeEnabled() else { return [] }
        return scheduledTasks().compactMap { task in
            ScheduleDuePolicy.nextDue(task: task, now: now, calendar: calendar)
                .map { UpcomingScheduledTask(name: task.name, dueAt: $0) }
        }
    }

    /// An ISO 8601 moment, or `HH:mm` today in the wearer's zone — yesterday's, when that time
    /// today has not come yet.
    static func start(_ raw: String, now: Date, calendar: Calendar) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let date = RecordJSONCodec.parse(text) { return date }
        let parts = text.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0..<24).contains(hour), (0..<60).contains(minute),
              let today = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) else {
            return nil
        }
        return today <= now ? today : calendar.date(byAdding: .day, value: -1, to: today)
    }
}
