import Foundation
import CryptoKit

// MARK: - Vocabulary

/// What kind of thing happened. A **closed** vocabulary: the audit log used to carry a free-text
/// `action` and a free-text `detail`, which meant a filename, a clinical value or a credential
/// could reach compliance evidence simply by being passed to `log(action:detail:)`. Every case
/// here is an app-defined operation class, and every field an event carries beside it is a class,
/// a count, a fingerprint or a fixed token (roadmap W05.2).
///
/// `auditToken` is the stable wire/UI spelling. It is deliberately the same string the free-text
/// vocabulary already used, so an existing reviewer, an existing export and the on-disk history
/// all keep reading the same way across the migration.
enum AuditEventKind: String, Codable, CaseIterable, Sendable {
    // Compliance mode
    case complianceModeEnabled
    case complianceModeDisabled
    // The audit log itself
    case auditClearGranted
    case auditClearRefused
    case auditExportCreated
    case auditExportReleased
    case integrityCheck
    case policyVersionChanged
    case ownerAuthorizationOutcome
    // Retention and deletion
    case retentionPurgeCompleted
    case filePurged
    case fileSecurelyDeleted
    // Clinical capture and egress
    case recordingStarted
    case recordingStopped
    case transcriptSaved
    case clinicalExport
    case exportCreated
    case exportReleased
    case appLaunched
    // Vocabulary defined here for the sources that live in other change sets. Nothing on this
    // branch can emit them — the deletion coordinator, the consent store, the tool-definition
    // digest store and the model registry are all owned elsewhere — so they are declared and
    // recorded as owed wiring rather than faked.
    case deletionCompleted
    case consentChanged
    case toolDefinitionChanged
    case modelOrToolChanged
    case enrolmentChanged
    case remoteAuthorizationDecided
    /// A record migrated from the pre-schema free-text log, or written by a caller whose action
    /// token this vocabulary does not (yet) name. Carries a fingerprint of the old detail, never
    /// the text.
    case legacy

    var auditToken: String {
        switch self {
        case .complianceModeEnabled: return "COMPLIANCE_ENABLED"
        case .complianceModeDisabled: return "COMPLIANCE_DISABLED"
        case .auditClearGranted: return "AUDIT_LOG_CLEARED"
        case .auditClearRefused: return "AUDIT_CLEAR_REFUSED"
        case .auditExportCreated: return "AUDIT_EXPORT_CREATED"
        case .auditExportReleased: return "AUDIT_EXPORT_RELEASED"
        case .integrityCheck: return "INTEGRITY_CHECK"
        case .policyVersionChanged: return "POLICY_VERSION_CHANGED"
        case .ownerAuthorizationOutcome: return "OWNER_AUTHORIZATION"
        case .retentionPurgeCompleted: return "RETENTION_PURGE"
        case .filePurged: return "FILE_PURGED"
        case .fileSecurelyDeleted: return "SECURE_DELETE"
        case .recordingStarted: return "RECORDING_STARTED"
        case .recordingStopped: return "RECORDING_STOPPED"
        case .transcriptSaved: return "TRANSCRIPT_SAVED"
        case .clinicalExport: return "CLINICAL_EXPORT"
        case .exportCreated: return "EXPORT_CREATED"
        case .exportReleased: return "EXPORT_RELEASED"
        case .appLaunched: return "APP_LAUNCHED"
        case .deletionCompleted: return "DELETION_COMPLETED"
        case .consentChanged: return "CONSENT_CHANGED"
        case .toolDefinitionChanged: return "TOOL_DEFINITION_CHANGED"
        case .modelOrToolChanged: return "MODEL_OR_TOOL_CHANGED"
        case .enrolmentChanged: return "ENROLMENT_CHANGED"
        case .remoteAuthorizationDecided: return "REMOTE_AUTHORIZATION"
        case .legacy: return "LEGACY"
        }
    }
}

/// Who caused it, as a class rather than an identity. Naming a person in an audit row would make
/// the log itself the widest identifier store in the app.
enum AuditActorClass: String, Codable, CaseIterable, Sendable {
    case wearer, owner, system, remotePeer, enterprise
}

/// What it happened to.
enum AuditTargetClass: String, Codable, CaseIterable, Sendable {
    case complianceMode, auditLog, transcript, export, enrolment
    case remoteAuthorization, consent, toolDefinition, model, policy
}

/// How it ended.
enum AuditResult: String, Codable, CaseIterable, Sendable {
    case succeeded, refused, failed
}

/// The owner-authorization outcome an operation was carried out under, where one was taken.
enum AuditDecision: String, Codable, CaseIterable, Sendable {
    case granted, denied, unavailable

