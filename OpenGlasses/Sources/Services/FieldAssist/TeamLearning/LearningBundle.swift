import Foundation

/// The unsigned, reviewed team-learning bundle (Plan FP P3) — how candidates travel from field
/// phones to a reviewer, and decisions and approved entries travel back, for an organisation with
/// no office.
///
/// **Shape.** One closed JSON object:
///
///     { schemaVersion: 1, kind: "avenkin.learning-bundle", direction: "candidates" | "decisions",
///       organisationLabel?, issuedAt, sequence?,
///       candidates: [...], statuses: [...], entries: [...], retracted: [...] }
///
/// The four arrays are the contract's own payloads (`Contracts/team-learning.md`): a candidate in
/// §3's shape, a status in §4's, an entry and a retraction in §5's. The binding fields the office
/// envelopes carry per item (`organizationID`, `enrolmentID`, `officeID`, `generation`) and the
/// per-item `version`/`kind` are absent: a crew has no binding, and the version and kind are said
/// once, on the bundle. So the codable items here are what the signed office envelopes wrap when
/// that route is built — re-spelt, not translated. A `candidates` bundle carries candidates and
/// nothing else; a `decisions` bundle carries statuses, entries and retractions and no candidate.
///
/// **No signature, by design.** A crew cannot sign: the only key the app trusts for signed content
/// is the vendor's, whose private half is off-repo, and an organisation without an office holds no
/// key of its own. So a bundle is attributed by nothing and is **untrusted input** (FP §2, Plan R):
/// `decode(_:)` validates structure only — closed objects, no duplicate or unknown keys, plain
/// integers, the contract's text rules and length caps, a 2 MiB ceiling — and refuses the whole
/// bundle, by a named reason, at the first thing wrong. Nothing in a bundle is ever applied
/// because it decoded: candidates go through `LearningReview` like local ones, and a decisions
/// bundle is staged by `LearningBundleIntake` until each entry is accepted. The signed route is the
/// office contract, not this.
struct LearningBundle: Equatable {

    static let schemaVersion: Int64 = 1
    static let kind = "avenkin.learning-bundle"
    /// The contract's ceiling for a whole learning set (§2), applied to a bundle too.
    static let maximumBytes = 2 * 1024 * 1024
    /// The session id a bundle's queued op and delivery are filed under. A bundle belongs to no
    /// job; this keeps it out of every per-job count.
    static let queueSessionID = "team-learning"

    enum Direction: String, Codable, CaseIterable, Equatable {
        /// Field phone → reviewer: candidates for review.
        case candidates
        /// Reviewer → field phones: statuses, approved entries and retractions.
        case decisions
    }

    /// A candidate as it travels (contract §3, plus the 2026-10-09 `origin`).
    struct Candidate: Codable, Equatable {
        var candidateID: String
        var revision: Int64
        var withdrawn: Bool
        var origin: LearningCandidate.Origin
        var jobSessionID: String
        var jobNumber: String?
        var taskID: String?
        var createdAt: Int64
        var author: String
        var vaultID: String
        var modelToken: String?
        var spokenModel: String?
        var finding: String
        var symptom: String?
        var fix: String?
        var evidence: LearningCandidate.Evidence
        var redactions: [String]
    }

    /// The reviewer's answer about one candidate (contract §4).
    enum Decision: String, Codable, CaseIterable, Equatable {
        case received
        case approved
        case merged
        case notTakenUp = "not_taken_up"

        var candidateStatus: LearningCandidate.Status {
            switch self {
            case .received: return .received
            case .approved: return .approved
            case .merged: return .merged
            case .notTakenUp: return .notTakenUp
            }
        }

        /// `approved`, `merged` and `not_taken_up` are final for the candidate (§4).
        var isFinal: Bool { self != .received }
    }

    struct Status: Codable, Equatable {
        var candidateID: String
        var revision: Int64
        var status: Decision
        var entryID: String?
        var reason: String?
        var issuedAt: Int64
    }

