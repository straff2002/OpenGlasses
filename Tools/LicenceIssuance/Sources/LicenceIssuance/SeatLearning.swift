import Foundation

// Plan NG — team learnings reviewed in the portal. A phone enrolled in a company whose vaults come
// from the portal sends each candidate it files to the company's administrator over the signed seat
// channel (Plan JS P2), and asks after the administrator's decisions on the same channel. The
// contract is `Contracts/team-learning.md` §12; the golden fixtures are
// `Contracts/fixtures/team-learning-portal-v1/`, read by this package's tests and the app's.
//
// **Foundation only, self-contained.** It refers to nothing else in this package, so the app
// compiles it into its own target (as it does `CrewExperience.swift`) and the service compiles it on
// Linux. The signature over a request is the seat channel's (`SeatWire`, in `Seats.swift`, which
// verifies it): this file holds the shapes, the limits, the checks both sides hold a message to,
// the paging rule and the route rule — never a key.

// MARK: - The wire

public enum SeatLearningWire {
    /// The two seat actions, beside `claim`, `renew` and `release` under `/seats/`. Their raw values
    /// are what the request signature names, so a candidate cannot be replayed as a status fetch.
    public enum Action: String, Codable, CaseIterable, Sendable {
        case learningCandidate = "learning-candidate"
        case learningStatus = "learning-status"
        public var path: String { "/seats/" + rawValue }
    }

    /// The seat channel's request domain (`SeatWire.requestDomain`): one signing rule for every seat
    /// action, the action's name inside it.
    public static let requestDomain = "openglasses.seat-request.v1\n"

    /// What the phone signs: domain, action, nonce, then the request's JSON exactly as sent — the
    /// same bytes `SeatWire.signedBytes` makes for the other seat actions.
    public static func signedBytes(action: Action, nonce: String, request: Data) -> Data {
        Data((requestDomain + action.rawValue + "\n" + nonce + "\n").utf8) + request
    }

    /// The candidate's request JSON may weigh at most this (team-learning §2's candidate cap).
    public static let maximumCandidateRequestBytes = 32 * 1024
    /// A status fetch is a lease and a cursor.
    public static let maximumStatusRequestBytes = 4_096
    /// Every seat reply is at most this, as today.
    public static let maximumReplyBytes = 8 * 1024
    /// At most this many statuses in one page; fewer when they would not fit the reply cap.
    public static let maximumStatusesPerPage = 32
    /// The phone stops asking for more pages after this many in one fetch.
    public static let maximumPagesPerFetch = 64

    /// **Wire identifiers, not product names: never change them.**
    public static let candidateKind = "avenkin.learning-candidate"
    public static let statusKind = "avenkin.learning-candidate-status"
    public static let version = 1

    /// The job session id never travels: the portal gets a join key made from it (decision 3).
    /// `jobSessionID` is the first 32 lowercase hex characters of the SHA-256 of these bytes, so the
    /// same job gives the same key within one company and an unrelated one in another.
    public static let jobSessionDomain = "openglasses.learning-job-session.v1\n"
    public static func jobSessionHashInput(profileId: String, sessionId: String) -> Data {
        Data((jobSessionDomain + profileId + "\n" + sessionId).utf8)
    }

    /// Sorted keys and unescaped slashes, so a message encodes to the same bytes on both sides.
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func decoder() -> JSONDecoder { JSONDecoder() }
}

// MARK: - Messages

/// The evidence as the contract carries it: names and counts only (§3). No photo, reading value or
/// nameplate text.
public struct SeatLearningEvidence: Codable, Equatable, Sendable {
    public var pagesVerified: [String]
    public var citationsOpened: [String]
    public var readings: Int
    public var photos: Int
    public init(pagesVerified: [String] = [], citationsOpened: [String] = [], readings: Int = 0, photos: Int = 0) {
        self.pagesVerified = pagesVerified; self.citationsOpened = citationsOpened
        self.readings = readings; self.photos = photos
    }
}

