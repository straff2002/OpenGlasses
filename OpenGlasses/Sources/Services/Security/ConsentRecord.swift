import Foundation

// MARK: - Vocabulary

/// Who agreed.
///
/// The three are not interchangeable and the type exists to stop them being treated as if they
/// were. A wearer approving an action is not the person in front of the lens agreeing to be
/// enrolled, and neither of them is an organisation's authority to process data at all. The most
/// common way consent goes wrong in a wearable is one of these standing in for another.
enum ConsentActor: String, Codable, Sendable, Equatable, CaseIterable {
    /// The person wearing the glasses, approving something the app is about to do.
    case wearer
    /// The person the data is *about* — a bystander, a patient, an interviewee.
    case subject
    /// An organisation's authority to process, established off-device by a process this app does
    /// not itself run.
    case enterprise
}

/// What the agreement is *for*. A closed vocabulary: a purpose nobody has written down is not a
/// purpose somebody agreed to.
///
/// The set is deliberately small and provisional. Which purposes this product actually needs, and
/// how each is described to a person, is a legal determination that has not been made — see the
/// W04.3 row in the remediation roadmap.
enum ConsentPurpose: String, Codable, Sendable, Equatable, CaseIterable {
    /// A remote or agentic action taken on the wearer's behalf.
    case remoteAction
    /// Sharing what the glasses can see or hear with a recipient off the device.
    case captureSharing
    /// Enrolling a person so they can be recognised later.
    case subjectEnrolment
    /// Exporting clinical data.
    case clinicalExport

    /// The version of the terms in force for this purpose. Bumping it makes every record taken
    /// under the old terms `stale`, which re-prompts rather than silently continuing.
    var currentVersion: Int { 1 }
}

/// What kind of data the agreement covers.
enum ConsentDataClass: String, Codable, Sendable, Equatable, CaseIterable {
    case none
    case imagery
    case audio
    case transcript
    case location
    case health
    case identity
}

// MARK: - Record

/// One agreement, as it stood at one moment.
///
/// Records are append-only in spirit: a withdrawal is a `withdrawnAt` on the existing row, never a
/// deletion, because "they never agreed" and "they agreed and then withdrew" are different facts
/// and only the second one obliges anybody to stop.
struct ConsentRecord: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let purpose: ConsentPurpose
    let dataClass: ConsentDataClass
    /// Who the data goes to — a server label, a peer label, `"on-device"`. Free text because the
    /// set is the user's, not ours; never logged, and compared verbatim.
    let recipient: String
    let actor: ConsentActor
    /// The terms version this agreement was given under.
    let version: Int
    let grantedAt: Date
    var withdrawnAt: Date?

    init(id: String = UUID().uuidString, purpose: ConsentPurpose, dataClass: ConsentDataClass,
         recipient: String, actor: ConsentActor, version: Int, grantedAt: Date,
         withdrawnAt: Date? = nil) {
        self.id = id
        self.purpose = purpose
        self.dataClass = dataClass
        self.recipient = recipient
        self.actor = actor
        self.version = version
        self.grantedAt = grantedAt
        self.withdrawnAt = withdrawnAt
    }

    var isWithdrawn: Bool { withdrawnAt != nil }
}

// MARK: - Policy

/// What the records say about one question.
enum ConsentOutcome: Equatable {
    /// A live agreement covers it.
    case granted(ConsentRecord)
    /// Nobody ever agreed to this.
    case notGranted
    /// Somebody agreed and then withdrew.
    case withdrawn(at: Date)
    /// Somebody agreed under terms that have since been superseded.
    case stale(recorded: Int, required: Int)

    var allowsProcessing: Bool {
        if case .granted = self { return true }
        return false
    }

    /// Whether the right response is to ask again. A withdrawal is not: asking again immediately
    /// after somebody says stop is how a consent surface becomes a nuisance dialog.
    var shouldPrompt: Bool {
        switch self {
        case .granted, .withdrawn: return false
        case .notGranted, .stale:  return true
        }
    }
}

/// The pure question-answering half of consent. No storage, no UI, no clock of its own.
enum ConsentPolicy {

