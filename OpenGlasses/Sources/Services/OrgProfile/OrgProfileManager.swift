import Foundation
import Combine

/// Plan CT PR 2 — what is stored about the enrolled profile.
///
/// The **document** is kept, not the decoded profile: it is re-verified on every launch, so what
/// storage holds is evidence rather than a verdict — the rule Plan DP set for licence codes.
struct OrgEnrolmentRecord: Codable, Equatable, Sendable {
    /// The signed document exactly as it was verified. Replaced by each renewal.
    var document: String
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
    /// The licence code enrolment activated, when it was not the profile's own — a licence key
    /// entered by hand whose `profile` claim named this profile (Plan CT 3a). Nil means the profile's.
    var activatedLicenceCode: String?

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

    // Plan CT PR 3b — the vault pack enrolment installs.

    /// The pack the profile names, while it is not yet installed. Enrolment does not wait on the
    /// download — the ceiling and the licence are the safety half — so it is retried until it lands.
    var pendingPackId: String?
    /// Why the last attempt failed, for the managed row.
    var packInstallError: String?
    /// Starting values held back until the pack is installed: the default vault (which would point
    /// at a vault the registry cannot resolve) and switching Field Assist on (which would open a
    /// home screen with nothing behind it).
    var heldStartingValues: [String: ProfileValue]?

    // Plan CT 3a — the organisation's AI model.

    /// The `ModelConfig` enrolment created from the profile's `aiModel`. It is the organisation's —
    /// its key too, whoever typed it — so removal deletes it. The person's own configs are untouched.
    var modelConfigId: String?
    /// The profile names a model that still needs its key (or its sign-in): Field Assist says the
    /// administrator needs to finish setting up this phone.
    var modelSetupPending: Bool?
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
    /// The licence enrolment will activate, when it is the entered key rather than the profile's
    /// own code (Plan CT 3a: the later-issued of the two).
    var licenceToActivate: String? = nil

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

    var carriesLicence: Bool { (licenceToActivate ?? profile.licenceCode) != nil }

    /// The vault pack enrolment will install, if the profile names one.
    var packId: String? { profile.vaultPack?.packId }

    /// What the edition changes and how administrator settings open (Plan CT 3b).
    var adminLines: [String] {
        guard let policy = result.adminPolicy else { return [] }
        var lines: [String]
        switch policy.edition {
        case .fieldAssist: lines = ["Shows only Field Assist, Job and a short Settings list"]
        }
        switch policy.credentials.method {
        case .card: lines.append("Administrator settings open with your organisation's admin card")
        case .passcode: lines.append("Administrator settings open with your organisation's passcode")
        case .cardOrPasscode: lines.append("Administrator settings open with the admin card or passcode")
        case .deviceOwner: lines.append("Anyone who can unlock this phone can open administrator settings")
        }
        return lines
    }

    /// The AI model the profile names, and where its prompts go when that is not the provider's own
    /// address. The key is not the profile's: it is entered on the next page.
    var aiModelLines: [String] {
        guard let model = result.aiModel else { return [] }
        var lines = ["AI model: \(model.summary)"]
        if let host = model.host { lines.append("Prompts go to \(host)") }
        return lines
    }

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
        /// The licence key entered and the profile it points at name different organisations.
        case differentOrganisation(entered: String, profile: String)
        case licence(String)
        case notRemovable

