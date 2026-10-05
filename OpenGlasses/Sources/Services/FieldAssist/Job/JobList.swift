import Foundation

// The Jobs tab's list (Plan HC), decided without SwiftUI.
//
// The tab used to be one job at a time: the open job when there was one, otherwise a Start button
// with the scheduled and finished jobs below it. It is now a list of every job — the open one
// first, then the ones scheduled, then the ones finished this week with the admin still owed on
// them flagged, then everything older folded away — and a job's own page is pushed on top of it.
// Everything here is a pure function of facts gathered elsewhere (`JobListFeed`): the sections,
// their order, the badges, the empty list, what "Add new job" does with a job already open, and
// where a link into one job lands.

/// Where a page inside the Jobs tab goes. One enum so the stack is a value the views and the
/// routing below can both produce without knowing about each other.
enum JobRoute: Hashable {
    /// The open job — or, when none is open, the page that starts one. **One page for both**, so a
    /// job started on it becomes the job in place, exactly as the tab always behaved, and a job
    /// closed by voice while it is on screen turns it back into the start page rather than leaving
    /// a page about nothing.
    case currentJob
    /// A finished job: its record, Send report, sign-off and its debriefs.
    case pastJob(sessionId: String)
    case transcript(threadId: String)
    /// A job ahead (Plan FO P3c): its details, its brief, directions and Start.
    case upcomingJob(id: String)
}

/// One field session, as the list needs it: the day card's to-do facts plus what a row prints and
/// what the search matches.
struct JobListSession: Equatable {
    /// The facts the job-day card's "still to do" is composed from (Plan HB), so a badge here and a
    /// row on the card cannot disagree about what is owed.
    var facts: JobDaySession
    var vaultName: String
    /// The machine, as the record names it, when one was identified.
    var equipment: String?
    /// The office's identifier for the job, when it came from an office: what an update names.
    var officeJobID: String?
    /// "Resolved", "Deferred", "Cancelled" — the session's own outcome label.
    var outcomeLabel: String = ""
    /// The record's own billing phrase.
    var billingLine: String = ""
}

/// Everything the list is composed from.
struct JobListInputs {
    var now: Date
    var calendar: Calendar = .current
    /// The open job, running or paused.
    var open: JobListSession?
    /// Every finished job on the phone, cancelled ones included — they were visits too. Report and
    /// sign-off facts are only trusted for the recent ones (`JobListComposer.recentDays`): they come
    /// off each session's log on disk, and the feed reads only those.
    var finished: [JobListSession] = []
    var upcoming: [UpcomingJob] = []
    var queue: [QueuedSend] = []
    var debrief: JobDayDebrief?
    var signOffRequired = false
    /// Recorded jobs not yet with the office (Plan HE), on whichever job they were made.
    var recordings: [JobDayRecording] = []
    /// Updates from the office the technician has not had open, by office job identifier.
    var newUpdates: [String: Int] = [:]
    /// What is typed in the search field. Blank is no search.
    var query = ""
    /// "Mon 29 Sep, 2:15 PM". Injected so tests do not depend on a locale.
    var dateText: (Date) -> String = {
        $0.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }
    /// "2:15 PM".
    var timeText: (Date) -> String = { $0.formatted(date: .omitted, time: .shortened) }
}

/// The composed list.
struct JobList: Equatable {

    /// Something still owed on a job, or a job ahead that is late. Short enough to sit under the
    /// row's title; the row's spoken sentence carries them all.
    struct Badge: Identifiable, Equatable, Hashable {
        /// Declared in the order a row shows them: lateness first, then the job-day card's own
        /// order of to-dos (`JobDay.Todo.Kind`).
        enum Kind: Int, Comparable, CaseIterable {
            case overdue
            case debrief
            case reportFailed
            case reportStaged
            case reportNotSent
            case signOff
            case parts
            case recordingAttention
            case recording
            /// The office has said something about this job that has not been opened yet. Not
            /// owed work: it is there to be read.
            case officeUpdate

