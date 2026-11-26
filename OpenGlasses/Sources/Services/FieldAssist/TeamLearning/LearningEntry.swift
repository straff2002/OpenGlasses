import Foundation

/// An approved team learning (Plan FP P2) — what a named reviewer approved, and the only form of a
/// finding that ever answers a question.
///
/// **Field names follow `Contracts/team-learning.md` §5** (`entryID`, `subject`, `vaultIDs`,
/// `finding`/`symptom`/`fix`, `approvedAt`, `approvedByRole`, `authorIsApprover`,
/// `contradictsSafetyNote`, `supersedes`, `candidateID`) plus the 2026-10-09 amendment (`origin`,
/// `sourceJobIDs`, `confirmedJobCount`) and the 2026-11-25 crew-experience amendment (`faultCode`,
/// `tried`, `outcome`, origin `recollection`, the symptom subject — Plan NF P0), so P3's learning-set
/// codec is a straight mapping. What the
/// phone keeps beside them — the approver's name, the text as captured, and the supersession and
/// retraction stamps — is its own review history and is not part of the wire entry.
struct LearningEntry: Codable, Equatable, Identifiable {

    /// What the entry is about (contract §5): a machine by identity, a practice by topic, or (the
    /// crew-experience amendment, Plan IM decision 4) a symptom bounded by an equipment type from the
    /// vault's closed list.
    enum Subject: Equatable {
        case model(modelToken: String, manufacturer: String? = nil, equipmentType: String? = nil)
        case practice(topic: String)
        /// An equipment type alone, with the symptom phrase it was recorded under. It answers only
        /// within the turn's equipment type (`VaultRetriever.EquipmentTypeScope`, Plan IM P0).
        case symptom(equipmentType: String, phrase: String)

        /// The `<subject>` part of the citation name: the model token, the topic or the equipment
        /// type (§7.1).
        var citationSubject: String {
            switch self {
            case .model(let token, _, _): return token
            case .practice(let topic): return topic
            case .symptom(let equipmentType, _): return equipmentType
            }
        }

        /// The model token by identity, or nil for a practice entry.
        var modelToken: String? {
            if case .model(let token, _, _) = self { return token }
            return nil
        }
    }

    /// The text as the candidate carried it, kept beside the text as approved ("both texts kept").
    struct Texts: Codable, Equatable {
        let finding: String
        let symptom: String?
        let fix: String?
    }

    /// Contract limit on `approvedByRole`.
    static let roleLimit = 80

    /// 32 lowercase hex characters; never reused (contract §5).
    let id: String
    var subject: Subject
    /// The vaults whose answers may use this entry; empty means every vault (contract §5, §10.1).
    var vaultIDs: [String]
    /// As approved — which may differ from the text as captured.
    var finding: String
    var symptom: String?
    var fix: String?
    /// The fault code the case is about, as the display shows it (crew-experience amendment).
    var faultCode: String?
    /// What was checked or tried on the way to the fix (Plan IM decision 3).
    var tried: String?
    /// How sure the crew is, in their words ("fixed it most times"), never a number (IM decision 3).
    var outcome: String?
    let approvedAt: Date
    let approvedByRole: String
    let authorIsApprover: Bool
    var contradictsSafetyNote: Bool
    var supersedes: String?
    let candidateID: String?
    /// Where the finding came from (decided 2026-10-09).
    let origin: LearningCandidate.Origin
    /// Job identifiers only — never a customer, site or address.
    var sourceJobIDs: [String]?
    /// How many jobs it was *filed on* (not "resolved": that needs an outcome the app does not hold).
    /// A `recollection` was bound to no job: absent, which reads as 0.
    var confirmedJobCount: Int?

    // Phone-side review history, not part of the wire entry.

    /// Who approved it, by display name. The role is what the citation carries.
    let approvedByName: String
    /// The text as captured, when the reviewer changed it; nil when approved as written.
    let captured: Texts?
    var supersededAt: Date?
    var supersededBy: String?
    var retractedAt: Date?
    var retractionReason: String?

    init(id: String = LearningCandidate.newID(), subject: Subject, vaultIDs: [String],
         finding: String, symptom: String? = nil, fix: String? = nil,
         faultCode: String? = nil, tried: String? = nil, outcome: String? = nil,
         approvedAt: Date, approvedByRole: String, approvedByName: String,
         authorIsApprover: Bool = false, contradictsSafetyNote: Bool = false,
         supersedes: String? = nil, candidateID: String? = nil,
         origin: LearningCandidate.Origin = .spoken,
         sourceJobIDs: [String]? = nil, confirmedJobCount: Int? = nil,
         captured: Texts? = nil) {
        self.id = id
        self.subject = subject
        self.vaultIDs = vaultIDs
        self.finding = finding
        self.symptom = symptom
        self.fix = fix
        self.faultCode = faultCode
        self.tried = tried
        self.outcome = outcome
        self.approvedAt = approvedAt
        self.approvedByRole = approvedByRole
        self.approvedByName = approvedByName
        self.authorIsApprover = authorIsApprover
        self.contradictsSafetyNote = contradictsSafetyNote
        self.supersedes = supersedes
        self.candidateID = candidateID
        self.origin = origin
        self.sourceJobIDs = sourceJobIDs
        self.confirmedJobCount = confirmedJobCount
        self.captured = captured
    }