/// Team-learning §3's candidate under the **portal binding**: `profileId` and `seatID` in place of
/// the office binding's `organizationID`, `enrolmentID`, `officeID` and `generation`. Every other
/// field is §3's, with the job session id replaced by its join key (decision 3).
public struct SeatLearningCandidate: Codable, Equatable, Sendable {
    public var version: Int
    public var kind: String
    public var candidateID: String
    public var revision: Int
    public var withdrawn: Bool
    /// The company profile the phone is enrolled in.
    public var profileId: String
    /// The seat the phone holds: its lease's `deviceKeyHash` (64 lowercase hex).
    public var seatID: String
    /// `SeatLearningWire.jobSessionHashInput` hashed: 32 lowercase hex.
    public var jobSessionID: String
    public var jobNumber: String?
    public var taskID: String?
    public var createdAt: Int64
    public var author: String
    public var vaultID: String
    public var modelToken: String?
    public var spokenModel: String?
    public var finding: String
    public var symptom: String?
    public var fix: String?
    public var evidence: SeatLearningEvidence
    public var redactions: [String]

    public init(candidateID: String, revision: Int, withdrawn: Bool, profileId: String, seatID: String,
                jobSessionID: String, jobNumber: String?, taskID: String?, createdAt: Int64, author: String,
                vaultID: String, modelToken: String?, spokenModel: String?, finding: String, symptom: String?,
                fix: String?, evidence: SeatLearningEvidence, redactions: [String]) {
        self.version = SeatLearningWire.version; self.kind = SeatLearningWire.candidateKind
        self.candidateID = candidateID; self.revision = revision; self.withdrawn = withdrawn
        self.profileId = profileId; self.seatID = seatID; self.jobSessionID = jobSessionID
        self.jobNumber = jobNumber; self.taskID = taskID; self.createdAt = createdAt; self.author = author
        self.vaultID = vaultID; self.modelToken = modelToken; self.spokenModel = spokenModel
        self.finding = finding; self.symptom = symptom; self.fix = fix; self.evidence = evidence
        self.redactions = redactions
    }
}

/// `POST /seats/learning-candidate`: the lease the phone holds (the service finds the seat, and the
/// key that signed, by it, as for a renewal) and the candidate.
public struct SeatLearningCandidateRequest: Codable, Equatable, Sendable {
    public let lease: String
    public let candidate: SeatLearningCandidate
    public init(lease: String, candidate: SeatLearningCandidate) { self.lease = lease; self.candidate = candidate }
}

/// `POST /seats/learning-status`: the lease, and where the last page ended (absent for the first).
public struct SeatLearningStatusRequest: Codable, Equatable, Sendable {
    public let lease: String
    public let after: String?
    public init(lease: String, after: String? = nil) { self.lease = lease; self.after = after }
}

/// Team-learning §4's statuses. `not_taken_up` is spelled as the contract spells it.
public enum SeatLearningStatusCode: String, Codable, CaseIterable, Sendable {
    case received, approved, merged
    case notTakenUp = "not_taken_up"
    /// `approved`, `merged` and `not_taken_up` are final for the candidate.
    public var isFinal: Bool { self != .received }
}

/// Team-learning §4's status under the portal binding.
public struct SeatLearningStatus: Codable, Equatable, Sendable {
    public var version: Int
    public var kind: String
    public var candidateID: String
    public var revision: Int
    public var profileId: String
    public var seatID: String
    public var status: SeatLearningStatusCode
    /// Present for `approved` and `merged`: the entry it became or was merged into.
    public var entryID: String?
    /// Present for `not_taken_up`: the administrator's words for the author, 1–500 characters.
    public var reason: String?
    public var issuedAt: Int64

    public init(candidateID: String, revision: Int, profileId: String, seatID: String, status: SeatLearningStatusCode,
                entryID: String? = nil, reason: String? = nil, issuedAt: Int64) {
        self.version = SeatLearningWire.version; self.kind = SeatLearningWire.statusKind
        self.candidateID = candidateID; self.revision = revision; self.profileId = profileId; self.seatID = seatID
        self.status = status; self.entryID = entryID; self.reason = reason; self.issuedAt = issuedAt
    }
}

