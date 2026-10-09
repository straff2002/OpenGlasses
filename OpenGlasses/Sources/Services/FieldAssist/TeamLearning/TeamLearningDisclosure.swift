import Foundation

/// What an answer that drew on team learnings has to say about it (Plan FP §5).
///
/// "Clear that it is a team learning" is held to four places, none of them the model's phrasing:
/// 1. **the spoken lead-in** — composed here and prepended to a learning-only answer by the app
///    (`prepend(to:)`), and handed to the model as the exact sentence to open with on the modes
///    where the app does not hold the reply;
/// 2. **the citation** — the entry's contract §7.1 name, never a manual title
///    (`TeamLearningCitation`);
/// 3. **the badge flag** — `showsTeamLearningBadge`, on the answer's evidence the phone and HUD
///    read (`FieldSessionService.answerEvidence`; the visible badge is P4), and the citation chip's
///    own `Citation.isTeamLearning`;
/// 4. **the record** — a learning-only answer is logged on the job and carried on the
///    `WorkRecord` with the entry's id and approver role (`TeamLearningAnswer`), and kept out of
///    every customer-facing document.
struct TeamLearningDisclosure: Equatable {

    /// One entry an answer drew on.
    struct Entry: Equatable {
        let entryID: String
        let approvedByRole: String
        let citation: String
        let confirmedJobCount: Int?
        let contradictsSafetyNote: Bool
    }

    /// The answer rested on learnings alone: no manual passage cleared the gate.
    let restsOnLearningAlone: Bool
    /// The learnings the evidence carried, in rank order.
    let entries: [Entry]

    /// The badge flag: the answer's evidence includes a team learning.
    var showsTeamLearningBadge: Bool { !entries.isEmpty }

    /// The sentence a learning-alone answer opens with; nil when a manual passage carried it.
    var leadIn: String? {
        restsOnLearningAlone ? Self.leadIn(confirmedJobCount: entries.first?.confirmedJobCount) : nil
    }

    /// "The manual doesn't cover this. Your crew's own finding[, noted on <n> previous jobs]:" —
    /// the count only when the entry was filed on more than one job.
    static func leadIn(confirmedJobCount: Int?) -> String {
        var sentence = "The manual doesn't cover this. Your crew's own finding"
        if let count = confirmedJobCount, count > 1 { sentence += ", noted on \(count) previous jobs" }
        return sentence + ":"
    }

    /// The reply with the lead-in in front of it, exactly once. A reply that already opens with it
    /// (the model followed the instruction) is left as it is.
    static func prepend(_ leadIn: String, to answer: String) -> String {
        let body = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        let stem = leadIn.trimmingCharacters(in: CharacterSet(charactersIn: ": "))
        let comparable = body.replacingOccurrences(of: "\u{2019}", with: "'")
        if comparable.range(of: stem, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) != nil { return body }
        return body.isEmpty ? leadIn : leadIn + " " + body
    }

    /// The disclosure an outcome calls for, or nil when it carried no learning. `entry` resolves a
    /// corpus document id to its approved entry; a document whose entry this phone does not hold
    /// is still disclosed, by the id and role its own name carries.
    static func from(_ outcome: RetrievalOutcome,
                     entry: (String) -> LearningEntry?) -> TeamLearningDisclosure? {
        var seen = Set<String>()
        let entries: [Entry] = outcome.teamLearningPassages.compactMap { passage in
            let found = entry(passage.documentId)
            guard let id = found?.id ?? LearningCorpus.entryID(fromDocumentId: passage.documentId),
                  seen.insert(id).inserted else { return nil }
            return Entry(entryID: id,
                         approvedByRole: found?.approvedByRole ?? role(fromCitation: passage.documentName),
                         citation: passage.documentName,
                         confirmedJobCount: found?.confirmedJobCount,
                         contradictsSafetyNote: found?.contradictsSafetyNote ?? false)
        }
        guard !entries.isEmpty else { return nil }
        return TeamLearningDisclosure(restsOnLearningAlone: outcome.isTeamLearningOnly, entries: entries)
    }

    /// The role at the end of a §7.1 citation name.
    static func role(fromCitation name: String) -> String {
        guard let range = name.range(of: " · approved by ", options: .backwards) else { return "" }
        return String(name[range.upperBound...])
    }
}

/// That an answer on this job rested on a team learning alone (Plan FP §5; contract §8): the entry
/// and the approver's role, never the finding's words. Internal to the organisation, like
/// `LearningCandidateReference` beside it — no customer summary, printed work-order line or
/// customer-audience export carries it — so a job record never implies the manufacturer said it.
struct TeamLearningAnswer: Codable, Equatable {
    let entryID: String
    let approvedByRole: String
    /// When it first answered on this job.
    let answeredAt: Date
    /// How many answers on this job rested on it alone.
    var answers: Int

    init(entryID: String, approvedByRole: String, answeredAt: Date, answers: Int = 1) {
        self.entryID = entryID
        self.approvedByRole = approvedByRole
        self.answeredAt = answeredAt
        self.answers = answers
    }

    enum CodingKeys: String, CodingKey {
        case entryID = "entry_id"
        case approvedByRole = "approved_by_role"
        case answeredAt = "answered_at"
        case answers
    }
}

/// The evidence behind the latest answer, as the phone and the lens read it (Plan FP P2): which
/// kind of evidence it was, and the team-learning badge flag. The visible badge is P4's.
struct AnswerEvidence: Equatable {
    enum Basis: String, Equatable {
        /// Manual passages, no learning.
        case manual
        /// Manual passages with an approved team learning beside them.
        case manualWithTeamLearning
        /// Approved team learnings alone — the answer opens with the lead-in.
        case teamLearningOnly
        /// Nothing cleared the gate.
        case none
    }

    let basis: Basis
    /// Every citation the evidence carried, in rank order.
    let citations: [String]
    let disclosure: TeamLearningDisclosure?

    /// Badge the answer as a team learning.
    var teamLearningBadge: Bool { disclosure?.showsTeamLearningBadge ?? false }

    init(outcome: RetrievalOutcome, disclosure: TeamLearningDisclosure?) {
        switch outcome {
        case .sufficient(let passages):
            basis = passages.contains { $0.source == .teamLearning } ? .manualWithTeamLearning : .manual
        case .teamLearningOnly: basis = .teamLearningOnly
        case .insufficient: basis = .none
        }
        citations = outcome.passages.map(\.citation)
        self.disclosure = disclosure
    }
}
