import Foundation

/// Joining an Avenkin office by scanning its code (Contracts/commissioning.md): the phone reads the
/// office's invitation, answers it with a redemption signed by its application key, shows the
/// comparison code while someone at the office decides, and on approval puts the three artefacts
/// through the checks the phone already has — the vendor-signed profile and licence pair, the
/// owner's review, then the administrator-signed peer binding against the administrator key in
/// that profile — before it is enrolled and paired.
///
/// The decisions are `OfficeCommissioningFlow`'s; this drives them. Nothing is applied until the
/// person accepts the review, and nothing at all if they decline it or the binding fails.
@MainActor
final class OfficeCommissioningService: ObservableObject {

    enum Stage: Equatable {
        case idle
        /// Reading the scanned code.
        case checking
        case notStarted(OfficeCommissioningFlow.NotStarted)
        /// Building, signing and sending the redemption, until the office first answers.
        case sending
        /// The office has the redemption: both screens show this code until a person decides.
        case waiting(code: String)
        /// The office could not be reached. A retry sends the same redemption again.
        case networkFailure
        case refused(OfficeCommissioning.RefusalReason)
        case expired
        /// The office approved and its setup verified: the organisation's review, as for a setup file.
        case reviewing(OrgProfileReview)
        /// Checking the office binding, applying the profile and keeping the binding.
        case pairing
        /// Joined, and the organisation's AI model still needs its key (Plan CT 3a).
        case modelKey(OrgAIModel, organization: String)
        case paired(String)
        case failed(OfficeCommissioningFlow.Failure)

        var isBusy: Bool {
            switch self {
            case .checking, .pairing: return true
            default: return false
            }
        }
    }

    struct Seams {
        /// Nil in a build without the office transport.
        var transport: () -> (any OfficeCommissionTransport)? = OfficeCommissionMobilecoreTransport.makeIfAvailable
        var phoneTransportID: () async throws -> String = { try await OfficeTransportIdentity.shared.deviceID() }
        var phoneApplicationKey: () async throws -> Data = { try await OfficePhoneIdentity.shared.publicKey() }
        var signRedemption: (Data) async throws -> Data = {
            try await OfficePhoneIdentity.shared.signCommissionRedemption($0)
        }
        var highWater: OfficePeerHighWaterStore = .shared
        var approvedPeerStore: OfficeApprovedPeerStore = .shared
        var profileKeys: [String: String] = ProfileVerification.productionKeys
        var licenceKey: String = LicenseService.productionPublicKeyBase64
        var now: () -> Date = Date.init
        var pause: (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
        var appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        var appBuild: String = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        /// Tells the app the active model changed, so what it shows follows.
        var modelDidChange: @MainActor () -> Void = {}
    }

    /// Everything about one exchange that must not change once the redemption is sent: a retry
    /// re-sends exactly this, never a new one.
    private struct Exchange {
        let invitation: OfficeCommissioning.Invitation
        let enrolmentID: String
        let phoneTransportID: String
        let phoneApplicationKey: Data
        let redemptionEnvelope: String
        let comparisonCode: String
        var reachedOffice = false
        var approval: OfficeCommissioning.Approval?
    }

    @Published private(set) var stage: Stage = .idle

    private let manager: OrgProfileManager
    private var seams: Seams
    private var exchange: Exchange?
    private var work: Task<Void, Never>?

    init(manager: OrgProfileManager, seams: Seams = Seams()) {
        self.manager = manager
        self.seams = seams
    }

    /// When the office's code stops being answerable.
    var expiresAt: Date? {
        exchange.map { Date(timeIntervalSince1970: TimeInterval($0.invitation.expiresAt)) }
    }

    // MARK: - The code is scanned

    /// Text from the in-app scanner that starts with the office code's prefix.
    func start(qrText: String) {
        reset()
        guard let transport = seams.transport() else {
            stage = .notStarted(.unsupportedBuild)
            return
        }
        stage = .checking
        work = Task { [weak self] in await self?.begin(qrText: qrText, transport: transport) }
    }