            static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }

            init(_ todo: JobDay.Todo.Kind) {
                switch todo {
                case .debrief: self = .debrief
                case .reportFailed: self = .reportFailed
                case .reportStaged: self = .reportStaged
                case .reportNotSent: self = .reportNotSent
                case .signOff: self = .signOff
                case .parts: self = .parts
                case .recordingAttention: self = .recordingAttention
                case .recording: self = .recording
                }
            }

            var symbol: String {
                switch self {
                case .overdue: return "clock.badge.exclamationmark"
                case .debrief: return JobDay.Todo.Kind.debrief.symbol
                case .reportFailed: return JobDay.Todo.Kind.reportFailed.symbol
                case .reportStaged: return JobDay.Todo.Kind.reportStaged.symbol
                case .reportNotSent: return JobDay.Todo.Kind.reportNotSent.symbol
                case .signOff: return JobDay.Todo.Kind.signOff.symbol
                case .parts: return JobDay.Todo.Kind.parts.symbol
                case .recordingAttention: return JobDay.Todo.Kind.recordingAttention.symbol
                case .recording: return JobDay.Todo.Kind.recording.symbol
                case .officeUpdate: return "envelope.badge"
                }
            }

            /// Late, a send that failed, or a recording stuck on the phone — the ones a technician
            /// must not read past.
            var isWarning: Bool { self == .overdue || self == .reportFailed || self == .recordingAttention }
        }

        let kind: Kind
        let label: String

        var id: Kind { kind }
        var symbol: String { kind.symbol }
        var isWarning: Bool { kind.isWarning }

        /// The mark for updates not yet opened. Nil when there are none.
        static func officeUpdate(count: Int) -> Badge? {
            guard count > 0 else { return nil }
            return Badge(kind: .officeUpdate, label: label(.officeUpdate, parts: count))
        }

        static func label(_ kind: Kind, parts: Int = 1) -> String {
            switch kind {
            case .overdue: return "Overdue"
            case .debrief: return "Debrief not saved"
            case .reportFailed: return "Report didn't send"
            case .reportStaged: return "Report ready to send"
            case .reportNotSent: return "Report not sent"
            case .signOff: return "Sign-off owed"
            case .parts: return parts > 1 ? "\(parts) parts requests waiting" : "Parts request waiting"
            // A recording's badge says where that recording stands, with the reason
            // (`JobDayRecording.sentence`); these are what it says when it has only the kind.
            case .recordingAttention: return JobDayRecording.attentionTitle
            case .recording: return JobDayRecording.waitingTitle
            case .officeUpdate: return parts > 1 ? "\(parts) new updates from the office" : "New update from the office"
            }
        }
    }

    struct Item: Identifiable, Equatable {
        enum Status: Equatable {
            case inProgress
            case paused
            case scheduled
            /// Scheduled on an earlier day and never started — the job-day card's rule.
            case overdue
            /// A job ahead with no date on it.
            case unscheduled
            case finished(outcome: String)

            var label: String {
                switch self {
                case .inProgress: return "In progress"
                case .paused: return "Paused"
                case .scheduled: return "Scheduled"
                case .overdue: return "Overdue"
                case .unscheduled: return "Not scheduled"
                case .finished(let outcome): return outcome
                }
            }
        }

        let id: String
        let route: JobRoute
        /// "Job 1005", "No job number", or a job ahead's own title — never blank.
        let title: String
        let detail: String?
        /// For a job that arrived as a file: who signed it, or that nobody did.
        let note: String?
        let noteIsWarning: Bool
        let status: Status
        let badges: [Badge]

        var needsAttention: Bool { !badges.isEmpty }

        /// The whole row as one VoiceOver sentence.
        var spoken: String {
            ([title, status.label, detail, note] + badges.map(\.label))
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        }
    }

    let open: Item?
    /// Jobs ahead: soonest first (an overdue one first of all, kept rather than dropped), the
    /// undated ones last.
    let scheduled: [Item]
    /// Finished in the last `JobListComposer.recentDays` days, newest first.
    let recent: [Item]
    /// Everything finished before that, newest first. Folded away by the view.
    let older: [Item]
    /// Non-nil while a search is typed: every job that matches, in the order the sections draw
    /// them (open, scheduled, recent, older).
    let results: [Item]?

    /// Nothing at all: no job open, none scheduled, none finished.
    var isEmpty: Bool { open == nil && scheduled.isEmpty && recent.isEmpty && older.isEmpty }
    var recentAttention: Int { recent.filter(\.needsAttention).count }
    var olderAttention: Int { older.filter(\.needsAttention).count }

    static let emptyTitle = "No jobs yet"
    static let emptyMessage = "Add a job to start one now or schedule one for later. You can also just say \u{201C}start a job\u{201D}."

    /// "Finished in the last 7 days. 2 still have something to do."
    var recentFooter: String {
        let window = "Finished in the last \(JobListComposer.recentDays) days."
        switch recentAttention {
        case 0: return window
        case 1: return window + " 1 still has something to do."
        default: return window + " \(recentAttention) still have something to do."
        }
    }

    /// "Older jobs (42)", with how many of them still have something to do.
    var olderTitle: String {
        var title = "Older jobs (\(older.count))"
        if olderAttention > 0 { title += " · \(olderAttention) to do" }
        return title
    }

    /// The search found nothing — said about the search, not about the jobs.
    static func noResults(_ query: String) -> String {
        "No job matches \u{201C}\(query.trimmingCharacters(in: .whitespacesAndNewlines))\u{201D}."
    }
}

