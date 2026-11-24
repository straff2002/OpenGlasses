import Foundation
import Combine
import UIKit

/// Plan ND P3 — the third `ProfileIngress`: the profile a company's MDM puts in Managed App
/// Configuration.
///
/// It reads `com.apple.configuration.managed` at launch, on every foreground and on
/// `UserDefaults.didChangeNotification`, because an MDM can change the dictionary while the app runs
/// (Plan CT's trap: "read managed config once at launch"). It reads and hands over, nothing else:
/// `ManagedConfigReading` decides what the dictionary says, and `ManagedConfigEnrolment` acts on it
/// through `OrgProfileManager`, where verification and apply live for every path.
@MainActor
final class ManagedConfigIngress: ProfileIngress {

    struct Seams {
        var readDictionary: () -> [String: Any]? = {
            UserDefaults.standard.dictionary(forKey: ManagedConfigReading.dictionaryKey)
        }
    }

    static let shared = ManagedConfigIngress()

    let source: ProfileSource = .managedConfig

    /// Each reading, in order. `ManagedConfigEnrolment` sets it.
    var onReading: ((ManagedConfigReading.Reading) -> Void)?

    private let seams: Seams
    private var lastRaw: NSDictionary?
    private var hasRead = false
    private var observers: [NSObjectProtocol] = []
    private var deliveryContinuations: [UUID: AsyncStream<ProfileDelivery>.Continuation] = [:]

    init(seams: Seams = Seams()) {
        self.seams = seams
    }

    /// Observe the dictionary from now on, and read it once.
    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UserDefaults.didChangeNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.read(force: false) }
        })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.read(force: true) }
        })
        read(force: true)
    }

    /// Read the dictionary. Defaults change for every setting the app writes, so a change
    /// notification hands over a reading only when the dictionary itself changed. Launch and
    /// foreground always do: the removal rule needs a second read some time after the first.
    func read(force: Bool) {
        let raw = seams.readDictionary()
        let bridged = raw.map { $0 as NSDictionary }
        if !force, hasRead, bridged == lastRaw { return }
        hasRead = true
        lastRaw = bridged
        let reading = ManagedConfigReading.read(raw)
        onReading?(reading)
        if let delivery = reading.delivery {
            for continuation in deliveryContinuations.values { continuation.yield(delivery) }
        }
    }

    func deliveries() -> AsyncStream<ProfileDelivery> {
        let id = UUID()
        return AsyncStream { continuation in
            deliveryContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.deliveryContinuations[id] = nil }
            }
        }
    }
}

/// Plan ND P3 — what the app tells the company's MDM, at `com.apple.feedback.managed`: which version
/// of the company's settings this phone is on, whether it is enrolled, and the app build. It goes to
/// the company's own MDM console (decision 13), never to the vendor. Pure.
enum ManagedConfigFeedback {
    static let dictionaryKey = "com.apple.feedback.managed"

    enum EnrolmentState: String, Equatable, Sendable {
        case notEnrolled, enrolled, waitingForJob, awaitingModelKey, lapsed, revoked, notVerified
    }

    static func state(record: OrgEnrolmentRecord?, profile: ConfigProfile?, loadProblem: String?,
                      lease: ProfileLease.Status?) -> EnrolmentState {
        guard let record else { return .notEnrolled }
        if record.revoked == true { return .revoked }
        guard profile != nil else { return loadProblem != nil ? .notVerified : .notEnrolled }
        if let lease, !lease.isInForce { return .lapsed }
        if record.heldProfileDocument != nil { return .waitingForJob }
        if record.modelSetupPending == true { return .awaitingModelKey }
        return .enrolled
    }

    static func dictionary(record: OrgEnrolmentRecord?, profile: ConfigProfile?, loadProblem: String?,
                           lease: ProfileLease.Status?, build: String) -> [String: Any] {
        var feedback: [String: Any] = [
            "enrolmentState": state(record: record, profile: profile, loadProblem: loadProblem, lease: lease).rawValue,
            "build": build,
        ]
        if let profile {
            feedback["profileId"] = profile.profileId
            if let generation = record?.profileGenerationHighWater { feedback["profileGeneration"] = generation }
        }
        return feedback
    }
}

/// Plan ND P3 — acting on what device management delivered, through `OrgProfileManager`.
///
/// - **A delivery** already in force does nothing (an address renews like a link). Anything else is
///   fetched if it is an address, then verified and applied by the manager (`receiveManagedDelivery`).
/// - **`activationKey`**, when the phone holds no company secret yet, is looked up once per reading
///   and its secret kept only when its licence is the company in force; then the company's sealed
///   credentials and AI key open, and nobody types the key.
/// - **Removal**: the phone leaves only once `ManagedConfigAbsence` confirms `orgProfile` is gone.
/// - **Feedback** is rewritten whenever the enrolment changes, and only when what it says changed
///   (a write to defaults is itself a change notification).
@MainActor
final class ManagedConfigEnrolment {

