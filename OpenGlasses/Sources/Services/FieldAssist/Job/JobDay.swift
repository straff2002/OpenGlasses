import Foundation

// The job-day card and the day view behind it (Plan HB), decided without SwiftUI.
//
// With Field Assist on, the home screen shows the technician's day whether or not My Day is on:
// today's jobs in time order, then the job admin still owed, then — only when My Day is on and
// placed — the personal items. Everything here is a pure function of facts gathered elsewhere
// (`JobDayFeed`), so the order, the scoping, the empty day and the summary line are table tests.

/// Where a row of the day goes when tapped.
enum JobDayDestination: Hashable {
    /// The open job's own screen — the Jobs tab.
    case openJob
    /// A job ahead: its details, its brief and Start.
    case upcomingJob(id: String)
    /// A finished job's page: its record, Send report, sign-off and its debriefs.
    case pastJob(sessionId: String)
    /// A report in the send queue: its composer (for a failed one, a retry).
    case send(queuedId: String)
}

/// One field session, as the day needs it. Gathered from `FieldSessionService`; `reportSent` comes
/// off the session's own log on disk, which is why the feed gathers it once per change rather than
/// a view reading it per frame.
struct JobDaySession: Equatable {
    let id: String
    let jobReference: String?
    let customer: String?
    let siteHeadline: String?
    let startedAt: Date
    let endedAt: Date?
    let isPaused: Bool
    let cancelled: Bool
    var reportSent = false
    var signedOff = false
    /// Parts requests base has not answered yet.
    var openPartsRequests = 0

    var isOpen: Bool { endedAt == nil && !cancelled }

    /// "Job 1005", or "No job number" — never invented, never reformatted.
    var label: String { Self.label(reference: jobReference) }

    static func label(reference: String?) -> String {
        reference.flatMap { $0.isEmpty ? nil : "Job \($0)" } ?? JobTabModel.noJobNumber
    }
}

/// A debrief taken and not yet saved or scrapped.
struct JobDayDebrief: Equatable {
    let sessionId: String
    let label: String
}

/// Everything the day is composed from.
struct JobDayInputs {
    var now: Date
    var calendar: Calendar = .current
    var upcoming: [UpcomingJob] = []
    /// The open session and the ones finished recently; the composer scopes them itself.
    var sessions: [JobDaySession] = []
    var queue: [QueuedSend] = []
    var debrief: JobDayDebrief?
    /// Whether the organisation requires a customer sign-off before a report goes.
    var signOffRequired = false
    /// My Day's items, or nil when the personal part is not shown (`HomeDayCard`).
    var personal: [MyDayItem]?
    /// "10:30". Injected so tests do not depend on the simulator's locale.
    var timeText: (Date) -> String = { $0.formatted(date: .omitted, time: .shortened) }
    /// "Thu 9:00" — a time on another day.
    var dayTimeText: (Date) -> String = {
        $0.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}

/// The composed day.
struct JobDay: Equatable {

    struct Job: Identifiable, Equatable {
        enum Status: Equatable {
            case scheduled
            /// Scheduled on an earlier day and never started — kept rather than dropped.
            case overdue
            case inProgress
            case paused
            case done

            var label: String {
                switch self {
                case .scheduled: return "Scheduled"
                case .overdue: return "Overdue"
                case .inProgress: return "In progress"
                case .paused: return "Paused"
                case .done: return "Done"
                }
            }

            var isOpen: Bool { self == .inProgress || self == .paused }
            var isAhead: Bool { self == .scheduled || self == .overdue }
        }

        let id: String
        let time: Date?
        let timeText: String
        let title: String
        let site: String?
        /// The name the summary line uses: the customer when known, otherwise the title.
        let shortName: String
        let status: Status
        let destination: JobDayDestination

        var spoken: String {
            [timeText.isEmpty ? nil : timeText, title, site, status.label]
                .compactMap { $0 }.joined(separator: ", ")
        }
    }

    struct Todo: Identifiable, Equatable {
        /// Declared in the order the strip shows them.
        enum Kind: Int, Comparable, CaseIterable {
            case debrief
            case reportFailed
            case reportStaged
            case reportNotSent
            case signOff
            case parts

            static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }

            var symbol: String {
                switch self {
                case .debrief: return "text.bubble"
                case .reportFailed: return "exclamationmark.triangle"
                case .reportStaged: return "paperplane"
                case .reportNotSent: return "doc.text"
                case .signOff: return "signature"
                case .parts: return "shippingbox"
                }
            }

            var isReport: Bool { self == .reportFailed || self == .reportStaged || self == .reportNotSent }

            /// "1 report to send" — the summary's phrase when every to-do is this kind.
            func phrase(_ count: Int) -> String {
                let many = count != 1
                switch self {
                case .debrief: return many ? "\(count) debriefs to finish" : "1 debrief to finish"
                case .reportFailed: return many ? "\(count) reports didn't send" : "1 report didn't send"
                case .reportStaged: return many ? "\(count) reports to send" : "1 report to send"
                case .reportNotSent: return many ? "\(count) reports not sent" : "1 report not sent"
                case .signOff: return many ? "\(count) sign-offs owed" : "1 sign-off owed"
                case .parts: return many ? "\(count) parts requests waiting" : "1 parts request waiting"
                }
            }
        }

        let id: String
        let kind: Kind
        let title: String
        let detail: String?
        let destination: JobDayDestination
        /// The job it is owed on, so the Jobs list can badge that job's row (Plan HC).
        var sessionId: String?

        var spoken: String { [title, detail].compactMap { $0 }.joined(separator: ", ") }
    }

    /// The next job on a later day, for an empty day.
    struct Next: Equatable {
        let id: String
        let title: String
        let whenText: String
        let destination: JobDayDestination
    }

    let jobs: [Job]
    let todos: [Todo]
    let personal: [MyDayItem]
    let showsPersonal: Bool
    /// Only on a day with no jobs.
    let next: Next?
    /// "3 jobs · next 10:30 Smith & Co — 1 report to send" — the card's line after "Today".
    let summary: String
    /// The same, as a sentence for VoiceOver.
    let spokenSummary: String

    var isEmptyDay: Bool { jobs.isEmpty }

    static let empty = JobDay(jobs: [], todos: [], personal: [], showsPersonal: false, next: nil,
                              summary: JobDayComposer.noJobs, spokenSummary: "Today, no jobs.")
}

enum JobDayComposer {

    static let noJobs = "No jobs"
    /// How far back a failed send is still owed. A failure from last month is history, not a to-do.
    static let failedSendWindow: TimeInterval = 7 * 24 * 3600

    static func compose(_ inputs: JobDayInputs) -> JobDay {
        let cal = inputs.calendar
        let startOfToday = cal.startOfDay(for: inputs.now)
        let startOfTomorrow = cal.date(byAdding: .day, value: 1, to: startOfToday) ?? inputs.now
        let isToday: (Date) -> Bool = { $0 >= startOfToday && $0 < startOfTomorrow }

        let relevantSessions = inputs.sessions
            .filter { $0.isOpen || (!$0.cancelled && ($0.endedAt.map(isToday) ?? false)) }
            .sorted { $0.startedAt < $1.startedAt }

        let jobs = (upcomingRows(inputs, startOfToday: startOfToday, startOfTomorrow: startOfTomorrow)
                    + relevantSessions.map { sessionRow($0, inputs: inputs) })
            .sorted(by: jobOrder)

        let todos = owed(sessions: relevantSessions,
                         finishedInScope: relevantSessions.filter { !$0.isOpen && ($0.endedAt.map(isToday) ?? false) },
                         queue: inputs.queue, debrief: inputs.debrief,
                         signOffRequired: inputs.signOffRequired, now: inputs.now)

        let next: JobDay.Next? = jobs.isEmpty ? nextJob(inputs, after: startOfTomorrow) : nil

        let (summary, spoken) = summaryLine(jobs: jobs, todos: todos, next: next, inputs: inputs)
        return JobDay(jobs: jobs, todos: todos, personal: inputs.personal ?? [],
                      showsPersonal: inputs.personal != nil, next: next,
                      summary: summary, spokenSummary: spoken)
    }

    // MARK: - Jobs