enum JobListComposer {

    /// What counts as recent: today and the six days before it. The same span the job-day card
    /// keeps a failed send owed for.
    static let recentDays = 7
    /// How many older jobs the folded section shows before "Show more".
    static let olderPageSize = 25

    static func compose(_ inputs: JobListInputs) -> JobList {
        let cal = inputs.calendar
        let startOfToday = cal.startOfDay(for: inputs.now)
        let startOfTomorrow = cal.date(byAdding: .day, value: 1, to: startOfToday) ?? inputs.now
        let recentSince = cal.date(byAdding: .day, value: -(recentDays - 1), to: startOfToday) ?? startOfToday

        // Newest first, as the past-job list always was.
        let finished = inputs.finished
            .filter { !$0.facts.isOpen }
            .sorted { $0.facts.startedAt > $1.facts.startedAt }
        let isRecent: (JobListSession) -> Bool = { ($0.facts.endedAt ?? .distantPast) >= recentSince }
        let recentSessions = finished.filter(isRecent)
        let olderSessions = finished.filter { !isRecent($0) }
        let everySession = (inputs.open.map { [$0] } ?? []) + finished

        // The job-day card's own rules for what is owed (`JobDayComposer.owed`), over the list's
        // wider scope: report and sign-off for the recent jobs, parts and the send queue for every
        // job, and the debrief wherever it is.
        let todos = JobDayComposer.owed(
            sessions: everySession.map(\.facts),
            // A cancelled visit has no report to owe, as on the card.
            finishedInScope: recentSessions.map(\.facts).filter { !$0.cancelled },
            queue: inputs.queue, debrief: inputs.debrief,
            signOffRequired: inputs.signOffRequired, recordings: inputs.recordings, now: inputs.now)
        // A recording's badge carries its reason: "Recording waiting to sync. Waiting for Wi-Fi."
        let recordingBySession = Dictionary(inputs.recordings.map { ($0.sessionId, $0.sentence) },
                                            uniquingKeysWith: { first, _ in first })
        let partsBySession = Dictionary(everySession.map { ($0.facts.id, $0.facts.openPartsRequests) },
                                        uniquingKeysWith: { first, _ in first })
        var badgesBySession: [String: [JobList.Badge]] = [:]
        for todo in todos {
            guard let sessionId = todo.sessionId else { continue }
            let kind = JobList.Badge.Kind(todo.kind)
            // One badge per kind: a failed work order and a failed addendum are one "didn't send".
            guard badgesBySession[sessionId]?.contains(where: { $0.kind == kind }) != true else { continue }
            let isRecording = kind == .recording || kind == .recordingAttention
            badgesBySession[sessionId, default: []].append(
                JobList.Badge(kind: kind,
                              label: (isRecording ? recordingBySession[sessionId] : nil)
                                  ?? JobList.Badge.label(kind, parts: partsBySession[sessionId] ?? 1)))
        }
        func badges(_ sessionId: String) -> [JobList.Badge] {
            (badgesBySession[sessionId] ?? []).sorted { $0.kind < $1.kind }
        }
        // An update is live on a job ahead or open. A finished job's record is closed: what the
        // office says about it afterwards is kept and not flagged.
        func updates(_ officeJobID: String?) -> [JobList.Badge] {
            officeJobID.flatMap { JobList.Badge.officeUpdate(count: inputs.newUpdates[$0] ?? 0) }.map { [$0] } ?? []
        }

        let open = inputs.open.map {
            openItem($0, badges: badges($0.facts.id) + updates($0.officeJobID), inputs: inputs)
        }
        let scheduled = UpcomingJobStore.ordered(inputs.upcoming).map {
            upcomingItem($0, startOfToday: startOfToday, startOfTomorrow: startOfTomorrow, inputs: inputs)
        }
        let recent = recentSessions.map { finishedItem($0, badges: badges($0.facts.id), inputs: inputs) }
        let older = olderSessions.map { finishedItem($0, badges: badges($0.facts.id), inputs: inputs) }

        let needle = inputs.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var results: [JobList.Item]?
        if !needle.isEmpty {
            var keys: [String: String] = [:]
            for session in everySession { keys[itemId(session)] = searchKey(session) }
            for job in inputs.upcoming { keys[itemId(job)] = searchKey(job) }
            results = ([open].compactMap { $0 } + scheduled + recent + older)
                .filter { keys[$0.id]?.contains(needle) == true }
        }

        return JobList(open: open, scheduled: scheduled, recent: recent, older: older, results: results)
    }