    struct Seams {
        var fetch: (URL) async throws -> Data = OrgEnrolmentService.boundedFetch
        var resolveActivationKey: (ActivationKey) async throws -> ActivationKey.Contents = {
            try await ActivationKeyResolver().resolveContents($0)
        }
        var hasCompanySecret: () -> Bool = { CompanySecretStore.device.read() != nil }
        /// Keep the secret, then open the profile's sealed credentials with it.
        var keepCompanySecret: @MainActor (Data, ConfigProfile) -> Void = { secret, profile in
            OrgCredentialSync.shared.keep(secret)
            OrgCredentialSync.shared.apply(profile)
        }
        var loadAbsence: () -> ManagedConfigAbsence = ManagedConfigEnrolment.loadStoredAbsence
        var saveAbsence: (ManagedConfigAbsence) -> Void = ManagedConfigEnrolment.saveStoredAbsence
        var readFeedback: () -> [String: Any]? = {
            UserDefaults.standard.dictionary(forKey: ManagedConfigFeedback.dictionaryKey)
        }
        var writeFeedback: ([String: Any]) -> Void = {
            UserDefaults.standard.set($0, forKey: ManagedConfigFeedback.dictionaryKey)
        }
        var now: () -> Date = Date.init
        var launchId: String = ManagedConfigEnrolment.processLaunchId
        var build: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        /// The organisation's model may have changed: what the app shows follows.
        var modelDidChange: @MainActor () -> Void = {}
    }

    nonisolated static let absenceKey = "managedConfigAbsence"
    nonisolated static let processLaunchId = UUID().uuidString

    private let manager: OrgProfileManager
    private let seams: Seams
    private var latest: ManagedConfigReading.Reading?
    private var worker: Task<Void, Never>?
    private var loggedIgnoredKeys: [String]?
    private var loggedAbsence = false
    /// Whether this phone has heard from device management in this launch: feedback is written
    /// only to a phone an MDM configures, or one it configured before.
    private var managedByMDM = false
    private var recordObservation: AnyCancellable?

    init(manager: OrgProfileManager, seams: Seams = Seams()) {
        self.manager = manager
        self.seams = seams
    }

    /// Take readings from `ingress`, and keep the feedback current as the enrolment changes.
    func start(_ ingress: ManagedConfigIngress) {
        ingress.onReading = { [weak self] in self?.receive($0) }
        recordObservation = manager.$record.dropFirst()
            .sink { [weak self] _ in Task { @MainActor in self?.writeFeedbackIfChanged() } }
        ingress.start()
    }

    /// Readings are handled one at a time; a reading that arrives during a fetch replaces any still
    /// waiting, since only the latest dictionary matters.
    func receive(_ reading: ManagedConfigReading.Reading) {
        latest = reading
        guard worker == nil else { return }
        worker = Task { [weak self] in
            while let self, let next = self.latest {
                self.latest = nil
                await self.handle(next)
            }
            self?.worker = nil
        }
    }