    private func begin(qrText: String, transport: any OfficeCommissionTransport) async {
        let now = nowSeconds()
        let invitation: OfficeCommissioning.Invitation
        do {
            invitation = try OfficeCommissioning.decodeInvitation(await transport.readQR(qrText, now: now))
        } catch {
            guard !Task.isCancelled else { return }
            stage = .notStarted(OfficeCommissioningFlow.unreadable(qrText: qrText, now: now))
            return
        }
        guard !Task.isCancelled else { return }
        let current = currentEnrolment()
        if let refusal = OfficeCommissioningFlow.beforeConnecting(invitation, current: current, now: nowSeconds()) {
            stage = .notStarted(refusal)
            return
        }

        // The phone's own identities and enrolment, from its own storage — never from the code.
        let phoneTransportID: String
        let phoneApplicationKey: Data
        do {
            phoneTransportID = try await seams.phoneTransportID()
            phoneApplicationKey = try await seams.phoneApplicationKey()
        } catch {
            guard !Task.isCancelled else { return }
            stage = .notStarted(.noIdentity)
            return
        }
        guard !Task.isCancelled else { return }
        let enrolmentID = manager.enrolmentIDForCommissioning()

        stage = .sending
        let redemption: String
        let code: String
        do {
            let input = try OfficeCommissioning.decodeSigningInput(await transport.redemptionSigningInput(
                invitationEnvelope: invitation.invitationEnvelope, enrolmentID: enrolmentID,
                phoneTransportID: phoneTransportID,
                phoneApplicationKey: phoneApplicationKey.base64EncodedString(),
                appVersion: seams.appVersion, appBuild: seams.appBuild,
                existingEnrolment: OfficeCommissioningFlow.existingEnrolment(current),
                now: nowSeconds()))
            guard let checked = OfficeCommissioningFlow.checkedSigningInput(input) else {
                throw OfficeCommissioning.DecodingFailure.malformed
            }
            let signature = try await seams.signRedemption(checked.signingInput)
            redemption = try await transport.sealRedemption(
                invitationEnvelope: invitation.invitationEnvelope,
                payloadBase64: input.payload, signatureBase64: signature.base64EncodedString())
            code = try await transport.comparison(invitationEnvelope: invitation.invitationEnvelope,
                                                  redemptionEnvelope: redemption)
            guard OfficeCommissioningFlow.comparisonGroups(code) != nil else {
                throw OfficeCommissioning.DecodingFailure.malformed
            }
        } catch {
            guard !Task.isCancelled else { return }
            stage = .failed(.couldNotAnswer)
            return
        }
        guard !Task.isCancelled else { return }
        exchange = Exchange(invitation: invitation, enrolmentID: enrolmentID,
                            phoneTransportID: phoneTransportID, phoneApplicationKey: phoneApplicationKey,
                            redemptionEnvelope: redemption, comparisonCode: code)
        await ask(transport)
    }

    // MARK: - Waiting for the office

    /// Ask the office until a person there decides or the code expires.
    private func ask(_ transport: any OfficeCommissionTransport) async {
        var failures = 0
        while !Task.isCancelled, let current = exchange {
            let expiresAt = current.invitation.expiresAt
            guard OfficeCommissioningFlow.shouldAsk(expiresAt: expiresAt, now: nowSeconds()) else {
                stage = .expired
                return
            }
            do {
                let answer = try await transport.exchange(invitationEnvelope: current.invitation.invitationEnvelope,
                                                          redemptionEnvelope: current.redemptionEnvelope)
                guard !Task.isCancelled else { return }
                failures = 0
                exchange?.reachedOffice = true
                let decision: OfficeCommissioning.Decision
                do {
                    decision = try OfficeCommissioning.decodeDecision(answer)
                } catch {
                    stage = .failed(.unreadableAnswer)
                    return
                }
                switch OfficeCommissioningFlow.afterAnswer(decision, chosenEnrolmentID: current.enrolmentID,
                                                           expiresAt: expiresAt, now: nowSeconds()) {
                case .keepWaiting:
                    stage = .waiting(code: current.comparisonCode)
                case .approved(let approval):
                    exchange?.approval = approval
                    review(approval, invitation: current.invitation)
                    return
                case .refused(let reason):
                    stage = .refused(reason)
                    return
                case .expired:
                    stage = .expired
                    return
                case .failed(let failure):
                    stage = .failed(failure)
                    return
                }
            } catch {
                guard !Task.isCancelled else { return }
                failures += 1
                switch OfficeCommissioningFlow.afterNetworkFailure(consecutive: failures, expiresAt: expiresAt,
                                                                   now: nowSeconds()) {
                case .tryAgainQuietly:
                    break
                case .offerRetry:
                    stage = .networkFailure
                    return
                case .expired:
                    stage = .expired
                    return
                }
            }
            do { try await seams.pause(OfficeCommissioning.pollInterval) } catch { return }
        }
    }

    /// After a network failure: the same redemption, sent again.
    func retry() {
        guard stage == .networkFailure, let current = exchange, let transport = seams.transport() else { return }
        stage = current.reachedOffice ? .waiting(code: current.comparisonCode) : .sending
        work?.cancel()
        work = Task { [weak self] in await self?.ask(transport) }
    }

    // MARK: - The approval

    /// First of the three artefacts: the vendor-signed profile and licence, verified by the same
    /// review a setup file gets, then shown to the person.
    private func review(_ approval: OfficeCommissioning.Approval, invitation: OfficeCommissioning.Invitation) {
        switch manager.review(document: approval.profileDocument, source: .office,
                              enteredLicence: approval.licenceCode) {
        case .success(let review):
            guard OfficeCommissioningFlow.setupMatchesInvitation(
                profileOrganizationID: review.profile.officeAuthority?.organizationID,
                invitation: invitation) else {
                stage = .failed(.otherOrganisationsSetup)
                return
            }
            stage = .reviewing(review)
        case .failure(let refusal):
            stage = .failed(.setupDidNotVerify(refusal.errorDescription ?? ""))
        }
    }

