import Foundation
import Combine

/// Plan CT PR 2 — what is stored about the enrolled profile.
///
/// The **document** is kept, not the decoded profile: it is re-verified on every launch, so what
/// storage holds is evidence rather than a verdict — the rule Plan DP set for licence codes.
struct OrgEnrolmentRecord: Codable, Equatable, Sendable {
    /// The signed document exactly as it was verified.
    let document: String
    let source: ProfileSource
    /// A random id for this enrolment, shown on the managed row. Plan CT PR 4 revokes by it.
    let enrolmentId: String
    let enrolledAt: Date
    /// The person's own value for each starting value the profile wrote, to put back on removal.
    /// A key listed in `wroteStartingKeys` but absent here was unset before.
    var priorStartingValues: [String: ProfileValue]
    var wroteStartingKeys: [String]
    /// Whether the licence code in `LicenseService`'s slot was put there by this profile — so
    /// removal clears it only then, and never a code somebody typed by hand.
    var activatedLicence: Bool

    // Plan CT PR 2b — the lease. All optional, so a record written before the lease existed reads.

    /// Where the profile is hosted; renewal re-fetches it. Nil when it arrived without one — such a
    /// phone renews only by opening the organisation's link again.
    var profileURL: URL?
    /// When a verified copy was last fetched. The lease runs from here; nil means `enrolledAt`.
    var lastRenewedAt: Date?
    /// When renewal was last tried, so it is tried at most once a day.
    var lastRenewalAttempt: Date?
    /// The latest time the app has seen, so a clock wound back past it is noticed.
    var clockHighWater: Date?
    /// Set when the organisation revoked this phone. Its settings no longer apply and its content
    /// stays locked; erasing that content is Plan CT PR 4.
    var revoked: Bool?
    /// The mid-job grace: a lapse during a job locks when that job closes.
    var leaseLock: ProfileLease.Lock?
}

/// What the person holding the phone is shown before a profile is applied: who it is from, what it
/// turns on, what it takes away, and what this version of the app could not use.
struct OrgProfileReview: Identifiable, Equatable {
    let id = UUID()
    let document: String
    let source: ProfileSource
    let profile: ConfigProfile
    let result: ProfileApplier.Result
    /// Whether this replaces the same organisation's profile already in force (a renewal).
    let replacesCurrent: Bool
    /// Where the document was fetched from; the lease renews against it.
    var sourceURL: URL? = nil

    var organizationName: String { profile.organizationName }

    /// What the profile takes away or pins, one line per locked setting.
    var lockLines: [String] {
        result.ceilings.keys.sorted { $0.rawValue < $1.rawValue }.map { $0.ceilingDescription }
    }

    /// What the profile sets as a starting point the person may change afterwards.
    var startingValueLines: [String] {
        result.startingValues.sorted { $0.key.rawValue < $1.key.rawValue }
            .map { $0.key.startingValueDescription($0.value) }
    }

    /// Organisation details the profile supplies (its name on the sign-off sheet, its report route).
    var organizationLines: [String] {
        result.owned.keys.sorted { $0.rawValue < $1.rawValue }.map { $0.ownedDescription }
    }

    /// Entries this version of the app could not use, named.
    var dropLines: [String] {
        result.drops.map { "\($0.key) — \($0.reason.explanation)" }
    }

    var carriesLicence: Bool { profile.licenceCode != nil }

    static func == (lhs: OrgProfileReview, rhs: OrgProfileReview) -> Bool { lhs.id == rhs.id }
}

/// Plan CT PR 2 — enrolling, loading and removing the organisation profile.
///
/// The order is load-bearing and follows the plan's enrolment sequence: verify (both clocks), then
/// activate the licence the profile carries, then write the starting values and raise the ceiling.
/// Activation failing stops everything before a single setting is written. Every seam is injected,
/// so the sequence runs headless: no `UserDefaults`, no `LicenseService`, no clock of its own.
@MainActor
final class OrgProfileManager: ObservableObject {

    enum Refusal: Error, Equatable, LocalizedError {
        case verification(ProfileVerification.Failure)
        case revocation
        /// A different organisation's profile is already in force; it has to be removed first.
        case managedByAnother(String)
        case licence(String)
        case notRemovable

        var errorDescription: String? {
            switch self {
            case .verification(let failure): return failure.errorDescription
            case .revocation: return "That link carries a revocation, not a profile. There is nothing to apply."
            case .managedByAnother(let name): return "This phone is already managed by \(name). Remove that first, from Settings."
            case .licence(let message): return message
            case .notRemovable: return "Your organisation's device management applied this profile, so it can only be removed there."
            }
        }
    }

