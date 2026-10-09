import Foundation

/// A finding a technician filed for the team (Plan FP P1) — unreviewed text, and never an answer.
///
/// A candidate is one person's sentence from a plant room. It answers nobody's question, its own
/// author's included, until a named person has reviewed it and an approved entry made from it has
/// been published (FP §1, open question 2). Nothing on the phone retrieves a candidate for an
/// answer: `team_learning list` reading the author's own candidates back is the only read path.
///
/// **Field names follow `Contracts/team-learning.md` §3**, so the office envelope a later phase
/// signs is a re-spelling of this record rather than a translation of it: `candidateID`,
/// `jobSessionID`, `jobNumber`, `taskID`, `vaultID`, `modelToken`/`spokenModel`, `finding`,
/// `symptom`, `fix`, `evidence` as names and counts, `author` and `redactions`. The limits are the
/// contract's too, and are enforced at capture by `LearningCandidateText`. What the phone keeps
/// beside them — `status`, `origin`, the equipment's heading and source, `updatedAt` — is its own
/// bookkeeping and is not part of the wire shape.
struct LearningCandidate: Codable, Equatable, Identifiable {

    /// Where a candidate came from (decided 2026-10-09). The phone files only `spoken`; the other
    /// two are drafted at the office, and exist here so a bundle carrying them decodes.
    enum Origin: String, Codable, CaseIterable {
        /// Said on the job through `team_learning`.
        case spoken
        /// Cut from a completed job report by a person at the office.
        case report
        /// Drafted by the office's review pass over committed reports, for a person to approve.
        case reportReview
    }

    /// What has become of it. P1 produces `filed` and `withdrawn`. P3: `sent` when a bundle carrying
    /// it has left the phone (a confirmed delivery or a flushed queue — never when it is composed);
    /// `received`, `approved`, `merged` and `not_taken_up` when a decisions bundle saying so is
    /// accepted (contract §4), the reason travelling as `reviewReason`. On a reviewer's device an
    /// imported candidate starts `received`.
    enum Status: String, Codable, CaseIterable {
        /// On this phone, awaiting review.
        case filed
        /// The author took it back. The record stays; its text is emptied.
        case withdrawn
        case sent
        case received
        case approved
        case merged
        case notTakenUp = "not_taken_up"

        /// How the author hears it.
        var spoken: String {
            switch self {
            case .filed: return "filed, awaiting review"
            case .withdrawn: return "withdrawn"
            case .sent: return "sent, awaiting review"
            case .received: return "received at the office, awaiting review"
            case .approved: return "approved"
            case .merged: return "merged into an existing team learning"
            case .notTakenUp: return "not taken up"
            }
        }
    }

    /// The machine the finding is about, as the session had it resolved. Never the nameplate
    /// text: that is kept on the session for audit and is deliberately never carried anywhere else.
    struct Equipment: Codable, Equatable {
        let modelToken: String
        let heading: String
        let source: String
        /// What the technician called it, when that differs from the token.
        let statedModel: String?

        init(modelToken: String, heading: String, source: String, statedModel: String? = nil) {
            self.modelToken = modelToken
            self.heading = heading
            self.source = source
            self.statedModel = statedModel
        }

        init(_ identity: EquipmentIdentity) {
            self.init(modelToken: identity.modelToken, heading: identity.heading,
                      source: identity.source.rawValue, statedModel: identity.statedModel)
        }
    }

    /// The evidence in force when it was filed, as the contract carries it: the pages and
    /// citations by name, the readings and photos by count. No reading value, no photo.
    struct Evidence: Codable, Equatable {
        let pagesVerified: [String]
        let citationsOpened: [String]
        let readings: Int
        let photos: Int

        init(pagesVerified: [String] = [], citationsOpened: [String] = [], readings: Int = 0, photos: Int = 0) {
            self.pagesVerified = pagesVerified
            self.citationsOpened = citationsOpened
            self.readings = readings
            self.photos = photos
        }

        /// A copy of the task's — or, with no task running, the job's — evidence at filing time.
        init(_ evidence: FieldSession.Evidence) {
            self.init(pagesVerified: evidence.pagesVerified, citationsOpened: evidence.citationsOpened,
                      readings: evidence.readings.count, photos: evidence.photos.count)
        }
    }

    /// 32 lowercase hex characters, stable across revisions (contract §3).
    let id: String
    let origin: Origin
    /// Starts at 1; every amend and the withdrawal raise it.
    var revision: Int
    var status: Status
    let sessionId: String
    let jobReference: String?
    let taskId: String?
    let vaultId: String
    /// The identity in force when it was filed; nil when none had been resolved.
    let equipment: Equipment?
    /// What the technician called the machine when no identity was resolved.
    let spokenModel: String?
    var finding: String
    var symptom: String?
    var fix: String?
    let evidence: Evidence
    let author: String
    let createdAt: Date
    var updatedAt: Date
    /// Names of the redaction patterns that fired, never the text they matched.
    var redactions: [String]
    /// The approved entry it became or was merged into (contract §4 `entryID`), once reviewed.
    var entryID: String?
    /// The reviewer's words for the author when it was not taken up (contract §4 `reason`).
    var reviewReason: String?
    /// Where a candidate on a reviewer's device came from, when it arrived in a bundle rather than
    /// being filed here (Plan FP P3). Nil for every candidate this phone filed itself. An imported
    /// candidate is reviewed exactly like a local one — arriving is not approval.
    var importedFrom: String?