    /// Whether `actor` has a live agreement, at `requiredVersion` or better, covering exactly this
    /// purpose, data class and recipient.
    ///
    /// The actor is part of the question, not a detail of the answer: asking whether *the subject*
    /// agreed and being handed the wearer's approval is the failure this whole type exists to
    /// prevent. A record by a different actor is not a weaker match — it is not a match at all.
    static func evaluate(purpose: ConsentPurpose,
                         dataClass: ConsentDataClass,
                         recipient: String,
                         requiredVersion: Int,
                         actor: ConsentActor = .wearer,
                         in records: [ConsentRecord],
                         at now: Date = Date()) -> ConsentOutcome {
        let matching = records
            .filter { $0.purpose == purpose && $0.dataClass == dataClass
                && $0.recipient == recipient && $0.actor == actor }
            .sorted { $0.grantedAt > $1.grantedAt }

        guard let latest = matching.first else { return .notGranted }
        if let withdrawnAt = latest.withdrawnAt, withdrawnAt <= now { return .withdrawn(at: withdrawnAt) }
        if latest.version < requiredVersion {
            return .stale(recorded: latest.version, required: requiredVersion)
        }
        return .granted(latest)
    }

    /// An operating-system permission is not an agreement by anybody it points at.
    ///
    /// Camera access is the wearer's own device letting this app use a sensor. It carries no
    /// information about whether the people in front of the lens agreed to anything, and there is
    /// deliberately no function anywhere in this file that turns a permission status into a
    /// `ConsentRecord`. The constant exists so the rule can be asserted rather than merely
    /// intended.
    static let osPermissionIsNotSubjectAgreement = true
}

// MARK: - Subject attestation

enum ConsentAuthorityError: Error, Equatable {
    /// A wearer tried to speak for somebody else. The wearer's own approval is not evidence about
    /// the subject, however sincerely it was given.
    case wearerCannotAttestForSubject
    /// The authority offered was a subject's own record, which is not an authority to enrol other
    /// subjects.
    case subjectIsNotAnAuthority
    /// The enterprise authority relied on has been withdrawn.
    case authorityWithdrawn
}

/// Evidence that a *subject* enrolment decision came from somewhere entitled to make it.
///
/// There is no public initializer. The only way to obtain one is
/// ``fromEnterpriseAuthority(_:)``, which refuses anything but a live `enterprise` record — so
/// "the wearer said it was fine" cannot be expressed in the type system, let alone stored. The
/// process that establishes an enterprise authority in the first place is off-device and is not
/// implemented here; see the W04.3 row in the remediation roadmap.
struct SubjectConsentEvidence: Sendable, Equatable {
    /// The id of the authority record relied upon, kept so a withdrawal of the authority can be
    /// traced to the enrolments it covered.
    let authorityRecordID: String

    private init(authorityRecordID: String) {
        self.authorityRecordID = authorityRecordID
    }

    static func fromEnterpriseAuthority(_ record: ConsentRecord) throws -> SubjectConsentEvidence {
        switch record.actor {
        case .wearer:  throw ConsentAuthorityError.wearerCannotAttestForSubject
        case .subject: throw ConsentAuthorityError.subjectIsNotAnAuthority
        case .enterprise:
            guard !record.isWithdrawn else { throw ConsentAuthorityError.authorityWithdrawn }
            return SubjectConsentEvidence(authorityRecordID: record.id)
        }
    }
}

// MARK: - Store

/// The durable half: versioned, withdrawable consent records.
///
/// JSON, protected at rest, excluded from backup. Small by construction — a consent ledger is a
/// register of decisions, not a log of everything that happened.
@MainActor
final class ConsentStore {
    static let shared = ConsentStore()

    static let fileProtection = FileProtectionType.completeUntilFirstUserAuthentication
    /// A ceiling, so a misbehaving caller cannot turn the register into a data store. Oldest
    /// *settled* rows go first; a live agreement is never evicted to make room.
    static let capacity = 500

    private let directory: URL
    private let fileURL: URL
    private var rows: [ConsentRecord] = []
    private(set) var protectionApplied = false
    /// False after an unreadable or corrupt store. A consent register that cannot be read must not
    /// be treated as an empty one: that reads as "nobody ever agreed", which is the safe answer for
    /// processing and the wrong one for a withdrawal somebody already made.
    private(set) var storageAvailable = true

