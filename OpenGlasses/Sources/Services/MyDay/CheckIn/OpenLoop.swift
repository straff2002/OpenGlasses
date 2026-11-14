import CryptoKit
import Foundation

// MARK: - The Evening Check-in's open loops (Plan LE P0)
//
// One thing from the day still waiting on the wearer: an approval, a reminder, a goal step, an
// unheard update, a queued result — and, with Field Assist on, the job's own loose ends (§10).
// Pure values: every source adapts its own records into `OpenLoop` behind
// `OpenLoopSourceReading`, and `OpenLoopCollector` decides what counts and in what order.
// Nothing here reads a store, calls a model or leaves the phone.

/// Where an open loop comes from, declared in the order of the plan's table (§2). That order is
/// the collector's last tie-break, so a case is never reordered: add new ones at the end of their
/// group.
enum OpenLoopSource: String, CaseIterable, Equatable, Hashable, Sendable {
    /// A trail `.held` entry the wearer has not answered.
    case approval
    /// An incomplete reminder, due today or overdue.
    case reminder
    /// The next step of an active goal, due today or overdue.
    case goalStep
    /// An `actionable` (or higher) digest item never seen and not dismissed.
    case digest
    /// An agent result queued and not delivered.
    case agentResult
    /// A prepared card's draft the wearer opened and did not send (Plan KT). No producer yet.
    case draft
    /// A task step waiting on someone else past the threshold (Plan KI, decision 5). No producer yet.
    case waitingOnOthers
    /// A watcher finding filed to the digest and never heard (Plan JO). No producer yet.
    case watcherFinding
    /// A keep-asking reminder still not confirmed (Plan LG). No producer yet.
    case askAgain

    // §10 — the job's loose ends, in the order decision 11 ranks them.

    /// A job report staged in the send queue and never sent, a send that failed, or a finished
    /// job whose report never reached the queue.
    case jobReport
    /// A job whose close is held — for the customer's sign-off, or a check still owed.
    case jobCloseHeld
    /// A parts request on today's work that was never sent.
    case partsRequest
    /// A work task the technician deferred and did not finish.
    case deferredTask
    /// An expert hand-off or escalation still waiting on its answer.
    case expertOrEscalation

    /// The source's place in the plan's table: the final tie-break.
    var tableOrder: Int { Self.allCases.firstIndex(of: self) ?? Self.allCases.count }

    /// Its place among the job's loose ends (decision 11: report first), or nil for the others.
    var jobOrder: Int? {
        switch self {
        case .jobReport: return 0
        case .jobCloseHeld: return 1
        case .partsRequest: return 2
        case .deferredTask: return 3
        case .expertOrEscalation: return 4
        default: return nil
        }
    }

    var isJobLooseEnd: Bool { jobOrder != nil }

    /// Whether anything in the app produces this source's records yet. The four other plans'
    /// sources are defined so the collector and phraser are ready for them; until those plans
    /// land, no reader reports them.
    var hasProducer: Bool {
        switch self {
        case .draft, .waitingOnOthers, .watcherFinding, .askAgain: return false
        default: return true
        }
    }
}

/// The place a row opens. Each row opens its own place; nothing is sent, closed or approved by
/// the check-in itself (§6, §10).
enum OpenLoopPlace: Hashable, Sendable {
    /// A Field Assist destination, as the job day already names them (the report composer, the
    /// job's page, the parts order).
    case job(JobDayDestination)
    /// One digest item.
    case digestItem(id: String)
    /// One queued agent result.
    case agentResult(id: String)
    /// A prepared card (Plan KT).
    case card(id: String)
    /// A goal (Plan KI waiting steps, or a goal without a dated step).
    case goal(id: UUID)
}