    /// The older jobs the folded section shows after `pages` presses of "Show more" (zero is the
    /// first page), and how many are left behind it.
    static func page(_ older: [JobList.Item], pages: Int) -> (shown: [JobList.Item], remaining: Int) {
        let count = min(older.count, olderPageSize * (max(pages, 0) + 1))
        return (Array(older.prefix(count)), older.count - count)
    }

    // MARK: - Rows

    private static func itemId(_ session: JobListSession) -> String { "session-\(session.facts.id)" }
    private static func itemId(_ job: UpcomingJob) -> String { "upcoming-\(job.id)" }

    private static func openItem(_ session: JobListSession, badges: [JobList.Badge],
                                 inputs: JobListInputs) -> JobList.Item {
        let facts = session.facts
        let detail = ["Started \(inputs.timeText(facts.startedAt))", facts.customer,
                      session.equipment ?? session.vaultName]
            .compactMap { $0 }.joined(separator: " · ")
        return JobList.Item(id: itemId(session), route: .currentJob, title: facts.label,
                            detail: detail, note: nil, noteIsWarning: false,
                            status: facts.isPaused ? .paused : .inProgress, badges: badges)
    }

    private static func upcomingItem(_ job: UpcomingJob, startOfToday: Date, startOfTomorrow: Date,
                                     inputs: JobListInputs) -> JobList.Item {
        let status: JobList.Item.Status
        let when: String
        if let date = job.scheduledFor {
            if date < startOfToday {
                status = .overdue
                when = "Was due \(inputs.dateText(date))"
            } else if date < startOfTomorrow {
                status = .scheduled
                when = "Today \(inputs.timeText(date))"
            } else {
                status = .scheduled
                when = inputs.dateText(date)
            }
        } else {
            status = .unscheduled
            when = "No date set"
        }
        // The title is the site when there is no number; saying it twice would be noise.
        let site = job.jobReference != nil ? job.site.headline : nil
        let note = UpcomingJobsModel.provenanceLine(job.provenance)
        return JobList.Item(
            id: itemId(job), route: .upcomingJob(id: job.id), title: job.title,
            detail: [site, when].compactMap { $0 }.joined(separator: " · "),
            note: note, noteIsWarning: note != nil && job.provenance?.signature != .signed,
            status: status,
            badges: (status == .overdue ? [JobList.Badge(kind: .overdue, label: JobList.Badge.label(.overdue))] : [])
                + (job.provenance?.identity.flatMap {
                    JobList.Badge.officeUpdate(count: inputs.newUpdates[$0.jobID] ?? 0)
                }.map { [$0] } ?? []))
    }