    /// The person accepted the review. The administrator-signed binding is checked before
    /// anything is applied; then the profile is applied under the enrolment this phone chose, and
    /// the binding is kept by the same gate a binding file goes through.
    func confirm() {
        guard case .reviewing(let review) = stage, let current = exchange,
              let approval = current.approval else { return }
        stage = .pairing
        work?.cancel()
        work = Task { [weak self] in await self?.pair(review, current: current, approval: approval) }
    }

    private func pair(_ review: OrgProfileReview, current: Exchange,
                      approval: OfficeCommissioning.Approval) async {
        let invitation = current.invitation
        let binding = Data(approval.peerBinding.utf8)
        guard let officeKey = Data(base64Encoded: invitation.officeApplicationKey), officeKey.count == 32 else {
            stage = .failed(.bindingDidNotVerify)
            return
        }
        let office = OfficePairingService.ReviewedOffice(
            officeID: invitation.officeID, transportID: invitation.officeTransportID,
            applicationPublicKey: officeKey)
        do {
            let now = seams.now()
            let root = try OfficePeerBinding.vendorRoot(profileDocument: approval.profileDocument,
                                                        vendorKeys: seams.profileKeys, now: now)
            let prior = try await seams.highWater.read(organizationID: root.organizationID,
                                                       enrolmentID: current.enrolmentID)
            _ = try OfficePeerBinding.verify(
                binding, root: root,
                expected: .init(enrolmentID: current.enrolmentID, officeID: office.officeID,
                                officeTransportID: office.transportID,
                                officeApplicationKey: office.applicationPublicKey,
                                phoneTransportID: current.phoneTransportID,
                                phoneApplicationKey: current.phoneApplicationKey,
                                minimumGeneration: prior?.generation ?? 1),
                now: Int64(now.timeIntervalSince1970))
        } catch {
            guard !Task.isCancelled else { return }
            stage = .failed(.bindingDidNotVerify)
            return
        }
        guard !Task.isCancelled, case .pairing = stage else { return }

        if case .failure(let refusal) = manager.apply(review, enrolmentID: current.enrolmentID) {
            stage = .failed(.notApplied(refusal.errorDescription ?? ""))
            return
        }
        // The vault pack, if the profile names one, as for any enrolment. It does not hold this up.
        Task { [manager] in await manager.completePendingPack() }

        let pairing = OfficePairingService(
            manager: manager, transportID: seams.phoneTransportID,
            phoneApplicationKey: seams.phoneApplicationKey, highWater: seams.highWater,
            approvedPeerStore: seams.approvedPeerStore, profileKeys: seams.profileKeys,
            licenceKey: seams.licenceKey, clock: seams.now)
        do {
            _ = try await pairing.approve(binding, reviewedOffice: office)
        } catch {
            stage = .failed(.bindingNotKept)
            return
        }
        // The office connection itself is started the way a binding file's is, from the saved
        // approval; the approval carries no office sync address to dial (see Plan FX).
        seams.modelDidChange()
        if manager.needsModelSetup, let model = manager.organizationModel {
            stage = .modelKey(model, organization: review.organizationName)
        } else {
            stage = .paired(review.organizationName)
        }
    }

    /// The key page's Save, as for any enrolment that names a model.
    func submitModelKey(_ key: String) -> String? {
        guard case .modelKey(let model, let organization) = stage else { return nil }
        if model.access == .key, let problem = model.keyProblem(key) { return problem }
        guard manager.completeModelSetup(apiKey: key) else { return "Couldn't save the key. Try again." }
        seams.modelDidChange()
        stage = .paired(organization)
        return nil
    }

    func deferModelKey() {
        guard case .modelKey(_, let organization) = stage else { return }
        stage = .paired(organization)
    }

    // MARK: - Leaving

    /// Cancel, or close a finished exchange. Nothing is sent to the office: its code simply goes
    /// unanswered and expires.
    func dismiss() {
        reset()
        stage = .idle
    }

    /// An approval the person cannot see is not an approval — the rule the other enrolment routes
    /// follow. Waiting carries on when the app comes back; the code's expiry still holds.
    func handleBackground() {
        if case .reviewing = stage { dismiss() }
    }

    private func reset() {
        work?.cancel()
        work = nil
        exchange = nil
    }

    private func currentEnrolment() -> OfficeCommissioningFlow.CurrentEnrolment {
        guard let profile = manager.profile else { return .none }
        return .init(isManaged: true, organizationID: profile.officeAuthority?.organizationID,
                     organizationName: profile.organizationName)
    }

    private func nowSeconds() -> Int64 { Int64(seams.now().timeIntervalSince1970) }
}