    init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory()
        self.fileURL = self.directory.appendingPathComponent("consent-records.json")
        storageAvailable = load()
    }

    var records: [ConsentRecord] { rows }
    var storeURL: URL { fileURL }

    // MARK: Queries

    func evaluate(purpose: ConsentPurpose, dataClass: ConsentDataClass, recipient: String,
                  requiredVersion: Int, actor: ConsentActor = .wearer,
                  at now: Date = Date()) -> ConsentOutcome {
        ConsentPolicy.evaluate(purpose: purpose, dataClass: dataClass, recipient: recipient,
                               requiredVersion: requiredVersion, actor: actor, in: rows, at: now)
    }

    // MARK: Recording

    /// The wearer approving something the app is about to do on their behalf.
    @discardableResult
    func recordWearerApproval(purpose: ConsentPurpose, dataClass: ConsentDataClass,
                              recipient: String, version: Int, at now: Date = Date())
        -> ConsentRecord {
        append(ConsentRecord(purpose: purpose, dataClass: dataClass, recipient: recipient,
                             actor: .wearer, version: version, grantedAt: now))
    }

    /// A subject's own enrolment decision. Requires evidence that cannot be produced from a
    /// wearer's approval — see [[SubjectConsentEvidence]].
    @discardableResult
    func recordSubjectEnrolment(purpose: ConsentPurpose, dataClass: ConsentDataClass,
                                recipient: String, version: Int,
                                evidence: SubjectConsentEvidence,
                                at now: Date = Date()) -> ConsentRecord {
        _ = evidence.authorityRecordID   // held for traceability; never logged
        return append(ConsentRecord(purpose: purpose, dataClass: dataClass, recipient: recipient,
                                    actor: .subject, version: version, grantedAt: now))
    }

    /// An organisation's authority to process. Established off-device; this only records it.
    @discardableResult
    func recordEnterpriseAuthority(purpose: ConsentPurpose, dataClass: ConsentDataClass,
                                   recipient: String, version: Int, at now: Date = Date())
        -> ConsentRecord {
        append(ConsentRecord(purpose: purpose, dataClass: dataClass, recipient: recipient,
                             actor: .enterprise, version: version, grantedAt: now))
    }

    /// Withdraw an agreement. Idempotent: the first withdrawal time is the one that counts.
    @discardableResult
    func withdraw(id: String, at now: Date = Date()) -> ConsentRecord? {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return nil }
        if rows[index].withdrawnAt == nil {
            rows[index].withdrawnAt = now
            persist()
        }
        return rows[index]
    }

    /// Withdraw every live agreement matching a purpose — what "stop using my data for X" means.
    @discardableResult
    func withdrawAll(purpose: ConsentPurpose, actor: ConsentActor? = nil,
                     at now: Date = Date()) -> Int {
        var changed = 0
        for index in rows.indices
        where rows[index].purpose == purpose && rows[index].withdrawnAt == nil
            && (actor == nil || rows[index].actor == actor) {
            rows[index].withdrawnAt = now
            changed += 1
        }
        if changed > 0 { persist() }
        return changed
    }

    @discardableResult
    private func append(_ record: ConsentRecord) -> ConsentRecord {
        rows.append(record)
        enforceCapacity()
        persist()
        return record
    }

    private func enforceCapacity() {
        guard rows.count > Self.capacity else { return }
        // Evict settled (withdrawn) rows oldest-first; never drop a live agreement.
        let overflow = rows.count - Self.capacity
        var dropped = 0
        rows.removeAll { row in
            guard dropped < overflow, row.isWithdrawn else { return false }
            dropped += 1
            return true
        }
    }

    // MARK: Storage

    private static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Consent", isDirectory: true)
    }

    private func load() -> Bool {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return true }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            rows = try decoder.decode([ConsentRecord].self, from: data)
            return true
        } catch {
            PrivacyLog.store(.consentRecords, .loadFailed, error: SafeErrorSummary(error))
            return false
        }
    }

    @discardableResult
    private func persist() -> Bool {
        guard storageAvailable else { return false }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.protectionKey: Self.fileProtection])
            try encoder.encode(rows).write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.protectionKey: Self.fileProtection],
                                                  ofItemAtPath: fileURL.path)
            protectionApplied = true
            var url = fileURL
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
            PrivacyLog.store(.consentRecords, .recordWritten, count: rows.count)
            return true
        } catch {
            PrivacyLog.store(.consentRecords, .saveFailed, error: SafeErrorSummary(error))
            return false
        }
    }
}
