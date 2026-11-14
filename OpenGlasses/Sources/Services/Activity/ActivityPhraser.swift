import Foundation

/// The span a "what have you done…?" question asks about.
enum ActivityWindow: Equatable, Sendable {
    /// Since midnight in the wearer's time zone.
    case today
    /// Midnight to noon in the wearer's time zone (or to now, before noon).
    case thisMorning
    /// Since a moment the wearer named ("since I left").
    case since(Date)
}

/// A scheduled task's next run, as the "what's next" answer needs it. The caller works out the
/// time from the scheduler; this side only phrases it.
struct UpcomingScheduledTask: Equatable, Sendable {
    let name: String
    let dueAt: Date
}

/// Speaks the trail (Plan IW): "what have you done today / this morning / since…?" and "what's
/// next?". Pure — the entries, goals, clock and the wearer's time zone all come in as values.
///
/// A summary is the counts by kind, then the few entries worth hearing in time order, then what is
/// waiting on the wearer — always last, always said, even when the answer is "nothing". It fits the
/// same 35-second ceiling as My Day (`MyDaySpeechPolicy`), giving up entries before it gives up the
/// waiting-on-you line.
struct ActivityPhraser: Sendable {
    let now: Date
    let timeZone: TimeZone

    /// At most this many entries are read out; fewer when the ceiling needs it.
    static let maximumSpokenEntries = 5
    /// "What's next" names at most this many things.
    static let maximumNextItems = 4
    /// Scheduled tasks are mentioned when due within this horizon.
    static let scheduledHorizon: TimeInterval = 24 * 60 * 60

    init(now: Date, timeZone: TimeZone) {
        self.now = now
        self.timeZone = timeZone
    }

    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    // MARK: Windows

    func interval(for window: ActivityWindow) -> DateInterval {
        let startOfDay = calendar.startOfDay(for: now)
        switch window {
        case .today:
            return DateInterval(start: startOfDay, end: max(startOfDay, now))
        case .thisMorning:
            let noon = calendar.date(byAdding: .hour, value: 12, to: startOfDay) ?? startOfDay
            return DateInterval(start: startOfDay, end: max(startOfDay, min(now, noon)))
        case .since(let start):
            return DateInterval(start: min(start, now), end: now)
        }
    }

    func entries(_ entries: [ActivityEntry], in window: ActivityWindow) -> [ActivityEntry] {
        let span = interval(for: window)
        return entries.filter { span.contains($0.at) }.sorted { $0.at < $1.at }
    }

    private func label(for window: ActivityWindow) -> String {
        switch window {
        case .today: return "today"
        case .thisMorning: return "this morning"
        case .since(let start): return "since \(SpokenPhrasing.time(start, calendar: calendar))"
        }
    }

    // MARK: "What have you done?"

    func summary(of allEntries: [ActivityEntry], window: ActivityWindow) -> String {
        let inWindow = entries(allEntries, in: window)
        // Plan LE §3: a held entry the wearer has since answered is no longer waiting on them.
        let waiting = inWindow.filter(\.isAwaitingWearer)
        let finished = inWindow.filter { !$0.isAwaitingWearer }
        let waitingLine = waitingSentence(waiting)
        let when = label(for: window)

        guard !finished.isEmpty else {
            if waiting.isEmpty { return "I haven't done anything \(when), and nothing is waiting on you." }
            return "I haven't done anything else \(when). " + waitingLine
        }

        let pause: String
        if case .since = window { pause = "," } else { pause = "" }
        let opening = SpokenPhrasing.capitalisedFirst(when) + pause + " I "
            + SpokenPhrasing.joined(countClauses(finished)) + "."
        let chosen = spokenEntries(from: finished)

        // Give up entries, most recent pick first, until the whole answer fits; the opening and the
        // waiting-on-you line always stay.
        var count = chosen.count
        while true {
            let picked = Array(chosen.prefix(count)).sorted { $0.at < $1.at }
            var sentences = [opening]
            sentences += picked.map(entrySentence)
            let unsaid = finished.count - picked.count
            if unsaid > 0, !picked.isEmpty {
                sentences.append("And \(SpokenPhrasing.count(unsaid, "more thing")).")
            }
            sentences.append(waitingLine)
            let text = sentences.joined(separator: " ")
            if count == 0 || MyDaySpeechPolicy.estimatedDuration(for: text) <= MyDaySpeechPolicy.maximumDuration {
                return MyDaySpeechPolicy.estimatedDuration(for: text) <= MyDaySpeechPolicy.maximumDuration
                    ? text : MyDaySpeechPolicy.bounded(text)
            }
            count -= 1
        }
    }

    /// "did three things", "ran one scheduled task" — in a fixed order so the opening reads the
    /// same way every time.
    private func countClauses(_ entries: [ActivityEntry]) -> [String] {
        ActivityKind.allCases.compactMap { kind -> String? in
            let n = entries.filter { $0.kind == kind }.count
            guard n > 0 else { return nil }
            switch kind {
            case .action: return "did " + SpokenPhrasing.count(n, "thing")
            case .plannedStep: return "worked through " + SpokenPhrasing.count(n, "planned step")
            case .scheduledRun: return "ran " + SpokenPhrasing.count(n, "scheduled task")
            case .toldYou: return "passed on " + SpokenPhrasing.count(n, "update")
            case .held: return "held " + SpokenPhrasing.count(n, "thing") + " for you"
            case .refused: return "stopped " + SpokenPhrasing.count(n, "action") + " I wasn't allowed to take"
            }
        }
    }

