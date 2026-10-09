import Foundation

/// How the turn that filed a team learning is kept out of the model's view of the job (Plan FP P1).
///
/// The P0 inventory found the leak this closes: `FieldSessionContextSnapshot` renders every
/// technician `.userMessage` in the job's log as a "Technician report", and `field_session recall`
/// reads the same records — so *"note this for the team — on the 090 the tubing sweats"* reached the
/// next turn's prompt whatever the candidate store did. A candidate is unreviewed and must not be
/// asserted to the model as anything, so the turn that filed (or amended) one is **withheld**:
///
/// - The append-only log keeps it — it was said, and the audit trail and the office transcript are
///   records of what was said. What changes is the model-facing view.
/// - The filing writes a dedicated event (`teamLearningFiled` / `teamLearningAmended`) whose payload
///   lists the source ids of the turns it withholds, and the snapshot and recall skip those turns
///   and render the event as one fixed line with no candidate text.
/// - Which turn that is depends on the route. On the Direct path the turn in flight has a source id
///   (`FieldSessionService.turnSourceID`, set by `LLMService` for the length of a turn and by the
///   Tier-0 phrase route around its call), so that id is withheld exactly, whether the turn was
///   logged before the tool ran or is logged after it. The live modes (Gemini Live, OpenAI
///   Realtime) mint a transcript's id when the transcript lands, which can be before or after the
///   tool call; there the technician lines logged in the `liveWindow` before the filing are
///   withheld, and the next one logged within the window after it is tagged as withheld when it
///   arrives. The window over-withholds rather than under-withholds: a neighbouring line hidden from
///   the snapshot is still in the log, and the snapshot already tells the model not to infer
///   absence from it.
enum TeamLearningTurnWithholding {

    /// The line the snapshot shows in place of the filing turn. Fixed, and free of candidate text.
    static let filedLine = "A team-learning candidate was filed (awaiting review; not evidence)"
    static let amendedLine = "A team-learning candidate was amended (awaiting review; not evidence)"
    static let withdrawnLine = "A team-learning candidate was withdrawn"

    /// Payload key on a filing event: the source ids of the turns it withholds.
    static let withheldSourceIDsKey = "withheld_source_ids"
    /// Payload key on a live-mode turn logged after the filing that withholds it.
    static let withheldByKey = "team_learning_withheld"

    /// How far either side of a live-mode filing a technician line is taken to be the one that
    /// filed it.
    static let liveWindow: TimeInterval = 15

    /// Every source id a filing or amending event in the log withholds.
    static func withheldSourceIDs(in events: [SessionLogger.Event]) -> Set<String> {
        var ids = Set<String>()
        for event in events where event.kind == .teamLearningFiled || event.kind == .teamLearningAmended {
            let listed = event.payload?[withheldSourceIDsKey]?.value as? [Any] ?? []
            ids.formUnion(listed.compactMap { $0 as? String })
        }
        return ids
    }

    /// Whether a logged turn is withheld from the model's view of the job.
    static func isWithheld(_ event: SessionLogger.Event, withheld: Set<String>) -> Bool {
        guard event.kind == .userMessage else { return false }
        if event.payload?[withheldByKey] != nil { return true }
        guard let id = event.payload?["source_id"]?.value as? String else { return false }
        return withheld.contains(id)
    }

    /// The fixed line a team-learning event renders as, or nil for any other event.
    static func snapshotLine(for kind: SessionLogger.Event.Kind) -> String? {
        switch kind {
        case .teamLearningFiled: return filedLine
        case .teamLearningAmended: return amendedLine
        case .teamLearningWithdrawn: return withdrawnLine
        default: return nil
        }
    }
}
