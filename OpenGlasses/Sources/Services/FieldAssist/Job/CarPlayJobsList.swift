import Foundation

/// The Jobs list on the car screen, decided without CarPlay (Plan FO P3a, §6 minus the Debrief
/// action — that is P3b's).
///
/// **Read-only, and one glance per row.** The active job first, then recent finished jobs by
/// number, date and outcome. The work record is never rendered here; a technician at 100 km/h gets
/// a job number and a date, and everything else stays on the phone.
///
/// The two selections are deliberately unequal:
///  - the **active** job resumes its bound conversation through the P1 chokepoint
///    (`GuidedJobFlow.requestResume`), never by assigning `activeThreadId` — the id-without-history
///    defect P1 fixed on exactly this surface;
///  - a **past** job reads its name aloud and does nothing else. Debrief is P3b; the seam for it is
///    ``Row/selection`` gaining a case, not this model gaining a screen.
enum CarPlayJobsList {

    /// What tapping a row does.
    enum Selection: Equatable {
        /// Resume the open job's conversation. `threadId` is nil while the job owns none yet —
        /// nothing has been said on it — and the row then only speaks.
        case resumeActiveJob(threadId: String?)
        /// Read this finished job's name aloud. Nothing else is shown — what a past row does when
        /// a debrief cannot be started (Field Assist off).
        case speakPastJob(sessionId: String)
        /// Start a debrief on this finished job (Plan FO P3b). The app names the job aloud and
        /// listens; nothing is written until the technician saves.
        case debriefPastJob(sessionId: String)
        /// Read the delivery queue back — "what's waiting?" without having to say it.
        case readSendQueue
    }

    struct Row: Identifiable, Equatable {
        let id: String
        /// "Job 1005", or "No job number" — never blank, for the same reason the phone's list is
        /// never blank: a row nobody can read is a row nobody can tap with confidence.
        let title: String
        /// The active job's state, or a finished job's date and outcome. Nothing else.
        let detail: String
        let isActiveJob: Bool
        let selection: Selection

        /// What the car speaks when the row is chosen, and what VoiceOver would read.
        var spoken: String { "\(title), \(detail)" }
    }

    /// The blank a job number cannot be. Same words as the phone's list, from one constant each,
    /// because a technician who sees "No job number" on the Job tab must see it here too.
    static var noJobNumber: String { JobTabModel.noJobNumber }

    /// How many finished jobs the car screen carries. CarPlay bounds a list template anyway, and
    /// a scroll on a car screen is the thing this list is trying not to be.
    static let pastJobLimit = 10

    /// The rows, active job first.
    ///
    /// - Parameters:
    ///   - active: the open job, if one is. Keyed on `endedAt`/`outcome` exactly as the rest of the
    ///     plan is, so a paused job is still the job and a cancelled one is not.
    ///   - history: every session the device holds; finished ones are taken from it, newest first.
    ///   - boundThreadId: the conversation the open job owns, when it owns one.
    /// - Parameters:
    ///   - debriefAvailable: whether a past row's action is **Debrief** (Plan FO P3b) or the
    ///     read-only name it was before. False when Field Assist is off, where a debrief would
    ///     have nothing to write onto.
    ///   - stagedSends: how many reports are waiting for a thumb. More than none puts one row at
    ///     the top that reads the queue back, so "what's waiting?" is answerable at a glance as
    ///     well as out loud.
    static func rows(active: FieldSession?,
                     history: [FieldSession],
                     boundThreadId: String?,
                     debriefAvailable: Bool = false,
                     stagedSends: Int = 0) -> [Row] {
        var rows: [Row] = []
        if stagedSends > 0 {
            rows.append(Row(id: "send-queue",
                            title: stagedSends == 1 ? "1 report ready to send"
                                                    : "\(stagedSends) reports ready to send",
                            detail: "Needs the phone",
                            isActiveJob: false,
                            selection: .readSendQueue))
        }
        if let active, active.endedAt == nil, active.outcome != .cancelled {
            rows.append(Row(id: active.id,
                            title: title(for: active),
                            detail: active.pausedAt == nil ? "In progress" : "Paused",
                            isActiveJob: true,
                            selection: .resumeActiveJob(threadId: boundThreadId)))
        }
        let past = history
            .filter { $0.endedAt != nil }
            .sorted { $0.startedAt > $1.startedAt }
            .prefix(pastJobLimit)
        for session in past {
            rows.append(Row(id: session.id,
                            title: title(for: session),
                            detail: "\(session.startedAt.formatted(date: .abbreviated, time: .omitted)) · "
                                + session.outcome.displayName,
                            isActiveJob: false,
                            selection: debriefAvailable
                                ? .debriefPastJob(sessionId: session.id)
                                : .speakPastJob(sessionId: session.id)))
        }
        return rows
    }

    /// What the list says when there is nothing on it. A blank template on a car screen looks
    /// broken; this says which of the two reasons it is.
    static func emptyMessage(fieldAssistActive: Bool) -> String {
        fieldAssistActive
            ? "No jobs yet. Start one on the phone or by voice."
            : "Field Assist is off."
    }

    private static func title(for session: FieldSession) -> String {
        guard let reference = session.jobReference, !reference.isEmpty else { return noJobNumber }
        return "Job \(reference)"
    }
}