/// Why the service took nothing. Unsigned, like every seat refusal: the phone only words its job's
/// status line with one. A refused candidate stays queued on the phone.
public enum SeatLearningRefusal: String, Codable, CaseIterable, Sendable {
    /// The nonce was unknown, used or stale: ask for another and try again.
    case badNonce
    /// The request did not open, decode or pass `SeatLearningCheck`.
    case badRequest
    /// Over `maximumCandidateRequestBytes`.
    case tooLarge
    /// The seat the lease names was freed, or its lease and grace ran out.
    case freed
    /// The profile's licence has run out.
    case licenceLapsed
    case unknownProfile
    /// The profile's licence does not count seats, so there is no seat to sign with.
    case notSeatChecked
    /// The company does not review team learnings in the portal (no company vaults, or the switch is off).
    case routeOff
    /// The company's licence does not include team learnings.
    case notIncluded
}

/// The answer to a candidate: the §4 status for the candidate and revision it now holds (`received`,
/// or the decision if one was made), or a refusal.
public struct SeatLearningCandidateReply: Codable, Equatable, Sendable {
    public let status: SeatLearningStatus?
    public let refusal: SeatLearningRefusal?
    public init(status: SeatLearningStatus? = nil, refusal: SeatLearningRefusal? = nil) {
        self.status = status; self.refusal = refusal
    }
}

/// One page of the seat's statuses, ordered by `candidateID`; `next` is where the following page
/// starts, absent on the last.
public struct SeatLearningStatusReply: Codable, Equatable, Sendable {
    public let statuses: [SeatLearningStatus]?
    public let next: String?
    public let refusal: SeatLearningRefusal?
    public init(statuses: [SeatLearningStatus]? = nil, next: String? = nil, refusal: SeatLearningRefusal? = nil) {
        self.statuses = statuses; self.next = next; self.refusal = refusal
    }
}

// MARK: - The checks both sides hold a message to

public struct SeatLearningProblem: Error, Equatable, Sendable, Codable, CustomStringConvertible {
    public enum Reason: String, Codable, CaseIterable, Sendable {
        case wrongKind, wrongVersion, badIdentifier, badRevision, badTime, badCount
        case missingFinding, empty, textInWithdrawal, tooLong, controlCharacter, tooMany, tooLarge, badLease
        case missingEntryID, entryIDOutOfPlace, missingReason, reasonOutOfPlace
    }
    public let reason: Reason
    /// The field the reason is about, by its wire name.
    public let field: String
    public init(_ reason: Reason, _ field: String) { self.reason = reason; self.field = field }
    public var description: String { "\(reason.rawValue) \(field)" }
}

public enum SeatLearningCheck {
    public static let findingLimit = 2_000
    public static let fieldLimit = 500
    public static let authorLimit = 120
    public static let reasonLimit = 500
    /// A job number, task id or model token as the phone holds it.
    public static let shortTextLimit = 80
    /// One page or citation name in the evidence, and how many of each.
    public static let evidenceNameLimit = 300
    public static let evidenceNamesLimit = 100
    public static let redactionsLimit = 20
    public static let leaseLimit = 2_048
    /// Integers are positive and at most 2^53 − 1 (team-learning §2).
    public static let largestInteger: Int64 = 9_007_199_254_740_991

    /// A candidate's request, as the service opens it and the phone builds it. The size is the
    /// encoded request's (`SeatLearningWire.encoder()`).
    public static func check(_ request: SeatLearningCandidateRequest) throws {
        guard !request.lease.isEmpty, request.lease.utf8.count <= leaseLimit else { throw SeatLearningProblem(.badLease, "lease") }
        try check(request.candidate)
        let bytes = try SeatLearningWire.encoder().encode(request).count
        guard bytes <= SeatLearningWire.maximumCandidateRequestBytes else { throw SeatLearningProblem(.tooLarge, "request") }
    }