    /// An approved entry as it travels (contract §5, plus the amendment's three fields).
    struct Entry: Codable, Equatable {
        var entryID: String
        var subject: LearningEntry.Subject
        var vaultIDs: [String]
        var finding: String
        var symptom: String?
        var fix: String?
        var approvedAt: Int64
        var approvedByRole: String
        var authorIsApprover: Bool
        var contradictsSafetyNote: Bool
        var supersedes: String?
        var candidateID: String?
        var origin: LearningCandidate.Origin?
        var sourceJobIDs: [String]?
        var confirmedJobCount: Int64?
    }

    /// An entry withdrawn after publication (§5 `retracted[]`): kept so a phone can say why an
    /// answer it once gave is gone, and a tombstone that beats content whatever its timestamp.
    struct Retraction: Codable, Equatable {
        var entryID: String
        var retractedAt: Int64
        var reason: String
    }

    var direction: Direction
    /// Which organisation the bundle says it is from, for a person to read. Not authority: anyone
    /// can write any label.
    var organisationLabel: String?
    var issuedAt: Int64
    /// An issuer's own counter, when it keeps one; compared before `issuedAt` for ordering.
    var sequence: Int64?
    var candidates: [Candidate]
    var statuses: [Status]
    var entries: [Entry]
    var retracted: [Retraction]

    init(direction: Direction, organisationLabel: String? = nil, issuedAt: Int64, sequence: Int64? = nil,
         candidates: [Candidate] = [], statuses: [Status] = [], entries: [Entry] = [],
         retracted: [Retraction] = []) {
        self.direction = direction
        self.organisationLabel = organisationLabel
        self.issuedAt = issuedAt
        self.sequence = sequence
        self.candidates = candidates
        self.statuses = statuses
        self.entries = entries
        self.retracted = retracted
    }

    var issuedDate: Date { Date(timeIntervalSince1970: TimeInterval(issuedAt)) }

    /// Nothing in it.
    var isEmpty: Bool { candidates.isEmpty && statuses.isEmpty && entries.isEmpty && retracted.isEmpty }

    /// The file a bundle travels as: `team-learning-<direction>-<yyyyMMdd-HHmm>.json`, the time
    /// being `issuedAt` in UTC so the same bundle always has the same name.
    var fileName: String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let p = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: issuedDate)
        func pad(_ v: Int?, _ w: Int) -> String {
            let d = String(v ?? 0)
            return String(repeating: "0", count: max(0, w - d.count)) + d
        }
        let stamp = "\(pad(p.year, 4))\(pad(p.month, 2))\(pad(p.day, 2))-\(pad(p.hour, 2))\(pad(p.minute, 2))"
        return "team-learning-\(direction.rawValue)-\(stamp).json"
    }
}

// MARK: - Mapping to and from the phone's records

extension LearningBundle.Candidate {

    init(_ candidate: LearningCandidate) {
        // An empty optional is left out rather than sent empty: the closed schema refuses `""` for
        // an identifier, and absent is what the contract means by it.
        func present(_ value: String?) -> String? { value.flatMap { $0.isEmpty ? nil : $0 } }
        self.init(candidateID: candidate.id, revision: Int64(candidate.revision), withdrawn: candidate.withdrawn,
                  origin: candidate.origin, jobSessionID: candidate.sessionId, jobNumber: present(candidate.jobReference),
                  taskID: present(candidate.taskId), createdAt: Int64(candidate.createdAt.timeIntervalSince1970.rounded(.down)),
                  author: candidate.author, vaultID: candidate.vaultId, modelToken: present(candidate.modelToken),
                  spokenModel: present(candidate.spokenModel), finding: candidate.finding,
                  symptom: candidate.withdrawn ? nil : present(candidate.symptom),
                  fix: candidate.withdrawn ? nil : present(candidate.fix),
                  evidence: candidate.evidence, redactions: candidate.redactions)
    }