    init(id: String = LearningCandidate.newID(), origin: Origin = .spoken, revision: Int = 1,
         status: Status = .filed, sessionId: String, jobReference: String?, taskId: String?,
         vaultId: String, equipment: Equipment?, spokenModel: String?, finding: String,
         symptom: String?, fix: String?, evidence: Evidence, author: String,
         createdAt: Date, updatedAt: Date? = nil, redactions: [String]) {
        self.id = id
        self.origin = origin
        self.revision = revision
        self.status = status
        self.sessionId = sessionId
        self.jobReference = jobReference
        self.taskId = taskId
        self.vaultId = vaultId
        self.equipment = equipment
        self.spokenModel = spokenModel
        self.finding = finding
        self.symptom = symptom
        self.fix = fix
        self.evidence = evidence
        self.author = author
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.redactions = redactions
    }

    /// The contract's identifier: a UUID's 128 bits as 32 lowercase hex characters.
    static func newID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// The contract's `withdrawn` flag.
    var withdrawn: Bool { status == .withdrawn }

    var modelToken: String? { equipment?.modelToken }

    /// The handle a technician can say: the first six characters of the id.
    var shortHandle: String { String(id.prefix(6)) }

    /// What the job record carries about it — its existence, never its words.
    var reference: LearningCandidateReference { reference(inUse: false) }

    /// The same, saying whether an approved entry made from it now answers on this phone.
    func reference(inUse: Bool) -> LearningCandidateReference {
        LearningCandidateReference(candidateId: id, status: status, modelToken: modelToken,
                                   createdAt: createdAt, inUse: inUse)
    }

    /// Filed on this phone, not imported from another.
    var isLocal: Bool { importedFrom == nil }

    enum CodingKeys: String, CodingKey {
        case id = "candidateID"
        case origin, revision, status
        case sessionId = "jobSessionID"
        case jobReference = "jobNumber"
        case taskId = "taskID"
        case vaultId = "vaultID"
        case equipment, spokenModel, finding, symptom, fix, evidence, author
        case createdAt, updatedAt, redactions
        case entryID, reviewReason, importedFrom
    }
}

/// That an observation was filed on a job, and where it stands — carried on the session and folded
/// into the job's `WorkRecord` (Plan FP §1).
///
/// The id, the status, the machine and the date, **never the text**: the record shows that a
/// finding was filed and that it is not in use, without the finding itself travelling with the job.
/// Internal to the organisation, like the model-usage line beside it: no customer summary, no
/// printed work-order line and no customer-audience export carries it (contract §8).
struct LearningCandidateReference: Codable, Equatable {
    let candidateId: String
    var status: LearningCandidate.Status
    let modelToken: String?
    let createdAt: Date
    /// Whether an answer can draw on it. A candidate answers nothing; this turns true only when an
    /// approved entry made from it (or merged into) has been accepted on this phone (P3).
    var inUse: Bool = false

    init(candidateId: String, status: LearningCandidate.Status, modelToken: String?, createdAt: Date,
         inUse: Bool = false) {
        self.candidateId = candidateId
        self.status = status
        self.modelToken = modelToken
        self.createdAt = createdAt
        self.inUse = inUse
    }

    enum CodingKeys: String, CodingKey {
        case candidateId = "candidate_id"
        case status
        case modelToken = "model_token"
        case createdAt = "created_at"
        case inUse = "in_use"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        candidateId = try c.decode(String.self, forKey: .candidateId)
        status = try c.decode(LearningCandidate.Status.self, forKey: .status)
        modelToken = try c.decodeIfPresent(String.self, forKey: .modelToken)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        inUse = try c.decodeIfPresent(Bool.self, forKey: .inUse) ?? false
    }
}

/// The contract's text rules, applied at capture (contract §3, §7.4).
///
/// Pure, so every refusal is a test. The order is the design: the text is normalised first, then
/// redacted, then measured — the limits apply to what is stored and would be sent, which is the
/// redacted text.
///
/// **Normalised, then refused.** A tab and a carriage return are how dictation and keyboards break
/// lines, so they become a space and a line feed; a line feed survives inside `finding` only and
/// becomes a space elsewhere. Every other control character — and the bidirectional overrides,
/// which can make text read differently from how it is stored — is refused with the reason,
/// rather than silently removed, because text the technician did not mean to say is text they
/// should hear about.
///
/// **Lengths are counted in Unicode scalars**, which is never fewer than the characters a person
/// sees, so text this side accepts cannot be over a limit the other side counts differently.
enum LearningCandidateText {