    /// Answers questions: neither superseded nor retracted.
    var isLive: Bool { supersededAt == nil && retractedAt == nil }

    /// The contract's §7.1 citation name, byte for byte:
    /// `Team learning · <modelToken or topic> · <YYYY-MM-DD UTC of approvedAt> · approved by <role>`,
    /// or for a `recollection` (the crew-experience amendment, Plan NF)
    /// `Crew experience · <subject> · <date> · approved by <role>`.
    var citationName: String { TeamLearningCitation.name(for: self) }

    /// A company's crew experience (origin `recollection`): cited and introduced as the company's
    /// experience, not as a finding seen on a job.
    var isCrewExperience: Bool { origin == .recollection }

    /// Whether this entry applies to `vaultId` by its own scope (empty `vaultIDs` = every vault).
    func isScoped(to vaultId: String) -> Bool { vaultIDs.isEmpty || vaultIDs.contains(vaultId) }

    enum CodingKeys: String, CodingKey {
        case id = "entryID"
        case subject, vaultIDs, finding, symptom, fix, faultCode, tried, outcome
        case approvedAt, approvedByRole, authorIsApprover
        case contradictsSafetyNote, supersedes, candidateID, origin, sourceJobIDs, confirmedJobCount
        case approvedByName, captured, supersededAt, supersededBy, retractedAt, retractionReason
    }
}

// MARK: - Subject coding (contract §5)

extension LearningEntry.Subject: Codable {
    private enum Keys: String, CodingKey { case kind, modelToken, manufacturer, equipmentType, topic, phrase }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "model":
            self = .model(modelToken: try c.decode(String.self, forKey: .modelToken),
                          manufacturer: try c.decodeIfPresent(String.self, forKey: .manufacturer),
                          equipmentType: try c.decodeIfPresent(String.self, forKey: .equipmentType))
        case "practice":
            self = .practice(topic: try c.decode(String.self, forKey: .topic))
        case "symptom":
            self = .symptom(equipmentType: try c.decode(String.self, forKey: .equipmentType),
                            phrase: try c.decode(String.self, forKey: .phrase))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c,
                                                   debugDescription: "unknown subject kind \(other)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .model(let token, let manufacturer, let equipmentType):
            try c.encode("model", forKey: .kind)
            try c.encode(token, forKey: .modelToken)
            try c.encodeIfPresent(manufacturer, forKey: .manufacturer)
            try c.encodeIfPresent(equipmentType, forKey: .equipmentType)
        case .practice(let topic):
            try c.encode("practice", forKey: .kind)
            try c.encode(topic, forKey: .topic)
        case .symptom(let equipmentType, let phrase):
            try c.encode("symptom", forKey: .kind)
            try c.encode(equipmentType, forKey: .equipmentType)
            try c.encode(phrase, forKey: .phrase)
        }
    }
}

/// The citation name both sides compute the same way (contract §7.1).
enum TeamLearningCitation {

    /// What every team-learning citation begins with. A citation that begins this way is a team
    /// learning's, never a manual title — the parser, the chips and the export all key on it.
    static let prefix = "Team learning · "
    /// What a crew-experience citation begins with (team-learning §11, Plan NF):
    /// `CrewExperienceSheet.citationPrefix`, the portal's own spelling.
    static let crewExperiencePrefix = CrewExperienceSheet.citationPrefix
    /// Every prefix a learning's citation can begin with.
    static let prefixes = [prefix, crewExperiencePrefix]

    static func name(subject: String, approvedAt: Date, role: String, crewExperience: Bool = false) -> String {
        (crewExperience ? crewExperiencePrefix : prefix) + "\(subject) · \(utcDate(approvedAt)) · approved by \(role)"
    }

    static func name(for entry: LearningEntry) -> String {
        name(subject: entry.subject.citationSubject, approvedAt: entry.approvedAt, role: entry.approvedByRole,
             crewExperience: entry.isCrewExperience)
    }

    /// Where in `text` the first learning citation (of either kind) begins, or nil.
    static func firstCitationRange(in text: String) -> Range<String.Index>? {
        prefixes.compactMap { text.range(of: $0) }.min { $0.lowerBound < $1.lowerBound }
    }

    /// Whether a citation name is a company's crew experience rather than a team learning.
    static func isCrewExperience(_ source: String) -> Bool {
        source.trimmingCharacters(in: .whitespaces).hasPrefix(crewExperiencePrefix)
    }

    /// `YYYY-MM-DD` in UTC, whatever the phone's own zone and calendar.
    static func utcDate(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        func pad(_ value: Int?, _ width: Int) -> String {
            let digits = String(value ?? 0)
            return String(repeating: "0", count: max(0, width - digits.count)) + digits
        }
        return "\(pad(parts.year, 4))-\(pad(parts.month, 2))-\(pad(parts.day, 2))"
    }

    /// Whether a citation or source line names a team learning.
    static func isTeamLearning(_ source: String) -> Bool {
        let trimmed = source.trimmingCharacters(in: .whitespaces)
        return prefixes.contains { trimmed.hasPrefix($0) }
    }
}