    /// The candidate as the reviewer's store keeps it: `received`, its origin preserved, and a
    /// note of where it came from. The equipment carries the token alone — the heading and the
    /// recognition source stayed on the author's phone.
    func candidate(importedFrom note: String) -> LearningCandidate {
        let created = Date(timeIntervalSince1970: TimeInterval(createdAt))
        var candidate = LearningCandidate(
            id: candidateID, origin: origin, revision: Int(revision),
            status: withdrawn ? .withdrawn : .received, sessionId: jobSessionID, jobReference: jobNumber,
            taskId: taskID, vaultId: vaultID,
            equipment: modelToken.map { LearningCandidate.Equipment(modelToken: $0, heading: $0, source: "bundle") },
            spokenModel: spokenModel, finding: finding, symptom: symptom, fix: fix, evidence: evidence,
            author: author, createdAt: created, updatedAt: created, redactions: redactions)
        candidate.importedFrom = note
        return candidate
    }
}

extension LearningBundle.Entry {

    init(_ entry: LearningEntry) {
        self.init(entryID: entry.id, subject: entry.subject, vaultIDs: entry.vaultIDs, finding: entry.finding,
                  symptom: entry.symptom, fix: entry.fix,
                  approvedAt: Int64(entry.approvedAt.timeIntervalSince1970.rounded(.down)),
                  approvedByRole: entry.approvedByRole, authorIsApprover: entry.authorIsApprover,
                  contradictsSafetyNote: entry.contradictsSafetyNote, supersedes: entry.supersedes,
                  candidateID: entry.candidateID, origin: entry.origin, sourceJobIDs: entry.sourceJobIDs,
                  confirmedJobCount: entry.confirmedJobCount.map(Int64.init))
    }

    /// The entry as a receiving phone keeps it. The approver's name does not travel — the role is
    /// what the citation carries — so the history names the role.
    func entry() -> LearningEntry {
        LearningEntry(id: entryID, subject: subject, vaultIDs: vaultIDs, finding: finding, symptom: symptom,
                      fix: fix, approvedAt: Date(timeIntervalSince1970: TimeInterval(approvedAt)),
                      approvedByRole: approvedByRole, approvedByName: approvedByRole,
                      authorIsApprover: authorIsApprover, contradictsSafetyNote: contradictsSafetyNote,
                      supersedes: supersedes, candidateID: candidateID, origin: origin ?? .spoken,
                      sourceJobIDs: sourceJobIDs, confirmedJobCount: confirmedJobCount.map { Int($0) })
    }
}

extension LearningBundle.Retraction {
    init?(_ entry: LearningEntry) {
        guard let at = entry.retractedAt else { return nil }
        self.init(entryID: entry.id, retractedAt: Int64(at.timeIntervalSince1970.rounded(.down)),
                  reason: entry.retractionReason ?? "")
    }

    var retractedDate: Date { Date(timeIntervalSince1970: TimeInterval(retractedAt)) }
}

// MARK: - Codable (closed, explicit keys)

extension LearningBundle: Codable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, kind, direction, organisationLabel, issuedAt, sequence
        case candidates, statuses, entries, retracted
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        direction = try c.decode(Direction.self, forKey: .direction)
        organisationLabel = try c.decodeIfPresent(String.self, forKey: .organisationLabel)
        issuedAt = try c.decode(Int64.self, forKey: .issuedAt)
        sequence = try c.decodeIfPresent(Int64.self, forKey: .sequence)
        candidates = try c.decode([Candidate].self, forKey: .candidates)
        statuses = try c.decode([Status].self, forKey: .statuses)
        entries = try c.decode([Entry].self, forKey: .entries)
        retracted = try c.decode([Retraction].self, forKey: .retracted)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.schemaVersion, forKey: .schemaVersion)
        try c.encode(Self.kind, forKey: .kind)
        try c.encode(direction, forKey: .direction)
        try c.encodeIfPresent(organisationLabel, forKey: .organisationLabel)
        try c.encode(issuedAt, forKey: .issuedAt)
        try c.encodeIfPresent(sequence, forKey: .sequence)
        try c.encode(candidates, forKey: .candidates)
        try c.encode(statuses, forKey: .statuses)
        try c.encode(entries, forKey: .entries)
        try c.encode(retracted, forKey: .retracted)
    }

    /// The bytes a bundle travels as. Sorted keys, so the same bundle is the same bytes.
    func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)) ?? Data()
    }
}

