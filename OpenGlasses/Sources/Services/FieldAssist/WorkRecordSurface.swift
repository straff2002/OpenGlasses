import Foundation

/// The slice of `FieldSessionService` the job surfaces need — the task list on the session card,
/// the read-back, and the report button. A protocol so all three are provable without standing up
/// a vault, a session or SwiftUI, in the same shape `EquipmentHosting` uses.
@MainActor
protocol WorkRecordHosting: AnyObject {
    var activeSession: FieldSession? { get }
    var lastDeliveryCancelled: Bool { get }
    func workRecord() -> WorkRecord?
}

extension FieldSessionService: WorkRecordHosting {}

/// What the session card draws for the job's tasks, decided without SwiftUI (Plan EM P2).
///
/// P1 recorded tasks, decided them by voice and rendered them into the record, and showed them
/// nowhere. A technician who has said "do it" four times has no way to see what is still open
/// without asking out loud, and a wrong decision has no screen to be corrected on.
@MainActor
struct TaskSectionModel {

    /// One task as the card lists it. Collapsed it is a title and a status; expanded it is why it
    /// was recommended, what parts it names, what the technician said they did, and the evidence.
    struct Row: Identifiable, Equatable {
        let id: String
        let title: String
        let status: FieldSession.Task.Status
        /// "Done", "In progress", "Recommended, no decision yet" — the record's own wording, so
        /// what a technician reads on the phone is what the customer reads on the PDF.
        let statusLabel: String
        let isOperatorAdded: Bool
        let why: String?
        let procedureLine: String?
        let parts: [String]
        let completionNote: String?
        /// "1 reading, 2 photos, 1 page verified" — nil when nothing was recorded against it.
        let evidence: String?
        let citation: String?
        let safetyNote: String?

        init(task: FieldSession.Task) {
            id = task.id
            title = task.title
            status = task.status
            statusLabel = WorkRecord.label(for: task.status)
            isOperatorAdded = task.origin == .operatorAdded
            why = task.why.flatMap { $0.isEmpty ? nil : $0 }
            procedureLine = task.procedureId.map { id in
                task.procedureOutcome.map { "Procedure \(id) — \($0)" } ?? "Procedure \(id)"
            }
            parts = task.parts.map(\.summary)
            completionNote = task.completionNote.flatMap { $0.isEmpty ? nil : $0 }
            evidence = WorkRecord.evidencePhrase(task.evidence)
            citation = task.citation.flatMap { $0.isEmpty ? nil : $0 }
            safetyNote = task.safetyNote.flatMap { $0.isEmpty ? nil : $0 }
        }
    }

    private let host: WorkRecordHosting
    /// How many of this job's records are still sitting in the queue. Injected rather than read,
    /// because the queue is the app's and this model is provable without one.
    private let unsentCount: Int

    init(host: WorkRecordHosting, unsentCount: Int = 0) {
        self.host = host
        self.unsentCount = unsentCount
    }

    /// Closed work first, then what is open, then what was turned down — the record's own order,
    /// so the screen and the read-back agree about what matters.
    var rows: [Row] {
        guard let session = host.activeSession else { return [] }
        return WorkRecord.statusOrder.flatMap { status in
            session.tasks.filter { $0.status == status }.map(Row.init(task:))
        }
    }

    var isEmpty: Bool { rows.isEmpty }

    /// "No tasks yet — recommendations you accept and work you add appear here."
    var emptyMessage: String {
        "No tasks yet. A recommendation you accept, or a job you add out loud, appears here."
    }

    /// "3 tasks · 1 still open" — the one-line header.
    var headline: String {
        let all = rows
        let open = all.filter { $0.status.isOpen }.count
        var line = "\(all.count) task\(all.count == 1 ? "" : "s")"
        if open > 0 { line += " · \(open) still open" }
        return line
    }

    /// "Unsent: 2" — the queue still holds records for this job, or a composer was dismissed
    /// without sending. Nil when there is nothing outstanding, so the card stays quiet.
    var unsentLine: String? {
        if unsentCount > 0 {
            return "Unsent: \(unsentCount) — waiting to reach the office."
        }
        if host.lastDeliveryCancelled {
            return "Unsent: the last report wasn't confirmed sent. It's still queued — send it again."
        }
        return nil
    }

    /// What "read back the job" speaks and what the sheet prints. Nil with no session.
    var readBack: [String]? { host.workRecord()?.summaryLines }

    var readBackSpeech: String? { host.workRecord()?.summary }
}

/// The one line the lens carries about the task in hand (Plan EM P2).
///
/// Same transient path as the figure and equipment cues: a notification over whatever the HUD is
/// showing, and nothing persistent. A technician who has just said "do it" needs to see what the
/// glasses think they took on; they do not need a permanent banner eating the display.
enum TaskHUDCue {

    struct Cue: Equatable {
        enum Phase: String, Equatable {
            case started
            case done
            case abandoned
        }

        let taskId: String
        let title: String
        let phase: Phase
    }

    /// "On: check the pressure switch tubing" / "Done: check the pressure switch tubing".
    static func line(for cue: Cue) -> String {
        switch cue.phase {
        case .started: return "On: \(cue.title)"
        case .done: return "Done: \(cue.title)"
        case .abandoned: return "Left: \(cue.title)"
        }
    }

    /// Flash it. A no-op without a display, which the service itself decides.
    @MainActor
    static func show(_ cue: Cue, on display: GlassesDisplayService) {
        display.showNotification(title: nil, body: line(for: cue), icon: .info, duration: 4)
    }
}