    public static func check(_ c: SeatLearningCandidate) throws {
        guard c.kind == SeatLearningWire.candidateKind else { throw SeatLearningProblem(.wrongKind, "kind") }
        guard c.version == SeatLearningWire.version else { throw SeatLearningProblem(.wrongVersion, "version") }
        guard isHex(c.candidateID, 32) else { throw SeatLearningProblem(.badIdentifier, "candidateID") }
        guard c.revision >= 1, Int64(c.revision) <= largestInteger else { throw SeatLearningProblem(.badRevision, "revision") }
        guard isSafeIdentifier(c.profileId) else { throw SeatLearningProblem(.badIdentifier, "profileId") }
        guard isHex(c.seatID, 64) else { throw SeatLearningProblem(.badIdentifier, "seatID") }
        guard isHex(c.jobSessionID, 32) else { throw SeatLearningProblem(.badIdentifier, "jobSessionID") }
        guard isSafeIdentifier(c.vaultID) else { throw SeatLearningProblem(.badIdentifier, "vaultID") }
        guard c.createdAt >= 1, c.createdAt <= largestInteger else { throw SeatLearningProblem(.badTime, "createdAt") }
        try text(c.jobNumber, "jobNumber", limit: shortTextLimit, required: false)
        try text(c.taskID, "taskID", limit: shortTextLimit, required: false)
        try text(c.modelToken, "modelToken", limit: shortTextLimit, required: false)
        try text(c.spokenModel, "spokenModel", limit: fieldLimit, required: false)
        try text(c.author, "author", limit: authorLimit, required: true)
        if c.withdrawn {
            // A withdrawal carries no words (§3): the text fields are empty.
            guard c.finding.isEmpty, c.symptom == nil, c.fix == nil else {
                throw SeatLearningProblem(.textInWithdrawal, "finding")
            }
        } else {
            guard !c.finding.isEmpty else { throw SeatLearningProblem(.missingFinding, "finding") }
            try text(c.finding, "finding", limit: findingLimit, required: true, lineFeeds: true)
            try text(c.symptom, "symptom", limit: fieldLimit, required: false)
            try text(c.fix, "fix", limit: fieldLimit, required: false)
        }
        try evidence(c.evidence)
        guard c.redactions.count <= redactionsLimit else { throw SeatLearningProblem(.tooMany, "redactions") }
        for name in c.redactions where !isSafeIdentifier(name) { throw SeatLearningProblem(.badIdentifier, "redactions") }
    }

    public static func check(_ s: SeatLearningStatus) throws {
        guard s.kind == SeatLearningWire.statusKind else { throw SeatLearningProblem(.wrongKind, "kind") }
        guard s.version == SeatLearningWire.version else { throw SeatLearningProblem(.wrongVersion, "version") }
        guard isHex(s.candidateID, 32) else { throw SeatLearningProblem(.badIdentifier, "candidateID") }
        guard s.revision >= 1, Int64(s.revision) <= largestInteger else { throw SeatLearningProblem(.badRevision, "revision") }
        guard isSafeIdentifier(s.profileId) else { throw SeatLearningProblem(.badIdentifier, "profileId") }
        guard isHex(s.seatID, 64) else { throw SeatLearningProblem(.badIdentifier, "seatID") }
        guard s.issuedAt >= 1, s.issuedAt <= largestInteger else { throw SeatLearningProblem(.badTime, "issuedAt") }
        switch s.status {
        case .approved, .merged:
            guard let entry = s.entryID else { throw SeatLearningProblem(.missingEntryID, "entryID") }
            guard isHex(entry, 32) else { throw SeatLearningProblem(.badIdentifier, "entryID") }
            guard s.reason == nil else { throw SeatLearningProblem(.reasonOutOfPlace, "reason") }
        case .notTakenUp:
            guard s.entryID == nil else { throw SeatLearningProblem(.entryIDOutOfPlace, "entryID") }
            guard let reason = s.reason else { throw SeatLearningProblem(.missingReason, "reason") }
            try text(reason, "reason", limit: reasonLimit, required: true)
        case .received:
            guard s.entryID == nil else { throw SeatLearningProblem(.entryIDOutOfPlace, "entryID") }
            guard s.reason == nil else { throw SeatLearningProblem(.reasonOutOfPlace, "reason") }
        }
    }

    private static func evidence(_ e: SeatLearningEvidence) throws {
        guard e.readings >= 0, Int64(e.readings) <= largestInteger else { throw SeatLearningProblem(.badCount, "readings") }
        guard e.photos >= 0, Int64(e.photos) <= largestInteger else { throw SeatLearningProblem(.badCount, "photos") }
        for (names, field) in [(e.pagesVerified, "pagesVerified"), (e.citationsOpened, "citationsOpened")] {
            guard names.count <= evidenceNamesLimit else { throw SeatLearningProblem(.tooMany, field) }
            for name in names { try text(name, field, limit: evidenceNameLimit, required: true) }
        }
    }

