import Foundation

/// What "Do it" on a goal step does (Plan IW P2), worked out from the step's suggested action.
///
/// A step can only ever suggest one of the six closed `StepAction` kinds, and each maps to the
/// tool it names with the arguments that tool already takes — so "Do it" is exactly the call the
/// wearer could have asked for by voice, and it goes through the router's authorization ladder
/// (confirmation, safety rules, the presence ceiling, Agent Mode) like any other. Nothing here
/// runs anything: the screen hands the result to the router, or to a drafting turn.
enum StepActionRun: Equatable {
    /// One call to a registered tool.
    case tool(name: String, arguments: [String: StepActionArgument])
    /// A drafting turn: the request goes to the assistant as the wearer's own message, and anything
    /// it then sends goes through its own tool and confirmation.
    case draft(request: String)
    /// A question for the wearer — there is nothing for the assistant to do.
    case nothing

    /// The run for `action`, on `step` of `goal`. Dates are written in `calendar`'s time zone,
    /// which is how the reminder and calendar tools read them.
    static func run(for action: StepAction, step: GoalStep, goal: Goal, calendar: Calendar) -> StepActionRun {
        switch action {
        case .reminder(let text, let at):
            var arguments: [String: StepActionArgument] = ["action": .text("create"), "title": .text(text)]
            if let at { arguments["due_at"] = .text(isoMoment(at, calendar: calendar)) }
            return .tool(name: "reminder", arguments: arguments)
        case .calendarHold(let title, let at, let minutes):
            return .tool(name: "calendar", arguments: [
                "action": .text("create"), "title": .text(title),
                "date": .text(dayString(at, calendar: calendar)),
                "start_time": .text(timeString(at, calendar: calendar)),
                "duration_minutes": .number(minutes),
            ])
        case .search(let query):
            return .tool(name: "web_search", arguments: ["query": .text(query)])
        case .scheduledCheck(let prompt, let every):
            return .tool(name: "manage_schedule", arguments: [
                "action": .text("create"), "task_name": .text(step.title), "task_prompt": .text(prompt),
                // `manage_schedule` reads 0 as once a day.
                "interval_minutes": .number(every == .daily ? 0 : 7 * 24 * 60),
                // No `speak_result`: like any new task, it starts silent and its results arrive
                // as a notification (`ScheduledTask.speakResultDefault`).
            ])
        case .draft(let kind, let prompt):
            return .draft(request: "Draft a \(kind.rawValue) for my goal \u{201C}\(goal.title)\u{201D}, "
                          + "for the step \u{201C}\(step.title)\u{201D}: \(prompt)")
        case .ask:
            return .nothing
        }
    }

    /// "Add a reminder", "Search the web" — what the button says it will do.
    static func buttonTitle(for action: StepAction) -> String {
        switch action {
        case .reminder: return String(localized: "Set the reminder", comment: "Goals screen: run a step's suggested reminder.")
        case .calendarHold: return String(localized: "Hold the time", comment: "Goals screen: run a step's suggested calendar hold.")
        case .search: return String(localized: "Search for it", comment: "Goals screen: run a step's suggested search.")
        case .draft: return String(localized: "Draft it", comment: "Goals screen: run a step's suggested draft.")
        case .scheduledCheck: return String(localized: "Set up the check", comment: "Goals screen: run a step's suggested scheduled check.")
        case .ask: return String(localized: "Do it", comment: "Goals screen: a step's suggested action.")
        }
    }

    // MARK: Pieces

    private static func isoMoment(_ date: Date, calendar: Calendar) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = calendar.timeZone
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func dayString(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 1, parts.day ?? 1)
    }

    private static func timeString(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
}

/// One argument value of a step's tool call — a closed set, so a run can be compared in a test and
/// never carries anything a tool's schema does not take.
enum StepActionArgument: Equatable {
    case text(String)
    case number(Int)
    case flag(Bool)

    var rawValue: Any {
        switch self {
        case .text(let text): return text
        case .number(let number): return number
        case .flag(let flag): return flag
        }
    }
}

extension Dictionary where Key == String, Value == StepActionArgument {
    /// The arguments as the router takes them.
    var rawValues: [String: Any] { mapValues(\.rawValue) }
}