    func handle(_ reading: ManagedConfigReading.Reading) async {
        if !reading.ignoredKeys.isEmpty, reading.ignoredKeys != loggedIgnoredKeys {
            loggedIgnoredKeys = reading.ignoredKeys
            PrivacyLog.transfer(.companyProfile, .managedIgnoredKeys, count: reading.ignoredKeys.count)
        }
        for problem in reading.problems {
            PrivacyLog.transfer(.companyProfile, .managedUnreadable, operation: PrivacyToken(Self.name(problem)))
        }
        // An `orgProfile` that is there but unreadable is still there: it never counts toward removal.
        let profilePresent = reading.delivery != nil
            || reading.problems.contains(.profileNotText) || reading.problems.contains(.profileUnreadable)
        if profilePresent || reading.activationKey != nil || seams.readFeedback() != nil {
            managedByMDM = true
        }

        var absence = seams.loadAbsence()
        let confirmed = absence.observe(profilePresent: profilePresent, now: seams.now(), launchId: seams.launchId)
        defer { writeFeedbackIfChanged() }

        guard profilePresent else {
            guard manager.record?.source == .managedConfig else {
                seams.saveAbsence(ManagedConfigAbsence())
                return
            }
            if confirmed {
                seams.saveAbsence(ManagedConfigAbsence())
                if manager.leaveDeviceManagement() {
                    PrivacyLog.transfer(.companyProfile, .managedLeft)
                    seams.modelDidChange()
                }
                loggedAbsence = false
            } else {
                seams.saveAbsence(absence)
                if !loggedAbsence {
                    loggedAbsence = true
                    PrivacyLog.transfer(.companyProfile, .managedAbsent)
                }
            }
            return
        }
        seams.saveAbsence(absence)
        loggedAbsence = false
        guard let delivery = reading.delivery else { return }

        var contents: ActivationKey.Contents?
        if let key = reading.activationKey, !seams.hasCompanySecret() {
            contents = try? await seams.resolveActivationKey(key)
        }

        if !manager.managedDeliveryIsInForce(delivery) {
            let document: String
            let address: URL?
            switch delivery {
            case .inline(let text):
                document = text
                address = nil
            case .pointer(let url):
                guard let data = try? await seams.fetch(url), let text = String(data: data, encoding: .utf8) else {
                    PrivacyLog.transfer(.companyProfile, .managedFetchFailed)
                    return
                }
                document = text
                address = url
            }
            let outcome = manager.receiveManagedDelivery(document, sourceURL: address,
                                                         enteredLicence: contents?.licenceCode)
            log(outcome)
            switch outcome {
            case .enrolled, .moved:
                seams.modelDidChange()
                // The pack and the company's vaults, as after a confirmed enrolment (Plan LR).
                Task { [manager] in await manager.completeEnrolment() }
            case .renewed, .revoked:
                seams.modelDidChange()
            case .held, .unchanged, .refused:
                break
            }
        }

        if let contents, let secret = contents.companySecret, let profile = manager.profile,
           manager.acceptsCompanySecret(forLicence: contents.licenceCode) {
            seams.keepCompanySecret(secret, profile)
            manager.reconcileOrganizationModel()
            seams.modelDidChange()
        }
    }

    private func log(_ outcome: OrgProfileManager.ManagedDeliveryOutcome) {
        let generation = manager.record?.profileGenerationHighWater.map { PrivacyToken(String($0)) }
        switch outcome {
        case .enrolled: PrivacyLog.transfer(.companyProfile, .managedEnrolled, version: generation)
        case .moved: PrivacyLog.transfer(.companyProfile, .managedMoved, version: generation)
        case .renewed: PrivacyLog.transfer(.companyProfile, .managedRenewed, version: generation)
        case .refused(let refusal): PrivacyLog.transfer(.companyProfile, .managedRefused,
                                                        operation: PrivacyToken(Self.name(refusal)))
        case .held, .unchanged, .revoked: break
        }
    }

    private func writeFeedbackIfChanged() {
        guard managedByMDM else { return }
        let feedback = ManagedConfigFeedback.dictionary(record: manager.record, profile: manager.profile,
                                                        loadProblem: manager.loadProblem, lease: manager.lease,
                                                        build: seams.build)
        if let current = seams.readFeedback(), (current as NSDictionary) == (feedback as NSDictionary) { return }
        seams.writeFeedback(feedback)
    }

    // MARK: - Closed vocabularies for the log

    nonisolated static func name(_ problem: ManagedConfigReading.Problem) -> String {
        switch problem {
        case .profileNotText: return "profileNotText"
        case .profileUnreadable: return "profileUnreadable"
        case .activationKeyUnreadable: return "activationKeyUnreadable"
        }
    }

    nonisolated static func name(_ refusal: OrgProfileManager.Refusal) -> String {
        switch refusal {
        case .verification: return "verification"
        case .revocation: return "revocation"
        case .managedByAnother: return "managedByAnother"
        case .managedByDevice: return "managedByDevice"
        case .moveChanged: return "moveChanged"
        case .differentOrganisation: return "differentOrganisation"
        case .licence: return "licence"
        case .officePackage: return "officePackage"
        case .notRemovable: return "notRemovable"
        case .enrolmentChanged: return "enrolmentChanged"
        case .staleProfile: return "staleProfile"
        }
    }

    // MARK: - Production storage

    /// Owned by `OrgProfileManager`'s record in the data-store registry: one date and a launch id.
    nonisolated static func loadStoredAbsence() -> ManagedConfigAbsence {
        guard let data = UserDefaults.standard.data(forKey: absenceKey),
              let absence = try? JSONDecoder().decode(ManagedConfigAbsence.self, from: data) else {
            return ManagedConfigAbsence()
        }
        return absence
    }

    nonisolated static func saveStoredAbsence(_ absence: ManagedConfigAbsence) {
        if absence == ManagedConfigAbsence() {
            UserDefaults.standard.removeObject(forKey: absenceKey)
        } else if let data = try? JSONEncoder().encode(absence) {
            UserDefaults.standard.set(data, forKey: absenceKey)
        }
    }
}