// MARK: - Decoding untrusted bytes

extension LearningBundle {

    /// Why a bundle was refused — always the whole bundle, never part of it.
    enum Refusal: Error, Equatable {
        case tooLarge(bytes: Int)
        case truncated
        case malformed
        case duplicateKey(String)
        case nonIntegerNumber
        case unknownVersion
        case unknownKind
        case unknownKey(String)
        case missingKey(String)
        case wrongType(String)
        case outOfRange(String)
        case invalidIdentifier(String)
        case controlCharacter(String)
        case tooLong(String, count: Int, limit: Int)
        case empty(String)
        case directionMismatch
        case duplicateItem(String)
        /// Older than one already applied for the same organisation label and direction.
        case reordered

        /// For whoever opened the file. Nothing from the bundle was applied when they read it.
        var message: String {
            let lead = "This team-learning file was not opened, and nothing in it was used: "
            switch self {
            case .tooLarge(let bytes):
                return lead + "it is \(bytes.formatted()) bytes, over the \(LearningBundle.maximumBytes.formatted())-byte limit."
            case .truncated: return lead + "it ends part-way through — it may not have finished downloading."
            case .malformed: return lead + "it isn't a readable team-learning file."
            case .duplicateKey(let key): return lead + "it names \u{201C}\(key)\u{201D} twice in one place."
            case .nonIntegerNumber: return lead + "it holds a number that isn't a whole number in range."
            case .unknownVersion: return lead + "it was made by a version of the app this one doesn't understand."
            case .unknownKind: return lead + "it isn't a team-learning file."
            case .unknownKey(let path): return lead + "it carries \u{201C}\(path)\u{201D}, which a team-learning file doesn't have."
            case .missingKey(let path): return lead + "\u{201C}\(path)\u{201D} is missing."
            case .wrongType(let path), .outOfRange(let path), .invalidIdentifier(let path):
                return lead + "\u{201C}\(path)\u{201D} isn't valid."
            case .controlCharacter(let path): return lead + "\u{201C}\(path)\u{201D} contains a control character."
            case .tooLong(let path, let count, let limit):
                return lead + "\u{201C}\(path)\u{201D} is \(count.formatted()) characters; the limit is \(limit.formatted())."
            case .empty(let path): return lead + "\u{201C}\(path)\u{201D} is empty."
            case .directionMismatch:
                return lead + "it mixes findings for review with decisions, which one file never does."
            case .duplicateItem(let id): return lead + "it lists \(id.prefix(6)) twice."
            case .reordered:
                return lead + "it is older than one from the same organisation already applied on this phone."
            }
        }
    }

    /// A bundle that passed every structural check, with its incoming text redacted.
    struct Decoded: Equatable {
        let bundle: LearningBundle
        /// The redaction patterns that fired on the incoming text, in `SecretPatterns.all` order.
        let redactionsOnIntake: [String]
    }

