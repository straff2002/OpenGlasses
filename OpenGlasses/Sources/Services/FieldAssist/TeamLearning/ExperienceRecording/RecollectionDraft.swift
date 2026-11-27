import Foundation

/// One field of a recollection as the drafting pass reads it (Plan IM P2): the partner's five
/// parts, the model and the equipment type, and the site, which never becomes part of a learning
/// (decision 6). The spellings are the wire's (`Contracts/team-learning.md` §13.1).
enum RecollectionField: String, CaseIterable, Codable, Sendable {
    case model, equipmentType, symptom, findings, tried, fix, outcome, siteNote

    /// The fields a learning is drafted from: every one but the site.
    static let learning: [RecollectionField] = allCases.filter { $0 != .siteNote }

    /// A draft needs at least one of these, filled or held back. A recording that is not a case
    /// ("just testing") has none and drafts nothing.
    static let substance: [RecollectionField] = [.symptom, .findings, .fix]

    /// The most Unicode scalars the field may hold: the candidate's own limits (team-learning §3,
    /// §13), and the equipment type list's. A site note has none, because it is not a learning.
    var limit: Int? {
        switch self {
        case .model, .equipmentType: return VaultPackRules.equipmentTypeLimit
        case .symptom, .tried, .fix: return LearningCandidateText.fieldLimit
        case .findings: return LearningCandidateText.findingLimit
        case .outcome: return LearningCandidateText.outcomeLimit
        case .siteNote: return nil
        }
    }

    /// A name is held to its words. A model or equipment type its quotes do not say is refused
    /// rather than quoted in its place: there is no verbatim form of "which machine".
    var isName: Bool { self == .model || self == .equipmentType }

    /// The plain-text rule the field is normalised under (§7.4): a line feed survives inside the
    /// findings only, as it does inside a candidate's finding.
    var textRule: LearningCandidateText.Field {
        switch self {
        case .findings: return .finding
        case .tried: return .tried
        case .fix: return .fix
        case .outcome: return .outcome
        case .model, .equipmentType, .symptom, .siteNote: return .symptom
        }
    }
}

/// A learning drafted from one part of an experience recording (Plan IM P2) — unreviewed, and
/// never an answer. A person approves, edits or discards it in the review queue (P3).
///
/// Every filled field keeps the transcript spans it came from, so the reviewer sees the words
/// beside the field. A field the transcript does not say is absent, never filled in; a field that
/// was said but cannot be kept as drafted (over its limit, or an equipment type the vault does not
/// list) is `heldBack` with its spans, so the reviewer can read it in the transcript instead.
///
/// The shape is the wire's (`Contracts/team-learning.md` §13.1): what an office intake computes
/// from the same transcript and model answer is this, field for field.
struct RecollectionDraft: Codable, Equatable, Sendable {

    /// A half-open range of Unicode scalar offsets into the recording's transcript. Scalars, so a
    /// reader in another language counts the same characters (Python's `str` indexes them too).
    struct Span: Codable, Equatable, Hashable, Sendable {
        let start: Int
        let end: Int

        init(start: Int, end: Int) {
            self.start = start
            self.end = end
        }

        func overlaps(_ other: Span) -> Bool { start < other.end && other.start < end }
    }

    struct Field: Codable, Equatable, Sendable {
        let text: String
        let spans: [Span]
        /// True when the model's wording said more than its quotes, so the field is the
        /// technician's own words, verbatim, in its place.
        let verbatim: Bool
    }

    /// A field that was said but is not drafted, and why.
    struct HeldBack: Codable, Equatable, Sendable {
        enum Reason: String, Codable, Sendable {
            /// Longer than the candidate allows. Never cut: a cut "fixed it every time, except…"
            /// says something else.
            case overLimit
            /// An equipment type that is not on the vault's closed list (decision 4): no symptom
            /// subject is drafted from it.
            case notListed
        }

        let field: RecollectionField
        let reason: Reason
        /// For `overLimit`: how long it was, and the limit.
        var count: Int?
        var limit: Int?
        /// For `notListed`: the type as said.
        var text: String?
        let spans: [Span]
    }