    private static func upcomingRows(_ inputs: JobDayInputs, startOfToday: Date,
                                     startOfTomorrow: Date) -> [JobDay.Job] {
        inputs.upcoming.compactMap { job in
            guard let when = job.scheduledFor, when < startOfTomorrow else { return nil }
            let overdue = when < startOfToday
            let site = job.jobReference != nil ? job.site.headline : nil
            return JobDay.Job(
                id: "upcoming-\(job.id)",
                time: when,
                timeText: overdue ? inputs.dayTimeText(when) : inputs.timeText(when),
                title: job.title,
                site: site,
                shortName: job.site.customer ?? job.title,
                status: overdue ? .overdue : .scheduled,
                destination: .upcomingJob(id: job.id))
        }
    }

    private static func sessionRow(_ session: JobDaySession, inputs: JobDayInputs) -> JobDay.Job {
        let status: JobDay.Job.Status = session.isOpen ? (session.isPaused ? .paused : .inProgress) : .done
        return JobDay.Job(
            id: "session-\(session.id)",
            time: session.startedAt,
            timeText: inputs.timeText(session.startedAt),
            title: session.label,
            site: session.siteHeadline,
            shortName: session.customer ?? session.label,
            status: status,
            destination: session.isOpen ? .openJob : .pastJob(sessionId: session.id))
    }