    struct Seams {
        var verificationKeys: [String: String] = ProfileVerification.productionKeys
        var licenceKey: String = LicenseService.productionPublicKeyBase64
        var now: () -> Date = Date.init
        var resolvableVaultIds: @MainActor () -> Set<String> = { Set(VaultRegistry.shared.allManifests.map(\.id)) }
        var loadRecord: () -> OrgEnrolmentRecord? = OrgProfileManager.loadStoredRecord
        var saveRecord: (OrgEnrolmentRecord?) -> Void = OrgProfileManager.saveStoredRecord
        var readSetting: (SettingKey) -> ProfileValue? = OrgProfileManager.readDefaults
        var writeSetting: (SettingKey, ProfileValue?) -> Void = OrgProfileManager.writeDefaults
        var activateLicence: @MainActor (String) throws -> Void = { code in _ = try LicenseService.shared.activate(code: code) }
        var storedLicenceCode: () -> String? = { UserDefaults.standard.string(forKey: LicenseService.storageKey) }
        var clearLicence: @MainActor () -> Void = { LicenseService.shared.clear() }
        var installEnvelope: (ProfileApplier.Result, String) -> Void = { PolicyEnvelope.install($0, organizationName: $1) }
        var clearEnvelope: () -> Void = { PolicyEnvelope.clear() }
        var newEnrolmentId: () -> String = { String(UUID().uuidString.prefix(8)).lowercased() }
        var fetch: (URL) async throws -> Data = OrgEnrolmentService.boundedFetch
        var activeJobId: @MainActor () -> String? = { FieldSessionService.shared.activeSession?.id }
        var withholdLicence: (String?) -> Void = { PolicyEnvelope.withholdLicence($0) }
    }

    /// The app's one manager. `PolicyEnvelope` is process-wide, so there is only ever one
    /// enrolment in force; tests build their own instance over injected seams instead.
    static let shared = OrgProfileManager()

    @Published private(set) var record: OrgEnrolmentRecord?
    @Published private(set) var profile: ConfigProfile?
    /// Set when the stored profile failed re-verification at launch. The phone runs unmanaged and
    /// the managed row says why, rather than trusting a document that no longer verifies.
    @Published private(set) var loadProblem: String?
    /// Where the lease stands, as of the last evaluation. Nil on an unmanaged phone.
    @Published private(set) var lease: ProfileLease.Status?
    /// Whether the organisation's content is locked right now (the lease is not in force and no
    /// job is holding the lock off).
    @Published private(set) var contentLocked = false

    private var seams: Seams
    private var jobObservation: AnyCancellable?

    init(seams: Seams = Seams()) {
        self.seams = seams
    }

    var isManaged: Bool { profile != nil }

    // MARK: - Launch

    /// Re-verify the stored document and put its ceiling back in force. Starting values are not
    /// re-written: they were starting values, and the person may have changed them since.
    func loadAtLaunch() {
        guard let stored = seams.loadRecord() else {
            record = nil
            profile = nil
            loadProblem = nil
            return
        }
        record = stored
        do {
            guard case .profile(let verified) = try ProfileVerification.verify(stored.document,
                                                                               keys: seams.verificationKeys) else {
                throw Refusal.revocation
            }
            profile = verified
            loadProblem = nil
            if stored.revoked == true {
                seams.clearEnvelope()
            } else {
                let result = ProfileApplier.apply(profile: verified, resolvableVaultIds: seams.resolvableVaultIds())
                seams.installEnvelope(result, verified.organizationName)
            }
        } catch {
            profile = nil
            loadProblem = "The stored organisation profile no longer verifies, so none of its settings are in force. Ask your organisation for a new code."
            seams.clearEnvelope()
        }
        evaluateLease()
    }