    /// The entries worth hearing: anything that went wrong or may not have gone through first,
    /// then actions and plan steps, then scheduled runs and updates, then refusals; the latest of
    /// each first. At most `maximumSpokenEntries`, in priority order (spoken in time order).
    private func spokenEntries(from entries: [ActivityEntry]) -> [ActivityEntry] {
        func rank(_ entry: ActivityEntry) -> Int {
            if entry.outcome == .failed || entry.outcome == .uncertain { return 0 }
            switch entry.kind {
            case .action, .plannedStep: return 1
            case .scheduledRun, .toldYou, .held: return 2
            case .refused: return 3
            }
        }
        return entries
            .sorted { (rank($0), $1.at) < (rank($1), $0.at) }
            .prefix(Self.maximumSpokenEntries)
            .map { $0 }
    }

    private func entrySentence(_ entry: ActivityEntry) -> String {
        switch entry.outcome {
        case .failed: return entry.title + ", but it didn't work."
        case .uncertain: return entry.title + ", but I couldn't confirm it went through."
        case .done: return SpokenPhrasing.sentence(entry.title)
        case .waitingOnYou:
            switch entry.resolution {
            case .approved: return entry.title + ": you said yes."
            case .declined: return entry.title + ": you said no."
            case .expired: return entry.title + ": it lapsed."
            case nil: return SpokenPhrasing.sentence(entry.title)
            }
        }
    }

    /// "Nothing is waiting on you." / "One thing is waiting on you: …" — explicit either way.
    func waitingSentence(_ waiting: [ActivityEntry]) -> String {
        let ordered = waiting.sorted { $0.at < $1.at }
        switch ordered.count {
        case 0:
            return "Nothing is waiting on you."
        case 1:
            return "One thing is waiting on you: \(SpokenPhrasing.listCased(ordered[0].title))."
        case 2:
            return "Two things are waiting on you: "
                + SpokenPhrasing.joined(ordered.map { SpokenPhrasing.listCased($0.title) }) + "."
        default:
            let first = ordered.prefix(2).map { SpokenPhrasing.listCased($0.title) }
            return SpokenPhrasing.capitalisedFirst(SpokenPhrasing.count(ordered.count, "thing"))
                + " are waiting on you, starting with " + SpokenPhrasing.joined(first) + "."
        }
    }

    // MARK: "What's next?"

    /// Open goal steps and scheduled tasks due within a day, soonest first (an undated goal step
    /// after the dated ones), then anything waiting on the wearer, last and explicit.
    func whatsNext(goals: [Goal], scheduled: [UpcomingScheduledTask], entries: [ActivityEntry]) -> String {
        struct Item { let due: Date?; let order: Int; let sentence: String }
        var items: [Item] = []
        var order = 0

        for goal in goals {
            guard let step = GoalAdvancePolicy.nextStep(in: goal) else { continue }
            let due = step.dueAt ?? goal.dueAt
            let when = due.map { ", due \(SpokenPhrasing.day($0, now: now, calendar: calendar))" } ?? ""
            items.append(Item(due: due, order: order,
                              sentence: "\(goal.title): \(SpokenPhrasing.listCased(step.title))\(when)."))
            order += 1
        }
        for task in scheduled where task.dueAt >= now && task.dueAt <= now.addingTimeInterval(Self.scheduledHorizon) {
            items.append(Item(due: task.dueAt, order: order,
                              sentence: "I'll run \(task.name) "
                                + "\(SpokenPhrasing.dayAndTime(task.dueAt, now: now, calendar: calendar))."))
            order += 1
        }
        items.sort { lhs, rhs in
            switch (lhs.due, rhs.due) {
            case let (l?, r?): return l == r ? lhs.order < rhs.order : l < r
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return lhs.order < rhs.order
            }
        }

        let waiting = entries.filter(\.isAwaitingWearer)
        guard !items.isEmpty else {
            if waiting.isEmpty { return "Nothing's coming up, and nothing is waiting on you." }
            return "Nothing else is coming up. " + waitingSentence(waiting)
        }

        var shown = Array(items.prefix(Self.maximumNextItems))
        while true {
            var sentences = ["Here's what's next."] + shown.map(\.sentence)
            let unsaid = items.count - shown.count
            if unsaid > 0 {
                sentences.append("And \(SpokenPhrasing.count(unsaid, "more thing")).")
            }
            if !waiting.isEmpty { sentences.append(waitingSentence(waiting)) }
            let text = sentences.joined(separator: " ")
            if shown.count <= 1 || MyDaySpeechPolicy.estimatedDuration(for: text) <= MyDaySpeechPolicy.maximumDuration {
                return MyDaySpeechPolicy.estimatedDuration(for: text) <= MyDaySpeechPolicy.maximumDuration
                    ? text : MyDaySpeechPolicy.bounded(text)
            }
            shown.removeLast()
        }
    }
}