        var errorDescription: String? {
            switch self {
            case .verification(let failure): return failure.errorDescription
            case .revocation: return "That link carries a revocation, not a profile. There is nothing to apply."
            case .managedByAnother(let name): return "This phone is already managed by \(name). Remove that first, from Settings."
            case .differentOrganisation(let entered, let profile):
                return "This licence is for \(entered), but the profile it points to is for \(profile). Ask your organisation for a new key."
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
        var installPack: @MainActor (String) async -> OrgPackInstaller.Outcome = { await OrgPackInstaller.install(packId: $0) }
        var loadModels: () -> [ModelConfig] = { Config.savedModels }
        var saveModels: ([ModelConfig]) -> Void = { Config.setSavedModels($0) }
        var activeModelId: () -> String = { Config.activeModelId }
        var setActiveModelId: (String) -> Void = { Config.setActiveModelId($0) }
        var newModelConfigId: () -> String = { UUID().uuidString }
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
                sourceURL: URL? = nil, enteredLicence: String? = nil) -> Result<OrgProfileReview, Refusal> {
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
        // A licence key that pointed here must name the same organisation as the profile's own
        // licence, and the later-issued of the two is the one activated — so a renewal re-minted at
        // the same address wins over an older code entered from an email.
        var licenceToActivate: String?
        if let entered = enteredLicence,
           let enteredPayload = try? LicenseService.decode(code: entered, publicKeyBase64: seams.licenceKey) {
            if let own = verified.licenceCode,
               let ownPayload = try? LicenseService.decode(code: own, publicKeyBase64: seams.licenceKey) {
                guard ownPayload.licensee == enteredPayload.licensee else {
                    return .failure(.differentOrganisation(entered: enteredPayload.licensee,
                                                           profile: ownPayload.licensee))
                }
                if enteredPayload.issued > ownPayload.issued { licenceToActivate = entered }
            } else {
                licenceToActivate = entered
            }
        }
        let result = ProfileApplier.apply(profile: verified,
                                          resolvableVaultIds: resolvableIncludingPack(verified))
        return .success(OrgProfileReview(document: document, source: source, profile: verified,
                                         result: result, replacesCurrent: profile != nil,
                                         sourceURL: sourceURL, licenceToActivate: licenceToActivate))
    }

    /// Apply a reviewed profile: licence first, then settings, then the ceiling.
    func apply(_ review: OrgProfileReview) -> Result<Void, Refusal> {
        // The clock may have moved while the sheet was open.
        if let refusal = ProfileVerification.enrolmentRefusal(for: review.profile, now: seams.now(),
                                                              licenceKey: seams.licenceKey) {
            return .failure(.verification(refusal))
        }

        var activatedLicence = record?.activatedLicence ?? false
        let licence = review.licenceToActivate ?? review.profile.licenceCode
        if let code = licence {
            do {
                try seams.activateLicence(code)
                activatedLicence = true
            } catch {
                return .failure(.licence(error.localizedDescription))
            }
        }

        // Step 3 before step 4: with a pack still to install, the default vault and the Field Assist
        // switch wait for it, and everything else is written now.
        // (The installer returns at once for a pack that is already on the phone.)
        var pendingPack: String?
        var held: [String: ProfileValue] = [:]
        var writable = review.result
        if let packId = review.profile.vaultPack?.packId {
            pendingPack = packId
            for key in [SettingKey.fieldAssistDefaultVaultId, .fieldAssistEnabled] {
                if let value = writable.startingValues.removeValue(forKey: key) { held[key.rawValue] = value }
            }
        }

        var priors = record?.priorStartingValues ?? [:]
        var wrote = Set(record?.wroteStartingKeys ?? [])
        writeStartingValues(writable, onlyNewKeys: false, priors: &priors, wrote: &wrote)

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
        newRecord.activatedLicenceCode = review.licenceToActivate
        newRecord.pendingPackId = pendingPack
        newRecord.heldStartingValues = held.isEmpty ? nil : held
        newRecord.modelConfigId = record?.modelConfigId
        newRecord.modelSetupPending = record?.modelSetupPending
        reconcileModel(review.result.aiModel, organizationName: review.profile.organizationName,
                       record: &newRecord)
        seams.saveRecord(newRecord)
        record = newRecord
        profile = review.profile
        loadProblem = nil
        seams.installEnvelope(review.result, review.profile.organizationName)
        evaluateLease()
        return .success(())
    }

    /// The vaults a review may count as resolvable: those installed now, plus — when the profile
    /// names a pack — the default vault it names, which the pack is expected to provide. Whether it
    /// really does is checked when the pack lands, before the default is written.
    private func resolvableIncludingPack(_ profile: ConfigProfile) -> Set<String> {
        var ids = seams.resolvableVaultIds()
        if profile.vaultPack != nil,
           case .string(let vaultId)? = profile.settings[SettingKey.fieldAssistDefaultVaultId.rawValue]?.value {
            ids.insert(vaultId)
        }
        return ids
    }

    // MARK: - The vault pack (Plan CT PR 3b)

    /// Install the pack the profile names, then write the starting values that were waiting for it.
    ///
    /// Called right after enrolment and again at launch and on every foreground until it succeeds. A
    /// failure is recorded, named on the managed row, and retried; the ceiling and the licence were in
    /// force from the moment the profile was applied, so nothing about the device's bounds waits on
    /// this download. The default vault is written only if a vault with that id now resolves — a
    /// pack that turns out to provide a different vault leaves the default where it was, rather than
    /// pointing it at nothing.
    func completePendingPack() async {
        guard let current = record, let packId = current.pendingPackId, current.revoked != true else { return }
        let outcome = await seams.installPack(packId)
        guard var latest = record, latest.enrolmentId == current.enrolmentId,
              latest.pendingPackId == packId else { return }
        switch outcome {
        case .failed(let reason):
            latest.packInstallError = reason
        case .installed:
            let resolvable = seams.resolvableVaultIds()
            var ready = ProfileApplier.Result()
            for (name, value) in latest.heldStartingValues ?? [:] {
                guard let key = SettingKey(rawValue: name) else { continue }
                if key == .fieldAssistDefaultVaultId {
                    guard case .string(let vaultId) = value, resolvable.contains(vaultId) else { continue }
                }
                ready.startingValues[key] = value
            }
            var priors = latest.priorStartingValues
            var wrote = Set(latest.wroteStartingKeys)
            writeStartingValues(ready, onlyNewKeys: false, priors: &priors, wrote: &wrote)
            latest.priorStartingValues = priors
            latest.wroteStartingKeys = wrote.sorted()
            latest.pendingPackId = nil
            latest.packInstallError = nil
            latest.heldStartingValues = nil
        }
        seams.saveRecord(latest)
        record = latest
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

    // MARK: - The organisation's AI model (Plan CT 3a)

    /// The model the profile in force names, checked. Nil when it names none it can use.
    var organizationModel: OrgAIModel? {
        profile?.aiModel.flatMap { try? OrgAIModel.resolve($0).get() }
    }

    /// The edition in force and how its administrator gets past it (Plan CT 3b). Nil on an
    /// unmanaged or revoked phone: a revocation lifts the organisation's rules, its view included.
    var adminPolicy: AdminPolicy? {
        guard let profile, record?.revoked != true else { return nil }
        return ProfileApplier.apply(profile: profile, resolvableVaultIds: []).adminPolicy
    }

    /// The profile names a model that still waits for its key or sign-in — the "administrator
    /// needs to finish setting up this phone" state.
    var needsModelSetup: Bool {
        guard let record, record.revoked != true else { return false }
        return record.modelSetupPending == true && organizationModel != nil
    }

    /// Bring the organisation's model config in line with the profile's `aiModel`.
    ///
    /// - The same provider as the config enrolment already made: the model, address and label
    ///   follow the profile and **the key stays** — a renewal that moves to a newer model needs no
    ///   one to re-enter anything.
    /// - A provider with nothing to enter (on-device): the config is made now.
    /// - Otherwise the phone waits for the key, and the config already in place (if any) stays in
    ///   use meanwhile, so a technician is never dropped into a provider with no key.
    /// - A profile that stops naming a model changes nothing: the config stays until removal.
    private func reconcileModel(_ model: OrgAIModel?, organizationName: String,
                                record: inout OrgEnrolmentRecord) {
        guard let model else {
            record.modelSetupPending = nil
            return
        }
        var models = seams.loadModels()
        if let id = record.modelConfigId, let index = models.firstIndex(where: { $0.id == id }),
           models[index].provider == model.provider.rawValue {
            let updated = model.makeConfig(id: id, apiKey: models[index].apiKey,
                                           organizationName: organizationName)
            if models[index] != updated {
                models[index].name = updated.name
                models[index].model = updated.model
                models[index].baseURL = updated.baseURL
                seams.saveModels(models)
            }
            record.modelSetupPending = nil
            return
        }
        if model.access == .onDevice {
            installModel(model, apiKey: "", organizationName: organizationName, record: &record)
        } else {
            record.modelSetupPending = true
        }
    }

    /// Save the organisation's model with the key the person entered (or none, after a sign-in),
    /// make it the active model, and replace the config an earlier profile made. The caller has
    /// run `OrgAIModel.keyProblem` on the key.
    @discardableResult
    func completeModelSetup(apiKey: String) -> Bool {
        guard var current = record, current.revoked != true, let profile, let model = organizationModel else {
            return false
        }
        if model.access == .key && model.keyProblem(apiKey) != nil { return false }
        installModel(model, apiKey: apiKey, organizationName: profile.organizationName, record: &current)
        seams.saveRecord(current)
        record = current
        return true
    }

    private func installModel(_ model: OrgAIModel, apiKey: String, organizationName: String,
                              record: inout OrgEnrolmentRecord) {
        var models = seams.loadModels()
        if let previous = record.modelConfigId { models.removeAll { $0.id == previous } }
        let config = model.makeConfig(id: seams.newModelConfigId(), apiKey: apiKey,
                                      organizationName: organizationName)
        models.append(config)
        seams.saveModels(models)
        seams.setActiveModelId(config.id)
        record.modelConfigId = config.id
        record.modelSetupPending = nil
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
        seams.withholdLicence(locked && current.activatedLicence
                              ? (current.activatedLicenceCode ?? profile.licenceCode) : nil)
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
        await completePendingPack()
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
        if let code = renewed.licenceCode, code != profile?.licenceCode,
           (try? seams.activateLicence(code)) != nil {
            current.activatedLicence = true
            // The profile's own code is now the one in force, not a key entered by hand.
            current.activatedLicenceCode = nil
        }
        let result = ProfileApplier.apply(profile: renewed, resolvableVaultIds: seams.resolvableVaultIds())
        // Values still waiting for the pack keep waiting: a renewal must not write them early.
        var writable = result
        if current.pendingPackId != nil {
            for name in (current.heldStartingValues ?? [:]).keys {
                if let key = SettingKey(rawValue: name) { writable.startingValues.removeValue(forKey: key) }
            }
        }
        var priors = current.priorStartingValues
        var wrote = Set(current.wroteStartingKeys)
        writeStartingValues(writable, onlyNewKeys: true, priors: &priors, wrote: &wrote)

        // The record is updated in place, so nothing a later phase added to it — the pack still
        // pending, the licence entered by hand — is lost on renewal.
        current.document = document
        current.priorStartingValues = priors
        current.wroteStartingKeys = wrote.sorted()
        current.lastRenewedAt = seams.now()
        current.revoked = false
        current.leaseLock = nil
        reconcileModel(result.aiModel, organizationName: renewed.organizationName, record: &current)
        seams.saveRecord(current)
        record = current
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
        if current.activatedLicence,
           let code = current.activatedLicenceCode ?? profile?.licenceCode ?? storedProfileLicence(current),
           seams.storedLicenceCode() == code.trimmingCharacters(in: .whitespacesAndNewlines) {
            seams.clearLicence()
        }
        if let id = current.modelConfigId {
            var models = seams.loadModels()
            models.removeAll { $0.id == id }
            seams.saveModels(models)
            if seams.activeModelId() == id, let next = models.first { seams.setActiveModelId(next.id) }
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