    static let findingLimit = 2_000
    static let fieldLimit = 500
    static let authorLimit = 120

    enum Field: String, Equatable {
        case finding, symptom, fix

        var spoken: String {
            switch self {
            case .finding: return "finding"
            case .symptom: return "symptom"
            case .fix: return "fix"
            }
        }
    }

    enum Refusal: Error, Equatable {
        case missingFinding
        case tooLong(Field, count: Int, limit: Int)
        case controlCharacter(Field)

        /// The sentence the technician hears. Nothing was filed when they hear it.
        var spoken: String {
            switch self {
            case .missingFinding:
                return "Nothing was filed: a team learning needs the finding itself — say what you worked out."
            case .tooLong(let field, let count, let limit):
                let advice = field == .finding
                    ? "Say it more briefly, or file it as two learnings."
                    : "Say it more briefly."
                return "Nothing was filed: the \(field.spoken) is \(count.formatted()) characters, and a team "
                    + "learning's \(field.spoken) can be at most \(limit.formatted()). \(advice)"
            case .controlCharacter(let field):
                return "Nothing was filed: the \(field.spoken) contains a control character that can't go into "
                    + "a team learning. Say it again as plain text."
            }
        }
    }

    /// The fields as they will be stored, and the names of the redaction patterns that fired.
    struct Cleaned: Equatable {
        let finding: String
        let symptom: String?
        let fix: String?
        let redactions: [String]
    }

    /// Validate and redact one capture. Symptom and fix are optional; empty is absent.
    static func clean(finding rawFinding: String?, symptom rawSymptom: String?,
                      fix rawFix: String?) -> Result<Cleaned, Refusal> {
        var fired: [String] = []
        func process(_ raw: String?, _ field: Field) -> Result<String?, Refusal> {
            guard let raw else { return .success(nil) }
            switch normalise(raw, field: field) {
            case .failure(let refusal): return .failure(refusal)
            case .success(let text):
                guard !text.isEmpty else { return .success(nil) }
                let (redacted, hits) = SecretPatterns.redact(text)
                for hit in hits where !fired.contains(hit) { fired.append(hit) }
                let limit = field == .finding ? findingLimit : fieldLimit
                let count = length(redacted)
                guard count <= limit else { return .failure(.tooLong(field, count: count, limit: limit)) }
                return .success(redacted)
            }
        }
        let finding: String?
        switch process(rawFinding, .finding) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let value): finding = value
        }
        guard let finding else { return .failure(.missingFinding) }
        let symptom: String?
        switch process(rawSymptom, .symptom) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let value): symptom = value
        }
        let fix: String?
        switch process(rawFix, .fix) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let value): fix = value
        }
        // In `SecretPatterns.all` order whatever order the fields fired in, so the same text always
        // records the same list.
        let order = SecretPatterns.all.map(\.name)
        let redactions = fired.sorted { (order.firstIndex(of: $0) ?? .max) < (order.firstIndex(of: $1) ?? .max) }
        return .success(Cleaned(finding: finding, symptom: symptom, fix: fix, redactions: redactions))
    }

    /// Tabs to spaces, carriage returns to line feeds, line feeds to spaces outside `finding`;
    /// refuse anything else in the control range; trim the ends.
    static func normalise(_ raw: String, field: Field) -> Result<String, Refusal> {
        let unified = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\t", with: " ")
        var scalars = String.UnicodeScalarView()
        for scalar in unified.unicodeScalars {
            if scalar == "\n" {
                scalars.append(field == .finding ? scalar : " ")
                continue
            }
            if isRefused(scalar) { return .failure(.controlCharacter(field)) }
            scalars.append(scalar)
        }
        return .success(String(scalars).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The general category Cc, plus the bidirectional embedding, override and isolate controls.
    static func isRefused(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.generalCategory == .control { return true }
        switch scalar.value {
        case 0x202A...0x202E, 0x2066...0x2069: return true
        default: return false
        }
    }

    /// The contract's measure.
    static func length(_ text: String) -> Int { text.unicodeScalars.count }

    /// The author's name as the contract wants it: plain, 1–120 characters. A name that cleans to
    /// nothing becomes "Technician" rather than leaving the field empty.
    static func author(_ raw: String) -> String {
        let plain = String(String.UnicodeScalarView(raw.unicodeScalars.map { isRefused($0) ? " " : $0 }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plain.isEmpty else { return "Technician" }
        var scalars = String.UnicodeScalarView()
        for scalar in plain.unicodeScalars.prefix(authorLimit) { scalars.append(scalar) }
        return String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// How a fired pattern is named out loud.
    static func spokenName(forPattern name: String) -> String {
        switch name {
        case "email": return "an email address"
        case "nz_ird": return "an IRD number"
        default: return "a credential"
        }
    }
}