    /// What the entry is suggested to be about, for the reviewer to accept or change.
    struct Subject: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable { case model, symptom }
        let kind: Kind
        var modelToken: String?
        var equipmentType: String?
        var phrase: String?

        static func model(_ token: String, equipmentType: String?) -> Subject {
            Subject(kind: .model, modelToken: token, equipmentType: equipmentType)
        }

        static func symptom(_ equipmentType: String, phrase: String) -> Subject {
            Subject(kind: .symptom, equipmentType: equipmentType, phrase: phrase)
        }

        /// As the review takes it (`LearningReview.approve(subject:)`).
        var entrySubject: LearningEntry.Subject? {
            switch kind {
            case .model:
                return modelToken.map { .model(modelToken: $0, equipmentType: equipmentType) }
            case .symptom:
                guard let equipmentType, let phrase else { return nil }
                return .symptom(equipmentType: equipmentType, phrase: phrase)
            }
        }
    }

    /// The part of the transcript the case was drafted from.
    let segment: Span
    /// The same part, as the candidate's recording evidence carries it: whole seconds, estimated
    /// from where the segment sits in the transcript, because the recorder keeps no timings (§13.1).
    let recording: LearningCandidate.Recording
    /// Keyed by `RecollectionField.rawValue`; only the fields that are filled.
    let fields: [String: Field]
    let heldBack: [HeldBack]
    /// The vault's model, when the drafted model resolves to exactly one of its sections.
    var modelToken: String?
    /// The model as said, when it resolves to none.
    var spokenModel: String?
    var subject: Subject?
    /// The hazard words the safety check finds in the drafted text (`LearningSafetyCheck`): shown
    /// to the reviewer, never a refusal. Approval runs the check again with the vault's safety core.
    let safetyTerms: [String]

    func field(_ name: RecollectionField) -> Field? { fields[name.rawValue] }
    func text(_ name: RecollectionField) -> String? { fields[name.rawValue]?.text }

    // MARK: - The candidate (Plan IM P3 files it)

    /// The `recollection` candidate this draft is filed as, with the recording it points at. The
    /// finding is the drafted findings, or failing those the fix, then the symptom — never words
    /// the transcript did not hold. Refused, as a capture is, when nothing is left to be a finding.
    func candidate(from recording: ExperienceRecording, author: String,
                   index: VaultModelIndex? = nil) -> Result<LearningCandidate, LearningCandidateText.Refusal> {
        let finding = text(.findings) ?? text(.fix) ?? text(.symptom)
        let cleaned: LearningCandidateText.Cleaned
        switch LearningCandidateText.clean(finding: finding, symptom: text(.symptom), fix: text(.fix),
                                           tried: text(.tried), outcome: text(.outcome)) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let value): cleaned = value
        }
        let equipment = modelToken.map { token in
            LearningCandidate.Equipment(
                modelToken: token,
                heading: index?.models.first(where: { $0.name == token })?.heading ?? token,
                source: EquipmentIdentity.Source.spoken.rawValue,
                statedModel: text(.model).flatMap { $0 == token ? nil : $0 })
        }
        let redactions = Array(Set(recording.redactions + cleaned.redactions)).sorted {
            let order = SecretPatterns.all.map(\.name)
            return (order.firstIndex(of: $0) ?? .max) < (order.firstIndex(of: $1) ?? .max)
        }
        return .success(LearningCandidate(
            origin: .recollection, sessionId: "recording-\(recording.id)", jobReference: nil, taskId: nil,
            vaultId: recording.vaultId, equipment: equipment, spokenModel: modelToken == nil ? spokenModel : nil,
            finding: cleaned.finding, symptom: cleaned.symptom, fix: cleaned.fix,
            tried: cleaned.tried, outcome: cleaned.outcome,
            evidence: LearningCandidate.Evidence(recording: self.recording),
            author: LearningCandidateText.author(author), createdAt: recording.createdAt,
            redactions: redactions))
    }
}

/// The site part of a recording, moved out of the learning (decision 6) into a draft for Plan HV's
/// site documents. It is never filed as, or inside, a learning candidate.
struct RecollectionSiteNote: Codable, Equatable, Sendable {
    let segment: RecollectionDraft.Span
    let text: String
    let spans: [RecollectionDraft.Span]
}