    /// Validate untrusted bytes. Structure only — nothing is applied, and a bundle that decodes is
    /// still data: its text is shown and retrieved as literal text, never followed.
    static func decode(_ data: Data) -> Result<Decoded, Refusal> {
        guard data.count <= maximumBytes else { return .failure(.tooLarge(bytes: data.count)) }
        let tree: LearningBundleJSON.Value
        switch LearningBundleJSON.parse(data) {
        case .failure(.truncated): return .failure(.truncated)
        case .failure(.duplicateKey(let key)): return .failure(.duplicateKey(key))
        case .failure(.nonIntegerNumber): return .failure(.nonIntegerNumber)
        case .failure: return .failure(.malformed)
        case .success(let value): tree = value
        }
        guard case .object = tree else { return .failure(.malformed) }
        // Version and kind first: a later version may add keys, and must be refused as a version,
        // not reported as an unknown key.
        guard tree["schemaVersion"] == .integer(schemaVersion) else { return .failure(.unknownVersion) }
        guard tree["kind"] == .string(kind) else { return .failure(.unknownKind) }
        if let refusal = LearningBundleSchema.bundle.check(tree, path: "") { return .failure(refusal) }

        let bundle: LearningBundle
        do {
            bundle = try JSONDecoder().decode(LearningBundle.self, from: data)
        } catch {
            return .failure(.malformed)
        }
        if let refusal = semanticProblem(bundle) { return .failure(refusal) }
        return .success(redactingIncoming(bundle))
    }

    /// What the schema cannot say: which arrays a direction may fill, no item twice, a withdrawn
    /// candidate's text empty and a live one's present, and an `approved`/`merged` status naming
    /// its entry.
    private static func semanticProblem(_ bundle: LearningBundle) -> Refusal? {
        switch bundle.direction {
        case .candidates:
            guard bundle.statuses.isEmpty, bundle.entries.isEmpty, bundle.retracted.isEmpty else {
                return .directionMismatch
            }
        case .decisions:
            guard bundle.candidates.isEmpty else { return .directionMismatch }
        }
        func firstDuplicate(_ ids: [String]) -> String? {
            var seen = Set<String>()
            return ids.first { !seen.insert($0).inserted }
        }
        if let id = firstDuplicate(bundle.candidates.map(\.candidateID)) { return .duplicateItem(id) }
        if let id = firstDuplicate(bundle.statuses.map(\.candidateID)) { return .duplicateItem(id) }
        if let id = firstDuplicate(bundle.entries.map(\.entryID)) { return .duplicateItem(id) }
        if let id = firstDuplicate(bundle.retracted.map(\.entryID)) { return .duplicateItem(id) }
        for (index, candidate) in bundle.candidates.enumerated() {
            let path = "candidates[\(index)]"
            if candidate.withdrawn {
                guard candidate.finding.isEmpty, candidate.symptom.map(\.isEmpty) ?? true,
                      candidate.fix.map(\.isEmpty) ?? true else { return .outOfRange(path + ".withdrawn") }
            } else if candidate.finding.isEmpty {
                return .empty(path + ".finding")
            }
        }
        for (index, status) in bundle.statuses.enumerated() {
            let path = "statuses[\(index)]"
            switch status.status {
            case .approved, .merged:
                guard status.entryID != nil else { return .missingKey(path + ".entryID") }
            case .received, .notTakenUp:
                guard status.entryID == nil else { return .unknownKey(path + ".entryID") }
            }
            if status.status != .notTakenUp, status.reason != nil { return .unknownKey(path + ".reason") }
        }
        return nil
    }