    /// Plain text (team-learning §7.4): no control character but a line feed inside `finding`, no
    /// bidirectional control, not empty when present, and within its limit in Unicode scalars.
    private static func text(_ value: String?, _ field: String, limit: Int, required: Bool, lineFeeds: Bool = false) throws {
        guard let value else {
            if required { throw SeatLearningProblem(.empty, field) }
            return
        }
        guard !value.isEmpty else { throw SeatLearningProblem(.empty, field) }
        for scalar in value.unicodeScalars where isRefused(scalar) && !(lineFeeds && scalar == "\n") {
            throw SeatLearningProblem(.controlCharacter, field)
        }
        guard value.unicodeScalars.count <= limit else { throw SeatLearningProblem(.tooLong, field) }
    }

    /// The general category Cc, plus the bidirectional embedding, override and isolate controls —
    /// the phone's `LearningCandidateText.isRefused`.
    public static func isRefused(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.generalCategory == .control { return true }
        switch scalar.value {
        case 0x202A...0x202E, 0x2066...0x2069: return true
        default: return false
        }
    }

    /// `count` lowercase hex characters.
    public static func isHex(_ id: String, _ count: Int) -> Bool {
        id.utf8.count == count && id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// 1–80 of A–Z a–z 0–9 - _ . and never `.` or `..` (`ProfileContract`'s rule).
    public static func isSafeIdentifier(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 80 && id != "." && id != ".."
            && id.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 || $0 == 46 }
    }
}

// MARK: - What the service keeps, and how it answers

public enum SeatLearningIntake {
    /// A candidate arriving for one already held: a higher revision replaces the held one; the same
    /// revision, or a lower one (a retry that crossed a newer send), changes nothing. Either way the
    /// answer names the revision now held, so a repeated or replayed candidate yields the same
    /// `received` (team-learning §4) and the phone's newer revision is never lost to an older one.
    public static func keep(_ incoming: SeatLearningCandidate, held: SeatLearningCandidate?) -> SeatLearningCandidate {
        guard let held, held.candidateID == incoming.candidateID else { return incoming }
        return incoming.revision > held.revision ? incoming : held
    }

    /// One page of a seat's statuses: ordered by `candidateID`, starting after `after`, at most
    /// `maximumStatusesPerPage`, and never more than fits `maximumReplyBytes` encoded (at least one,
    /// which always fits: a status is far below the cap). `next` is the last id on the page when
    /// more follow.
    public static func page(_ statuses: [SeatLearningStatus], after: String?) -> SeatLearningStatusReply {
        let ordered = statuses.sorted { $0.candidateID < $1.candidateID }
            .filter { after == nil || $0.candidateID > after! }
        var page: [SeatLearningStatus] = []
        for status in ordered {
            guard page.count < SeatLearningWire.maximumStatusesPerPage else { break }
            let candidate = SeatLearningStatusReply(statuses: page + [status], next: status.candidateID)
            let size = (try? SeatLearningWire.encoder().encode(candidate).count) ?? .max
            if size > SeatLearningWire.maximumReplyBytes, !page.isEmpty { break }
            page.append(status)
        }
        let more = ordered.count > page.count
        return SeatLearningStatusReply(statuses: page, next: more ? page.last?.candidateID : nil)
    }
}

// MARK: - Which route a company uses (§4 of the plan; team-learning §12.4)

public enum SeatLearningRoute: String, Codable, CaseIterable, Sendable {
    /// Plan JL: the company's own office, over the managed connection.
    case office
    /// Plan NG: the portal, over the seat channel.
    case portal
    /// Plan FP P3/P4: a reviewer's phone, by unsigned bundles.
    case reviewerDevice

    /// One route per company, in this order: an office binding wins; then the portal, when the
    /// company has company vaults on it and the profile has not switched the portal route off
    /// (on by default, decision 9); otherwise a reviewer's phone. A phone never sends a candidate
    /// by two routes.
    public static func choose(officeBinding: Bool, portalCompanyVaults: Bool, portalSwitchedOn: Bool) -> SeatLearningRoute {
        if officeBinding { return .office }
        if portalCompanyVaults && portalSwitchedOn { return .portal }
        return .reviewerDevice
    }
}