/// What the row's action does when the wearer takes it. Every one of them runs through the
/// item's own confirmation and screen; the check-in only routes.
enum OpenLoopAction: Hashable, Sendable {
    /// Run the held operation's own confirmation, as it would have run when it was held. The
    /// reference is the trail entry's id.
    case approve(entryID: UUID)
    /// Complete a reminder (`EventKitDayStore.completeReminder(id:)`).
    case complete(reminderID: String)
    /// Mark a goal step done (`GoalsDaySource.completeGoalStep`).
    case stepDone(goalID: UUID, stepID: UUID)
    /// Open the item's own place.
    case open(OpenLoopPlace)
    /// Nothing to do but clear it for tonight.
    case dismiss
}

/// The job a §10 loose end belongs to, as the job's record already names it. Never invented and
/// never reformatted: a reference is said as the technician gave it, a customer as they entered it.
enum OpenLoopJobName: Equatable, Hashable, Sendable {
    /// "the Smith job" / "for Smith".
    case customer(String)
    /// "job 1005" / "for job 1005".
    case reference(String)
}

/// One thing still waiting on the wearer.
struct OpenLoop: Identifiable, Equatable, Hashable, Sendable {
    /// Source-prefixed and stable across reads: "held:<entry id>", "reminder:<EventKit id>",
    /// "report:<queued id>". Dismissals are keyed by it.
    let id: String
    let source: OpenLoopSource
    /// Already in the wearer's words where the source has them: the reminder's text, the step's
    /// title, the trail entry's title, the part's description.
    let title: String
    /// Who or what it is about, when the source names it: the goal for a step, the person for a
    /// reply still owed, the expert for a hand-off.
    let subject: String?
    /// The job, for a §10 loose end.
    let job: OpenLoopJobName?
    /// When it started waiting.
    let since: Date
    /// When it is due, if it has a date.
    let dueAt: Date?
    /// The last attempt failed (a report whose send failed). Ranks first within its source and is
    /// said as a failure.
    let failed: Bool
    let action: OpenLoopAction
    /// What "it changed" means for the once-a-day rule: a dismissal sticks while this is the same.
    let fingerprint: String
    /// Ids of other loops this one stands for — a goal step whose action set a reminder lists
    /// that reminder's loop id, so the two count once, as the step (§2 rule 3).
    let covers: Set<String>

    init(id: String, source: OpenLoopSource, title: String, subject: String? = nil,
         job: OpenLoopJobName? = nil, since: Date, dueAt: Date? = nil, failed: Bool = false,
         action: OpenLoopAction, fingerprint: String? = nil, covers: Set<String> = []) {
        self.id = id
        self.source = source
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.subject = subject.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        self.job = job
        self.since = since
        self.dueAt = dueAt
        self.failed = failed
        self.action = action
        self.fingerprint = fingerprint
            ?? Self.fingerprint(title: self.title, dueAt: dueAt, failed: failed)
        self.covers = covers
    }

    /// The default fingerprint: the title, the due time and whether it failed — so a reminder
    /// moved to another time, a renamed step or a send that has since failed is new news. A one-way
    /// digest (P1): the dismissal record keeps loop ids and these, never a title, so the only thing
    /// the check-in keeps beyond its sources names nobody.
    static func fingerprint(title: String, dueAt: Date?, failed: Bool) -> String {
        let due = dueAt.map { String(Int($0.timeIntervalSince1970)) } ?? "-"
        let material = "\(title)|\(due)|\(failed ? "failed" : "-")"
        return SHA256.hash(data: Data(material.utf8)).prefix(12)
            .map { String(format: "%02x", $0) }.joined()
    }
}

/// What one reader found. A source that cannot be read says so; it never reports an empty list
/// in its place (§1).
enum OpenLoopReading: Equatable, Sendable {
    case read([OpenLoop])
    case unavailable
}

/// One source's adapter over its own store (P1 writes them). A reader may answer for more than one
/// source — the job stores answer five — and is reported unavailable for all of them together.
@MainActor
protocol OpenLoopSourceReading: AnyObject {
    var sources: [OpenLoopSource] { get }
    /// Read fresh at delivery time, never from a cache filled earlier in the day (Risks).
    func readOpenLoops(now: Date, calendar: Calendar) async -> OpenLoopReading
}