    /// `SecretPatterns.redact` over every incoming text field — a floor, as it is at capture —
    /// recording the names that fired. A candidate's own `redactions` gain them, so its stored
    /// text and its stored names cannot disagree.
    private static func redactingIncoming(_ bundle: LearningBundle) -> Decoded {
        var fired: [String] = []
        func clean(_ text: String, into hits: inout [String]) -> String {
            let (redacted, found) = SecretPatterns.redact(text)
            for hit in found where !fired.contains(hit) { fired.append(hit) }
            for hit in found where !hits.contains(hit) { hits.append(hit) }
            return redacted
        }
        func clean(optional text: String?, into hits: inout [String]) -> String? {
            text.map { clean($0, into: &hits) }
        }
        var out = bundle
        for index in out.candidates.indices {
            var hits: [String] = []
            var c = out.candidates[index]
            c.finding = clean(c.finding, into: &hits)
            c.symptom = clean(optional: c.symptom, into: &hits)
            c.fix = clean(optional: c.fix, into: &hits)
            c.spokenModel = clean(optional: c.spokenModel, into: &hits)
            for hit in hits where !c.redactions.contains(hit) { c.redactions.append(hit) }
            c.redactions = ordered(c.redactions)
            out.candidates[index] = c
        }
        var ignored: [String] = []
        for index in out.entries.indices {
            var e = out.entries[index]
            e.finding = clean(e.finding, into: &ignored)
            e.symptom = clean(optional: e.symptom, into: &ignored)
            e.fix = clean(optional: e.fix, into: &ignored)
            out.entries[index] = e
        }
        for index in out.statuses.indices {
            out.statuses[index].reason = clean(optional: out.statuses[index].reason, into: &ignored)
        }
        for index in out.retracted.indices {
            out.retracted[index].reason = clean(out.retracted[index].reason, into: &ignored)
        }
        return Decoded(bundle: out, redactionsOnIntake: ordered(fired))
    }

    /// Pattern names in `SecretPatterns.all` order, whatever order they fired in.
    static func ordered(_ names: [String]) -> [String] {
        let order = SecretPatterns.all.map(\.name)
        return names.sorted { (order.firstIndex(of: $0) ?? .max) < (order.firstIndex(of: $1) ?? .max) }
    }
}

// MARK: - The closed schema

/// What each object in a bundle may hold: its keys (and nothing else), their types, and the
/// contract's limits. Walked over the strict parse before any decoder reads the bytes.
enum LearningBundleSchema {

    indirect enum FieldType {
        /// Plain text: no control character (a line feed only where `lineFeeds`), at most `limit`
        /// Unicode scalars, and at least `minimum`.
        case text(minimum: Int, limit: Int, lineFeeds: Bool)
        /// 32 lowercase hex characters (contract §3, §5).
        case hexIdentifier
        /// One of a fixed set of strings.
        case oneOf(Set<String>)
        case integer(minimum: Int64)
        case bool
        case texts(itemLimit: Int, maximumCount: Int)
        case object(Object)
        case objects(Object)
        /// The entry's subject: `{kind: model, modelToken, manufacturer?, equipmentType?}` or
        /// `{kind: practice, topic}` — chosen by `kind`.
        case subject
    }

    struct Field {
        let type: FieldType
        let required: Bool
    }

    struct Object {
        let fields: [String: Field]

        func check(_ value: LearningBundleJSON.Value, path: String) -> LearningBundle.Refusal? {
            guard case .object(let pairs) = value else { return .wrongType(path.isEmpty ? "bundle" : path) }
            func join(_ key: String) -> String { path.isEmpty ? key : "\(path).\(key)" }
            for (key, _) in pairs where fields[key] == nil { return .unknownKey(join(key)) }
            for key in fields.keys.sorted() {
                guard let field = fields[key] else { continue }
                guard let child = value[key] else {
                    if field.required { return .missingKey(join(key)) }
                    continue
                }
                if case .null = child {
                    // An optional field is left out, never written as null.
                    return .wrongType(join(key))
                }
                if let refusal = LearningBundleSchema.check(child, as: field.type, path: join(key)) { return refusal }
            }
            return nil
        }
    }