    init(_ authorization: OwnerAuthorization) {
        switch authorization {
        case .granted: self = .granted
        case .denied: self = .denied
        case .unavailable: self = .unavailable
        }
    }
}

/// Why it was done. A closed vocabulary, because "purpose" is exactly the field a free-text
/// habit would reintroduce: it reads like a place for a sentence, and a sentence about a clinical
/// operation is a clinical fact.
enum AuditPurpose: String, Codable, CaseIterable, Sendable {
    case treatment
    case operations
    case complianceReview
    case wearerRequest
    case retentionPolicy
    case security
    case systemMaintenance
}

/// The policy revision an event was recorded under, so a reviewer can tell which rules were in
/// force. Bumped when the meaning of the fields changes, not when a case is added.
enum AuditPolicyVersion {
    static let current = "audit-1"
}

// MARK: - Fingerprints

/// Short, stable, one-way. Correlates records without carrying the value — the same treatment
/// `ToolAuthorizationEventLog` gives invocation ids.
enum AuditFingerprint {
    static func of(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func of(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - The event

/// One typed audit record (roadmap W05.2).
///
/// Every free-text slot the old `AuditEntry` had is gone. `purpose` is an enum's raw value,
/// `correlationID` is always a fingerprint of whatever the caller passed, `legacyAction` accepts
/// only a `SCREAMING_SNAKE` operation token and fingerprints anything else, and the old `detail`
/// survives only as `detailFingerprint`. There is no initializer that stores caller text
/// verbatim, which is what makes the canary suite's guarantee structural rather than a filter.
struct AuditEvent: Codable, Identifiable, Equatable, Sendable {
    let eventID: UUID
    /// Truncated to milliseconds at construction so the stored form, the exported form and the
    /// chain digest all agree on the same instant after a round trip.
    let at: Date
    let kind: AuditEventKind
    let actorClass: AuditActorClass
    let targetClass: AuditTargetClass
    /// `AuditPurpose.rawValue`, or nil. Never caller text.
    let purpose: String?
    let policyVersion: String
    let result: AuditResult
    /// A fingerprint of the caller's correlation value, never the value.
    let correlationID: String?
    let decision: AuditDecision?
    /// A magnitude — files purged, entries exported. Never an identifier.
    let count: Int?
    /// A digest of the artefact acted on (an export's bytes, a purged file's name). Never content.
    let subjectDigest: String?
    /// The caller's own operation token, when it passed the token filter.
    let legacyAction: String?
    /// The pre-schema `detail` field, one-way.
    let detailFingerprint: String?

    var id: UUID { eventID }

    /// The stable spelling a reviewer, the audit list and the export all read. The caller's token
    /// when there was one, else the kind's own.
    var action: String { legacyAction ?? kind.auditToken }

    /// Content-free one-line summary for the audit list. Every part is a fixed token or a count.
    var summary: String {
        var parts = ["target=\(targetClass.rawValue)", "actor=\(actorClass.rawValue)",
                     "result=\(result.rawValue)"]
        if let decision { parts.append("authorization=\(decision.rawValue)") }
        if let purpose { parts.append("purpose=\(purpose)") }
        if let count { parts.append("count=\(count)") }
        if let subjectDigest { parts.append("subject=\(subjectDigest.prefix(16))") }
        return parts.joined(separator: " · ")
    }

    init(kind: AuditEventKind,
         actorClass: AuditActorClass = .system,
         targetClass: AuditTargetClass,
         purpose: AuditPurpose? = nil,
         result: AuditResult = .succeeded,
         decision: AuditDecision? = nil,
         count: Int? = nil,
         subject: String? = nil,
         subjectDigest: String? = nil,
         correlation: String? = nil,
         action: String? = nil,
         detail: String? = nil,
         at: Date = Date(),
         eventID: UUID = UUID(),
         policyVersion: String = AuditPolicyVersion.current) {
        self.eventID = eventID
        self.at = Self.truncated(at)
        self.kind = kind
        self.actorClass = actorClass
        self.targetClass = targetClass
        self.purpose = purpose?.rawValue
        self.policyVersion = policyVersion
        self.result = result
        // Whatever the caller had in hand — an invocation id, a session id, a filename — reaches
        // storage only as a fingerprint. There is no path for the value itself.
        self.correlationID = correlation.map(AuditFingerprint.of)
        self.decision = decision
        self.count = count
        self.subjectDigest = subjectDigest ?? subject.map(AuditFingerprint.of)
        self.legacyAction = action.flatMap(Self.operationToken)
        self.detailFingerprint = detail.map(AuditFingerprint.of)
    }

    /// Migration constructor for a pre-schema row: the action token survives if it is one, the
    /// detail becomes a fingerprint, and nothing else is invented.
    static func legacy(action: String, detail: String, at: Date = Date(),
                       eventID: UUID = UUID()) -> AuditEvent {
        AuditEvent(kind: .legacy, targetClass: .auditLog, action: action, detail: detail,
                   at: at, eventID: eventID, policyVersion: "legacy")
    }

    /// An operation token is `SCREAMING_SNAKE`, short, and from the app's own call sites. Anything
    /// else — a sentence, a path, a credential-shaped string — is fingerprinted instead of stored,
    /// which is what stops a canary surviving in this slot.
    static func operationToken(_ raw: String) -> String? {
        guard !raw.isEmpty, raw.count <= 48 else { return AuditFingerprint.of(raw) }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")
        guard raw.unicodeScalars.allSatisfy(allowed.contains) else { return AuditFingerprint.of(raw) }
        return raw
    }

    private static func truncated(_ date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate:
                (date.timeIntervalSinceReferenceDate * 1000).rounded() / 1000)
    }

    // MARK: Coding

    private enum CodingKeys: String, CodingKey {
        case eventID, at, kind, actorClass, targetClass, purpose, policyVersion, result
        case correlationID, decision, count, subjectDigest, legacyAction, detailFingerprint
    }

    /// Pre-schema shape, still on disk in any install that ran before this change.
    private enum LegacyKeys: String, CodingKey {
        case id, timestamp, action, detail
    }

    /// Fixed-format so the stored bytes, the export and the digest never disagree about an
    /// instant. `ISO8601DateFormatter` is avoided deliberately: its default has no fractional
    /// seconds, and a round trip through it would silently move every event.
    static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return formatter
    }()

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(eventID, forKey: .eventID)
        try container.encode(Self.timestampFormatter.string(from: at), forKey: .at)
        try container.encode(kind, forKey: .kind)
        try container.encode(actorClass, forKey: .actorClass)
        try container.encode(targetClass, forKey: .targetClass)
        try container.encodeIfPresent(purpose, forKey: .purpose)
        try container.encode(policyVersion, forKey: .policyVersion)
        try container.encode(result, forKey: .result)
        try container.encodeIfPresent(correlationID, forKey: .correlationID)
        try container.encodeIfPresent(decision, forKey: .decision)
        try container.encodeIfPresent(count, forKey: .count)
        try container.encodeIfPresent(subjectDigest, forKey: .subjectDigest)
        try container.encodeIfPresent(legacyAction, forKey: .legacyAction)
        try container.encodeIfPresent(detailFingerprint, forKey: .detailFingerprint)
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self),
           container.contains(.kind) {
            eventID = try container.decode(UUID.self, forKey: .eventID)
            let stamp = try container.decode(String.self, forKey: .at)
            guard let parsed = Self.timestampFormatter.date(from: stamp) else {
                throw DecodingError.dataCorruptedError(forKey: .at, in: container,
                                                       debugDescription: "unparseable timestamp")
            }
            at = parsed
            kind = try container.decode(AuditEventKind.self, forKey: .kind)
            actorClass = try container.decode(AuditActorClass.self, forKey: .actorClass)
            targetClass = try container.decode(AuditTargetClass.self, forKey: .targetClass)
            // An unrecognised purpose is dropped rather than carried: the field is a closed
            // vocabulary, and a value from outside it has no meaning to a reviewer.
            purpose = try container.decodeIfPresent(String.self, forKey: .purpose)
                .flatMap { AuditPurpose(rawValue: $0)?.rawValue }
            policyVersion = try container.decode(String.self, forKey: .policyVersion)
            result = try container.decode(AuditResult.self, forKey: .result)
            correlationID = try container.decodeIfPresent(String.self, forKey: .correlationID)
            decision = try container.decodeIfPresent(AuditDecision.self, forKey: .decision)
            count = try container.decodeIfPresent(Int.self, forKey: .count)
            subjectDigest = try container.decodeIfPresent(String.self, forKey: .subjectDigest)
            legacyAction = try container.decodeIfPresent(String.self, forKey: .legacyAction)
                .flatMap(Self.operationToken)
            detailFingerprint = try container.decodeIfPresent(String.self, forKey: .detailFingerprint)
            return
        }

        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        let stamp = try legacy.decode(Double.self, forKey: .timestamp)
        self = AuditEvent.legacy(action: try legacy.decode(String.self, forKey: .action),
                                 detail: try legacy.decode(String.self, forKey: .detail),
                                 at: Date(timeIntervalSinceReferenceDate: stamp),
                                 eventID: try legacy.decode(UUID.self, forKey: .id))
    }
}