    private static func finishedItem(_ session: JobListSession, badges: [JobList.Badge],
                                     inputs: JobListInputs) -> JobList.Item {
        let facts = session.facts
        let detail = [inputs.dateText(facts.startedAt), facts.customer,
                      session.equipment ?? session.vaultName, session.billingLine]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return JobList.Item(id: itemId(session), route: .pastJob(sessionId: facts.id),
                            title: facts.label, detail: detail, note: nil, noteIsWarning: false,
                            status: .finished(outcome: session.outcomeLabel), badges: badges)
    }

    // MARK: - Search

    /// Job number first — the index a technician thinks in — then the customer, the site, the
    /// machine and the vault, because "the Lennox one at Smith's" is the other way people look.
    private static func searchKey(_ session: JobListSession) -> String {
        [session.facts.jobReference, session.facts.customer, session.facts.siteHeadline,
         session.equipment, session.vaultName]
            .compactMap { $0 }.joined(separator: " ").lowercased()
    }

    private static func searchKey(_ job: UpcomingJob) -> String {
        [job.jobReference, job.title, job.site.customer, job.site.address]
            .compactMap { $0 }.joined(separator: " ").lowercased()
    }
}

// MARK: - Add new job

/// What "Add new job" does (Plan HC).
///
/// One job is open at a time — `FieldSessionService.startSession` refuses a second, and the job's
/// conversation, its clock and its intake all belong to the one that is open. So with a job open,
/// "Add new job" **asks** rather than starts: resume the open one, go and finish it (the shipped
/// close — evidence, sign-off, the record — on the job's own page), or schedule the new one for
/// later, which needs nothing closed. **Nothing here ends a job** — the defect Plan HB fixed for
/// scenarios must not come back through a button labelled "Add".
enum JobListAdd: Equatable {
    /// Nothing is open: the start page, exactly what the tab used to show with no job.
    case startNew
    case jobOpen(OpenJobPrompt)

    static func decide(openJobLabel: String?) -> JobListAdd {
        openJobLabel.map { .jobOpen(OpenJobPrompt(jobLabel: $0)) } ?? .startNew
    }
}

/// The question "Add new job" asks while a job is open, and its answers.
struct OpenJobPrompt: Equatable, Identifiable {
    /// "Job 1005", or "No job number".
    let jobLabel: String

    var id: String { jobLabel }

    private var hasNumber: Bool { jobLabel != JobTabModel.noJobNumber }

    var title: String { hasNumber ? "\(jobLabel) is still open" : "A job is still open" }
    var message: String {
        "One job is open at a time. Finish it before starting another, or schedule the new job for later. Nothing is closed for you."
    }
    var resumeTitle: String { hasNumber ? "Resume \(jobLabel)" : "Resume the open job" }
    var finishTitle: String { hasNumber ? "Finish \(jobLabel)…" : "Finish the open job…" }
    static let scheduleTitle = "Schedule a job for later"

    enum Answer: Equatable, CaseIterable {
        case resume
        /// Open the job and begin its close — the same close its own Close job button runs, with
        /// its evidence review, sign-off and confirmation. Backing out of any of them leaves the
        /// job open.
        case finishFirst
        case scheduleLater
        case cancel
    }