    static func check(_ value: LearningBundleJSON.Value, as type: FieldType, path: String) -> LearningBundle.Refusal? {
        switch type {
        case .text(let minimum, let limit, let lineFeeds):
            guard case .string(let text) = value else { return .wrongType(path) }
            return textProblem(text, minimum: minimum, limit: limit, lineFeeds: lineFeeds, path: path)
        case .hexIdentifier:
            guard case .string(let text) = value else { return .wrongType(path) }
            return isHexIdentifier(text) ? nil : .invalidIdentifier(path)
        case .oneOf(let allowed):
            guard case .string(let text) = value else { return .wrongType(path) }
            return allowed.contains(text) ? nil : .outOfRange(path)
        case .integer(let minimum):
            guard case .integer(let number) = value else { return .wrongType(path) }
            return number >= minimum ? nil : .outOfRange(path)
        case .bool:
            guard case .bool = value else { return .wrongType(path) }
            return nil
        case .texts(let itemLimit, let maximumCount):
            guard case .array(let items) = value else { return .wrongType(path) }
            guard items.count <= maximumCount else { return .outOfRange(path) }
            for (index, item) in items.enumerated() {
                if let refusal = check(item, as: .text(minimum: 1, limit: itemLimit, lineFeeds: false),
                                       path: "\(path)[\(index)]") { return refusal }
            }
            return nil
        case .object(let object):
            return object.check(value, path: path)
        case .objects(let object):
            guard case .array(let items) = value else { return .wrongType(path) }
            for (index, item) in items.enumerated() {
                if let refusal = object.check(item, path: "\(path)[\(index)]") { return refusal }
            }
            return nil
        case .subject:
            switch value["kind"] {
            case .string("model"): return modelSubject.check(value, path: path)
            case .string("practice"): return practiceSubject.check(value, path: path)
            case nil: return .missingKey("\(path).kind")
            default: return .outOfRange("\(path).kind")
            }
        }
    }

    /// The contract's text rule (§7.4): a line feed only where allowed; every other control
    /// character, and the bidirectional overrides, refused; lengths in Unicode scalars.
    static func textProblem(_ text: String, minimum: Int, limit: Int, lineFeeds: Bool,
                            path: String) -> LearningBundle.Refusal? {
        for scalar in text.unicodeScalars {
            if scalar == "\n", lineFeeds { continue }
            if LearningCandidateText.isRefused(scalar) { return .controlCharacter(path) }
        }
        let count = LearningCandidateText.length(text)
        if count < minimum { return .empty(path) }
        if count > limit { return .tooLong(path, count: count, limit: limit) }
        return nil
    }