    /// Re-evaluate the lease whenever a job starts or ends, so a lapse deferred for a job locks the
    /// moment that job closes.
    func observeJobs() {
        jobObservation = FieldSessionService.shared.$activeSession
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in self?.evaluateLease() }
            }
    }

    // MARK: - Enrolment

    /// Verify a fetched document and build what the person is shown. Nothing is written.
    func review(document: String, source: ProfileSource,
                sourceURL: URL? = nil) -> Result<OrgProfileReview, Refusal> {
        let verified: ConfigProfile
        do {
            switch try ProfileVerification.verify(document, keys: seams.verificationKeys) {
            case .profile(let profile): verified = profile
            case .revocation: return .failure(.revocation)
            }
        } catch let failure as ProfileVerification.Failure {
            return .failure(.verification(failure))
        } catch {
            return .failure(.verification(.malformed))
        }
        if let refusal = ProfileVerification.enrolmentRefusal(for: verified, now: seams.now(),
                                                              licenceKey: seams.licenceKey) {
            return .failure(.verification(refusal))
        }
        if let current = profile, current.profileId != verified.profileId {
            return .failure(.managedByAnother(current.organizationName))
        }
        let result = ProfileApplier.apply(profile: verified, resolvableVaultIds: seams.resolvableVaultIds())
        return .success(OrgProfileReview(document: document, source: source, profile: verified,
                                         result: result, replacesCurrent: profile != nil,
                                         sourceURL: sourceURL))
    }

    /// Apply a reviewed profile: licence first, then settings, then the ceiling.
    func apply(_ review: OrgProfileReview) -> Result<Void, Refusal> {
        // The clock may have moved while the sheet was open.
        if let refusal = ProfileVerification.enrolmentRefusal(for: review.profile, now: seams.now(),
                                                              licenceKey: seams.licenceKey) {
            return .failure(.verification(refusal))
        }

        var activatedLicence = record?.activatedLicence ?? false
        if let code = review.profile.licenceCode {
            do {
                try seams.activateLicence(code)
                activatedLicence = true
            } catch {
                return .failure(.licence(error.localizedDescription))
            }
        }

        var priors = record?.priorStartingValues ?? [:]
        var wrote = Set(record?.wroteStartingKeys ?? [])
        writeStartingValues(review.result, onlyNewKeys: false, priors: &priors, wrote: &wrote)

        let now = seams.now()
        var newRecord = OrgEnrolmentRecord(
            document: review.document,
            source: review.source,
            enrolmentId: record?.enrolmentId ?? seams.newEnrolmentId(),
            enrolledAt: record?.enrolledAt ?? now,
            priorStartingValues: priors,
            wroteStartingKeys: wrote.sorted(),
            activatedLicence: activatedLicence)
        newRecord.profileURL = review.sourceURL ?? record?.profileURL
        newRecord.lastRenewedAt = now
        newRecord.lastRenewalAttempt = now
        newRecord.clockHighWater = max(record?.clockHighWater ?? now, now)
        seams.saveRecord(newRecord)
        record = newRecord
        profile = review.profile
        loadProblem = nil
        seams.installEnvelope(review.result, review.profile.organizationName)
        evaluateLease()
        return .success(())
    }

    /// Write the profile's starting values. Priors are recorded once, the first time a key is
    /// written — a renewal must not record the organisation's own earlier value as the person's —
    /// and a renewal writes only keys it has never written, so it does not undo what the person
    /// changed since.
    private func writeStartingValues(_ result: ProfileApplier.Result, onlyNewKeys: Bool,
                                     priors: inout [String: ProfileValue], wrote: inout Set<String>) {
        for (key, value) in result.startingValues {
            let isNew = !wrote.contains(key.rawValue)
            if onlyNewKeys && !isNew { continue }
            if isNew {
                if let prior = seams.readSetting(key) { priors[key.rawValue] = prior }
                wrote.insert(key.rawValue)
            }
            seams.writeSetting(key, value)
        }
    }

    // MARK: - The lease (Plan CT PR 2b)

    /// Where the lease stands now, and lock or unlock the organisation's content to match.
    @discardableResult
    func evaluateLease() -> ProfileLease.Status? {
        guard var current = record, let profile else {
            lease = nil
            contentLocked = false
            seams.withholdLicence(nil)
            return nil
        }
        let now = seams.now()
        let leaseDays = min(max(profile.leaseDays, ConfigProfile.leaseDaysRange.lowerBound),
                            ConfigProfile.leaseDaysRange.upperBound)
        let status = ProfileLease.status(leaseDays: leaseDays,
                                         lastRenewed: current.lastRenewedAt ?? current.enrolledAt,
                                         policyExpiry: profile.policyExpiry,
                                         clockHighWater: current.clockHighWater,
                                         revoked: current.revoked ?? false,
                                         now: now)
        if status != .clockWoundBack {
            current.clockHighWater = max(current.clockHighWater ?? now, now)
        }
        var lock = current.leaseLock ?? ProfileLease.Lock()
        let locked = lock.isLocked(status: status, activeJob: seams.activeJobId())
        current.leaseLock = lock
        if current != record {
            seams.saveRecord(current)
            record = current
        }
        lease = status
        contentLocked = locked
        seams.withholdLicence(locked && current.activatedLicence ? profile.licenceCode : nil)
        return status
    }

    /// Re-fetch the profile's URL and renew the lease, at most once a day unless `force`d.
    ///
    /// **Only a signed answer changes anything.** A fetch that fails — no signal, a timeout, a
    /// server error, a 404 from a host migration somebody got wrong — only fails to renew: an
    /// unsigned HTTP status is not a decision anybody made. A signed revocation document for this
    /// profile, or this enrolment's id in the profile's revoked list, revokes; the same profile,
    /// verified, renews.
    func renewIfDue(force: Bool = false) async {
        guard var current = record, let url = current.profileURL, let profile,
              current.revoked != true else {
            evaluateLease()
            return
        }
        let now = seams.now()
        if !force, let last = current.lastRenewalAttempt, last <= now,
           now.timeIntervalSince(last) < ProfileLease.renewalInterval {
            evaluateLease()
            return
        }
        current.lastRenewalAttempt = now
        seams.saveRecord(current)
        record = current

        let data = try? await seams.fetch(url)
        // The phone may have been un-managed or re-enrolled while the fetch was out.
        guard record?.enrolmentId == current.enrolmentId, self.profile?.profileId == profile.profileId,
              let data, let text = String(data: data, encoding: .utf8),
              let document = try? ProfileVerification.verify(text, keys: seams.verificationKeys) else {
            evaluateLease()
            return
        }
        switch document {
        case .revocation(let revocation) where revocation.profileId == profile.profileId:
            markRevoked()
        case .profile(let renewed) where renewed.profileId == profile.profileId:
            if (renewed.revokedEnrolmentIds ?? []).contains(current.enrolmentId) {
                markRevoked()
            } else {
                renew(with: renewed, document: text)
            }
        default:
            break
        }
        evaluateLease()
    }

    private func markRevoked() {
        guard var current = record else { return }
        current.revoked = true
        seams.saveRecord(current)
        record = current
        // Its rules lift with the revocation; its content stays locked (the lease is not in force).
        seams.clearEnvelope()
    }

    /// Apply a renewed copy of the same profile without asking: it is the organisation's own policy
    /// for a phone it already manages, so it may tighten, loosen or re-issue the licence — but it
    /// writes only starting values it has never written, so the person's own changes stand.
    private func renew(with renewed: ConfigProfile, document: String) {
        guard var current = record else { return }
        if let code = renewed.licenceCode, code != profile?.licenceCode {
            if (try? seams.activateLicence(code)) != nil { current.activatedLicence = true }
        }
        let result = ProfileApplier.apply(profile: renewed, resolvableVaultIds: seams.resolvableVaultIds())
        var priors = current.priorStartingValues
        var wrote = Set(current.wroteStartingKeys)
        writeStartingValues(result, onlyNewKeys: true, priors: &priors, wrote: &wrote)

        let renewedRecord = OrgEnrolmentRecord(
            document: document, source: current.source, enrolmentId: current.enrolmentId,
            enrolledAt: current.enrolledAt, priorStartingValues: priors,
            wroteStartingKeys: wrote.sorted(), activatedLicence: current.activatedLicence)
        var updated = renewedRecord
        updated.profileURL = current.profileURL
        updated.lastRenewedAt = seams.now()
        updated.lastRenewalAttempt = current.lastRenewalAttempt
        updated.clockHighWater = current.clockHighWater
        updated.revoked = false
        updated.leaseLock = nil
        seams.saveRecord(updated)
        record = updated
        profile = renewed
        seams.installEnvelope(result, renewed.organizationName)
    }

    // MARK: - Removal

    /// Remove the profile: lift the ceiling, put back the person's own starting values, and clear
    /// the licence only if this profile put it there. The caller has already obtained the device
    /// owner's grant. (Erasing the organisation's content on the way out is Plan CT PR 4.)
    func remove() -> Result<Void, Refusal> {
        guard let current = record else { return .success(()) }
        guard current.source.isLocallyRemovable else { return .failure(.notRemovable) }

        for name in current.wroteStartingKeys {
            guard let key = SettingKey(rawValue: name) else { continue }
            seams.writeSetting(key, current.priorStartingValues[name])
        }
        if current.activatedLicence, let code = profile?.licenceCode ?? storedProfileLicence(current),
           seams.storedLicenceCode() == code.trimmingCharacters(in: .whitespacesAndNewlines) {
            seams.clearLicence()
        }
        seams.saveRecord(nil)
        record = nil
        profile = nil
        loadProblem = nil
        lease = nil
        contentLocked = false
        seams.withholdLicence(nil)
        seams.clearEnvelope()
        return .success(())
    }

    /// The licence inside a stored document that no longer verifies — read without trusting it,
    /// only to recognise the code this profile activated so removal can clear it.
    private func storedProfileLicence(_ record: OrgEnrolmentRecord) -> String? {
        let parts = record.document.split(separator: ".")
        guard let first = parts.first, let payload = Data(base64Encoded: String(first)),
              let decoded = try? ProfileVerification.decoder.decode(ConfigProfile.self, from: payload) else {
            return nil
        }
        return decoded.licenceCode
    }

    // MARK: - Production seams

    nonisolated static let recordKey = "orgProfileEnrolment"

    nonisolated static func loadStoredRecord() -> OrgEnrolmentRecord? {
        guard let data = UserDefaults.standard.data(forKey: recordKey) else { return nil }
        return try? ProfileVerification.decoder.decode(OrgEnrolmentRecord.self, from: data)
    }

    nonisolated static func saveStoredRecord(_ record: OrgEnrolmentRecord?) {
        guard let record, let data = try? ProfileVerification.encoder.encode(record) else {
            UserDefaults.standard.removeObject(forKey: recordKey)
            return
        }
        UserDefaults.standard.set(data, forKey: recordKey)
    }

    /// Starting-value keys are `UserDefaults` keys verbatim.
    nonisolated static func readDefaults(_ key: SettingKey) -> ProfileValue? {
        switch UserDefaults.standard.object(forKey: key.rawValue) {
        case let flag as Bool: return .bool(flag)
        case let text as String: return .string(text)
        case let list as [String]: return .strings(list)
        default: return nil
        }
    }

    nonisolated static func writeDefaults(_ key: SettingKey, _ value: ProfileValue?) {
        switch value {
        case .bool(let flag)?: UserDefaults.standard.set(flag, forKey: key.rawValue)
        case .string(let text)?: UserDefaults.standard.set(text, forKey: key.rawValue)
        case .strings(let list)?: UserDefaults.standard.set(list, forKey: key.rawValue)
        case nil: UserDefaults.standard.removeObject(forKey: key.rawValue)
        }
    }
}