    /// What an answer does to the tab.
    struct Step: Equatable {
        var path: [JobRoute] = []
        /// Begin the open job's close once its page is up.
        var beginsClose = false
        /// Raise the add-a-job-for-later sheet.
        var schedules = false
    }

    static func step(_ answer: Answer) -> Step {
        switch answer {
        case .resume: return Step(path: [.currentJob])
        case .finishFirst: return Step(path: [.currentJob], beginsClose: true)
        case .scheduleLater: return Step(schedules: true)
        case .cancel: return Step()
        }
    }
}

// MARK: - Links into one job

/// A request, from anywhere in the app, to show the Jobs tab at a particular place (Plan HC).
///
/// Made through `AppState.openJobs(_:)`, which also selects the tab; consumed by the tab, which asks
/// `JobListRouting` what stack it means against what is on the phone at that moment.
enum JobListRequest: Equatable {
    /// The list itself, with nothing pushed — the staged-send notification (the send card is on
    /// the list) and a job file just added (it is under Scheduled).
    case list
    /// The open job — Resume, the day's open-job row, a scenario just started.
    case currentJob
    /// "Start a job" from elsewhere: the start page, or the open-job question when one is open.
    case newJob
    /// One job by its session id: the open job's page when it is the open one, a finished job's
    /// page otherwise.
    case session(id: String)
    /// A job ahead by its id.
    case upcoming(id: String)

    /// The job-day card's routes (Plan HB). A report in the send queue is not a place in the tab —
    /// it opens its composer where the wearer is — so it has no request.
    init?(_ destination: JobDayDestination) {
        switch destination {
        case .openJob: self = .currentJob
        case .upcomingJob(let id): self = .upcoming(id: id)
        case .pastJob(let sessionId): self = .session(id: sessionId)
        case .send: return nil
        }
    }
}

/// Where a request lands (Plan HC).
///
/// A link can outlive its job: a notification tapped an hour later, a day-view row for a job
/// removed meanwhile, Resume pressed as the job was closed by voice. Each of those lands on the
/// list with a short notice saying why — never on a blank page, never on a different job.
enum JobListRouting {

    struct Facts: Equatable {
        var openSessionId: String?
        /// "Job 1005" — for the open-job question.
        var openJobLabel: String?
        var finishedSessionIds: Set<String> = []
        var upcomingIds: Set<String> = []
    }

    struct Outcome: Equatable {
        /// The whole stack over the list. Empty is the list itself. **Replaces** whatever was
        /// pushed, so Back from the page a link opened is always the list.
        var path: [JobRoute] = []
        /// Shown at the top of the list when the job asked for could not be shown.
        var notice: String?
        /// A new job asked for while one is open: the question, on the list.
        var prompt: OpenJobPrompt?
    }

    static let noOpenJob = "No job is open right now."
    static let jobGone = "That job is no longer on this phone."
    static let upcomingGone = "That job is no longer scheduled. It may have been started or removed."

    static func resolve(_ request: JobListRequest, _ facts: Facts) -> Outcome {
        switch request {
        case .list:
            return Outcome()
        case .currentJob:
            return facts.openSessionId == nil ? Outcome(notice: noOpenJob) : Outcome(path: [.currentJob])
        case .newJob:
            let label = facts.openSessionId.map { _ in facts.openJobLabel ?? JobTabModel.noJobNumber }
            switch JobListAdd.decide(openJobLabel: label) {
            case .startNew: return Outcome(path: [.currentJob])
            case .jobOpen(let prompt): return Outcome(prompt: prompt)
            }
        case .session(let id):
            if id == facts.openSessionId { return Outcome(path: [.currentJob]) }
            if facts.finishedSessionIds.contains(id) { return Outcome(path: [.pastJob(sessionId: id)]) }
            return Outcome(notice: jobGone)
        case .upcoming(let id):
            return facts.upcomingIds.contains(id)
                ? Outcome(path: [.upcomingJob(id: id)]) : Outcome(notice: upcomingGone)
        }
    }
}