    static func isHexIdentifier(_ text: String) -> Bool {
        text.utf8.count == 32 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    // Field limits, from the contract where it names one.
    static let finding = FieldType.text(minimum: 0, limit: LearningCandidateText.findingLimit, lineFeeds: true)
    static let shortText = FieldType.text(minimum: 0, limit: LearningCandidateText.fieldLimit, lineFeeds: false)
    static let name = FieldType.text(minimum: 1, limit: LearningCandidateText.authorLimit, lineFeeds: false)
    static let reference = FieldType.text(minimum: 1, limit: 120, lineFeeds: false)
    static let timestamp = FieldType.integer(minimum: 1)

    static let evidence = Object(fields: [
        "pagesVerified": Field(type: .texts(itemLimit: LearningCandidateText.fieldLimit, maximumCount: 200), required: true),
        "citationsOpened": Field(type: .texts(itemLimit: LearningCandidateText.fieldLimit, maximumCount: 200), required: true),
        "readings": Field(type: .integer(minimum: 0), required: true),
        "photos": Field(type: .integer(minimum: 0), required: true),
    ])

    static let candidate = Object(fields: [
        "candidateID": Field(type: .hexIdentifier, required: true),
        "revision": Field(type: .integer(minimum: 1), required: true),
        "withdrawn": Field(type: .bool, required: true),
        "origin": Field(type: .oneOf(Set(LearningCandidate.Origin.allCases.map(\.rawValue))), required: true),
        "jobSessionID": Field(type: reference, required: true),
        "jobNumber": Field(type: reference, required: false),
        "taskID": Field(type: reference, required: false),
        "createdAt": Field(type: timestamp, required: true),
        "author": Field(type: name, required: true),
        "vaultID": Field(type: reference, required: true),
        "modelToken": Field(type: subjectText, required: false),
        "spokenModel": Field(type: .text(minimum: 1, limit: LearningCandidateText.fieldLimit, lineFeeds: false), required: false),
        "finding": Field(type: finding, required: true),
        "symptom": Field(type: shortText, required: false),
        "fix": Field(type: shortText, required: false),
        "evidence": Field(type: .object(evidence), required: true),
        "redactions": Field(type: .texts(itemLimit: 40, maximumCount: 20), required: true),
    ])

    static let status = Object(fields: [
        "candidateID": Field(type: .hexIdentifier, required: true),
        "revision": Field(type: .integer(minimum: 1), required: true),
        "status": Field(type: .oneOf(Set(LearningBundle.Decision.allCases.map(\.rawValue))), required: true),
        "entryID": Field(type: .hexIdentifier, required: false),
        "reason": Field(type: .text(minimum: 1, limit: LearningCandidateText.fieldLimit, lineFeeds: false), required: false),
        "issuedAt": Field(type: timestamp, required: true),
    ])

    /// A subject's token or topic: the reviewer's words or the model as spoken, so the field limit.
    static let subjectText = FieldType.text(minimum: 1, limit: LearningCandidateText.fieldLimit, lineFeeds: false)

    static let modelSubject = Object(fields: [
        "kind": Field(type: .oneOf(["model"]), required: true),
        "modelToken": Field(type: subjectText, required: true),
        "manufacturer": Field(type: reference, required: false),
        "equipmentType": Field(type: reference, required: false),
    ])

    static let practiceSubject = Object(fields: [
        "kind": Field(type: .oneOf(["practice"]), required: true),
        "topic": Field(type: subjectText, required: true),
    ])

    static let entry = Object(fields: [
        "entryID": Field(type: .hexIdentifier, required: true),
        "subject": Field(type: .subject, required: true),
        "vaultIDs": Field(type: .texts(itemLimit: 120, maximumCount: 100), required: true),
        "finding": Field(type: .text(minimum: 1, limit: LearningCandidateText.findingLimit, lineFeeds: true), required: true),
        "symptom": Field(type: shortText, required: false),
        "fix": Field(type: shortText, required: false),
        "approvedAt": Field(type: timestamp, required: true),
        "approvedByRole": Field(type: .text(minimum: 1, limit: LearningEntry.roleLimit, lineFeeds: false), required: true),
        "authorIsApprover": Field(type: .bool, required: true),
        "contradictsSafetyNote": Field(type: .bool, required: true),
        "supersedes": Field(type: .hexIdentifier, required: false),
        "candidateID": Field(type: .hexIdentifier, required: false),
        "origin": Field(type: .oneOf(Set(LearningCandidate.Origin.allCases.map(\.rawValue))), required: false),
        "sourceJobIDs": Field(type: .texts(itemLimit: 120, maximumCount: 1_000), required: false),
        "confirmedJobCount": Field(type: .integer(minimum: 1), required: false),
    ])

    static let retraction = Object(fields: [
        "entryID": Field(type: .hexIdentifier, required: true),
        "retractedAt": Field(type: timestamp, required: true),
        "reason": Field(type: .text(minimum: 1, limit: LearningCandidateText.fieldLimit, lineFeeds: false), required: true),
    ])

    static let bundle = Object(fields: [
        "schemaVersion": Field(type: .integer(minimum: 1), required: true),
        "kind": Field(type: .oneOf([LearningBundle.kind]), required: true),
        "direction": Field(type: .oneOf(Set(LearningBundle.Direction.allCases.map(\.rawValue))), required: true),
        "organisationLabel": Field(type: name, required: false),
        "issuedAt": Field(type: timestamp, required: true),
        "sequence": Field(type: .integer(minimum: 1), required: false),
        "candidates": Field(type: .objects(candidate), required: true),
        "statuses": Field(type: .objects(status), required: true),
        "entries": Field(type: .objects(entry), required: true),
        "retracted": Field(type: .objects(retraction), required: true),
    ])
}