// MARK: - Review copy

extension SettingKey {
    /// One line for a ceiling, as the review sheet shows it.
    var ceilingDescription: String {
        switch self {
        case .organizationAllowsUnsignedVaults: return "Vaults from a link must be signed"
        case .organizationRequiresSignedJobFiles: return "Job files must be signed by your organisation"
        case .organizationRequiresCustomerSignOff: return "Every job asks for the customer's signature"
        case .privacyFilterEnabled: return "Bystander face blur is always on"
        case .remoteInvokeObserveEnabled: return "Remote status requests are off"
        case .remoteInvokeOutputEnabled: return "Remote speak-and-display requests are off"
        case .remoteInvokeCaptureEnabled: return "Remote camera, recording and transcript requests are off"
        case .mcpServerEnabled: return "The MCP glasses server is off"
        case .agentModeEnabled: return "Agentic features are off"
        default: return rawValue
        }
    }

    /// One line for organisation details the profile supplies.
    var ownedDescription: String {
        switch self {
        case .organizationDisplayName: return "Its name on the customer sign-off sheet"
        case .organizationJobSigningKey: return "The key its job files are signed with"
        case .organizationJobReportChannel: return "Where a spoken \"send it\" goes"
        case .organizationReportRecipients: return "Who job reports are addressed to"
        default: return rawValue
        }
    }

    /// One line for a starting value.
    func startingValueDescription(_ value: ProfileValue) -> String {
        switch (self, value) {
        case (.fieldAssistEnabled, .bool(let on)): return on ? "Field Assist is turned on" : "Field Assist is turned off"
        case (.fieldAssistDefaultVaultId, .string(let id)): return "Field Assist opens with the \(id) vault"
        case (.fieldAssistDefaultMode, .string(let mode)):
            return mode == FieldSession.Mode.humanAssisted.rawValue
                ? "Field Assist starts in human-assisted mode" : "Field Assist starts in AI-only mode"
        default: return rawValue
        }
    }
}

extension ProfileApplier.Drop.Reason {
    var explanation: String {
        switch self {
        case .unknownKey: return "not a setting this version of the app lets a profile set"
        case .unreadableValue: return "its value could not be read"
        case .wrongType: return "its value is the wrong kind"
        case .wrongDirection: return "a profile may only tighten this setting"
        case .unknownDisposition: return "it says neither default nor ceiling"
        case .dispositionNotAllowed(let disposition):
            return disposition == .ceiling ? "this setting cannot be locked" : "this setting can only be locked"
        case .invalidValue(let problem): return problem
        }
    }
}