    /// Time order; a row without a time last; then by title so the order is total.
    private static func jobOrder(_ lhs: JobDay.Job, _ rhs: JobDay.Job) -> Bool {
        switch (lhs.time, rhs.time) {
        case let (l?, r?) where l != r: return l < r
        case (.some, nil): return true
        case (nil, .some): return false
        default: return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }

    private static func nextJob(_ inputs: JobDayInputs, after startOfTomorrow: Date) -> JobDay.Next? {
        let later = inputs.upcoming
            .compactMap { job in job.scheduledFor.map { (job, $0) } }
            .filter { $0.1 >= startOfTomorrow }
            .min { $0.1 < $1.1 }
        guard let (job, when) = later else { return nil }
        return JobDay.Next(id: job.id, title: job.site.customer ?? job.title,
                           whenText: inputs.dayTimeText(when),
                           destination: .upcomingJob(id: job.id))
    }

    // MARK: - Still to do

    /// The job admin still owed, over sessions the caller has scoped — the card's own rules, shared
    /// with the Jobs list's badges (Plan HC) so the two cannot disagree about what is owed.
    ///
    /// - `sessions`: the jobs in view; parts requests are read off these, and a to-do on the open
    ///   one routes to it.
    /// - `finishedInScope`: the finished jobs whose report and sign-off are checked — today's for
    ///   the card, the recent ones for the list. Their `reportSent` must have been read.
    /// - The send queue is scoped by itself: waiting and staged entries, and failures from the last
    ///   `failedSendWindow` not superseded by a later send.
    static func owed(sessions: [JobDaySession], finishedInScope: [JobDaySession], queue: [QueuedSend],
                     debrief: JobDayDebrief?, signOffRequired: Bool, now: Date) -> [JobDay.Todo] {
        var todos: [JobDay.Todo] = []
        let byId = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func route(_ sessionId: String) -> JobDayDestination {
            byId[sessionId]?.isOpen == true ? .openJob : .pastJob(sessionId: sessionId)
        }

        if let debrief {
            todos.append(.init(id: "debrief-\(debrief.sessionId)", kind: .debrief,
                               title: "Finish the debrief",
                               detail: "\(debrief.label) — not saved yet",
                               destination: route(debrief.sessionId), sessionId: debrief.sessionId))
        }

        let failed = owedFailures(queue, now: now)
        todos += failed.map { entry in
            let reason = entry.failureReason.map { " — \($0)" } ?? ""
            return .init(id: "send-\(entry.id)", kind: .reportFailed, title: "Report didn't send",
                         detail: "\(entry.documentKind.label) · \(entry.jobNumber)\(reason)",
                         destination: .send(queuedId: entry.id), sessionId: entry.sessionId)
        }

        let staged = queue.filter { $0.state == .staged }.sorted { $0.createdAt < $1.createdAt }
        todos += staged.map { entry in
            .init(id: "send-\(entry.id)", kind: .reportStaged, title: "Report ready to send",
                  detail: entry.summaryLine, destination: .send(queuedId: entry.id),
                  sessionId: entry.sessionId)
        }

        // A job whose report is already in the queue — waiting or failed — is covered by that row.
        let queued = Set(queue.filter { $0.state.isWaiting }.map(\.sessionId))
            .union(failed.map(\.sessionId))
        let finished = finishedInScope.filter { !$0.isOpen }

        todos += finished
            .filter { !$0.reportSent && !queued.contains($0.id) }
            .map { .init(id: "unsent-\($0.id)", kind: .reportNotSent, title: "Report not sent",
                         detail: $0.label, destination: .pastJob(sessionId: $0.id), sessionId: $0.id) }

        if signOffRequired {
            // Sign-off closes when the report goes: a signature added after the work order left
            // would describe a document nobody holds (`signOffIsStillOpen`).
            todos += finished
                .filter { !$0.signedOff && !$0.reportSent }
                .map { .init(id: "signoff-\($0.id)", kind: .signOff, title: "Customer sign-off owed",
                             detail: $0.label, destination: .pastJob(sessionId: $0.id), sessionId: $0.id) }
        }

        todos += sessions
            .filter { $0.openPartsRequests > 0 }
            .map { session in
                let count = session.openPartsRequests
                return .init(id: "parts-\(session.id)", kind: .parts,
                             title: count == 1 ? "Parts request waiting" : "\(count) parts requests waiting",
                             detail: session.label, destination: route(session.id), sessionId: session.id)
            }

        // Stable within a kind: the order each kind was gathered in.
        return todos.enumerated()
            .sorted { $0.element.kind == $1.element.kind ? $0.offset < $1.offset : $0.element.kind < $1.element.kind }
            .map(\.element)
    }

    /// Failed sends still owed: inside the window, and not superseded by a later send of the same
    /// document for the same job that went, or is waiting to.
    static func owedFailures(_ queue: [QueuedSend], now: Date) -> [QueuedSend] {
        queue.filter { $0.state == .failed && now.timeIntervalSince($0.updatedAt) <= failedSendWindow }
            .filter { failed in
                !queue.contains { other in
                    other.id != failed.id && other.sessionId == failed.sessionId
                        && other.documentKind == failed.documentKind
                        && (other.state == .sent || other.state.isWaiting)
                        && other.createdAt >= failed.createdAt
                }
            }
            .sorted { $0.updatedAt < $1.updatedAt }
    }

    // MARK: - The summary line

    private static func summaryLine(jobs: [JobDay.Job], todos: [JobDay.Todo], next: JobDay.Next?,
                                    inputs: JobDayInputs) -> (String, String) {
        var parts: [String] = []
        var spoken: [String] = []

        if jobs.isEmpty {
            parts.append(noJobs)
            spoken.append("no jobs")
        } else {
            let count = jobs.count == 1 ? "1 job" : "\(jobs.count) jobs"
            parts.append(count)
            spoken.append(count)
        }

        if let open = jobs.first(where: { $0.status.isOpen }) {
            let phrase = open.status == .paused ? "\(open.title) paused" : "on \(open.title)"
            parts.append(phrase)
            spoken.append(phrase)
        } else if let ahead = jobs.first(where: { $0.status.isAhead }) {
            if ahead.status == .overdue {
                parts.append("\(ahead.shortName) overdue")
                spoken.append("\(ahead.shortName) overdue")
            } else {
                parts.append("next \(ahead.timeText) \(ahead.shortName)")
                spoken.append("next at \(ahead.timeText), \(ahead.shortName)")
            }
        } else if !jobs.isEmpty {
            parts.append("all done")
            spoken.append("all done")
        } else if let next {
            parts.append("next \(next.whenText) \(next.title)")
            spoken.append("next \(next.whenText), \(next.title)")
        }

        var line = parts.joined(separator: " · ")
        var sentence = "Today, " + spoken.joined(separator: ", ") + "."
        if let todo = todoPhrase(todos) {
            line += " — \(todo)"
            sentence += " \(todo.prefix(1).uppercased() + todo.dropFirst())."
        }
        return (line, sentence)
    }

    /// One kind → its own phrase; only reports → "N reports to send"; a mix → "N things to do".
    static func todoPhrase(_ todos: [JobDay.Todo]) -> String? {
        guard let first = todos.first else { return nil }
        if todos.allSatisfy({ $0.kind == first.kind }) { return first.kind.phrase(todos.count) }
        if todos.allSatisfy({ $0.kind.isReport }) {
            return JobDay.Todo.Kind.reportStaged.phrase(todos.count)
        }
        return todos.count == 1 ? "1 thing to do" : "\(todos.count) things to do"
    }
}
