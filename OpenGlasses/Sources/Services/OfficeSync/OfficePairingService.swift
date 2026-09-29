import Foundation

/// Last trust gate before a managed connection. Approval follows a person's comparison of the
/// desktop's displayed identity; a later connection rechecks it and opens no shared folder.
/// A future content-share caller must repeat the gate at the point of sharing.
@MainActor
final class OfficePairingService {
    struct ReviewedOffice: Sendable {
        let officeID: String
        let transportID: String
        let applicationPublicKey: Data
    }

    struct Approval: Sendable {
        let binding: OfficePeerBinding.Verified
        let highWater: OfficePeerHighWaterStore.Decision
    }

    enum Refusal: Error, Equatable {
        case noDesktopEnrolment
        case inactiveLease
        case missingLicence
        case noApprovedOffice
        case approvalSuperseded
        case changedDuringApproval
    }

    private let manager: OrgProfileManager
    private let currentLicence: () -> String?
    private let transportID: () async throws -> String
    private let phoneApplicationKey: () async throws -> Data
    private let highWater: OfficePeerHighWaterStore
    private let approvedPeerStore: OfficeApprovedPeerStore
    private let profileKeys: [String: String]
    private let licenceKey: String
    private let clock: () -> Date

    init(manager: OrgProfileManager? = nil,
         currentLicence: (() -> String?)? = nil,
         transportID: @escaping () async throws -> String = { try await OfficeTransportIdentity.shared.deviceID() },
         phoneApplicationKey: @escaping () async throws -> Data = { try await OfficePhoneIdentity.shared.publicKey() },
         highWater: OfficePeerHighWaterStore = .shared,
         approvedPeerStore: OfficeApprovedPeerStore = .shared,
         profileKeys: [String: String] = ProfileVerification.productionKeys,
         licenceKey: String = LicenseService.productionPublicKeyBase64,
         clock: @escaping () -> Date = Date.init) {
        self.manager = manager ?? .shared
        self.currentLicence = currentLicence ?? { LicenseService.shared.storedCode }
        self.transportID = transportID
        self.phoneApplicationKey = phoneApplicationKey
        self.highWater = highWater
        self.approvedPeerStore = approvedPeerStore
        self.profileKeys = profileKeys
        self.licenceKey = licenceKey
        self.clock = clock
    }

    func approve(_ signedBinding: Data, reviewedOffice: ReviewedOffice) async throws -> Approval {
        guard let record = manager.record, record.source == .office,
              let profile = manager.profile else { throw Refusal.noDesktopEnrolment }
        guard manager.evaluateLease()?.isInForce == true, !manager.contentLocked,
              record.revoked != true else { throw Refusal.inactiveLease }
        guard let code = licence(for: record, profile: profile) else { throw Refusal.missingLicence }
        let pair = try OfficeInlineEntitlement.verify(
            profileDocument: record.document, licenceCode: code,
            profileKeys: profileKeys, licenceKey: licenceKey, now: clock())

        // These two values are obtained from this phone, never from the office's signed payload.
        let actualTransportID = try await transportID()
        let actualApplicationKey = try await phoneApplicationKey()
        let prior = try await highWater.read(organizationID: pair.root.organizationID,
                                             enrolmentID: record.enrolmentId)
        let expected = OfficePeerBinding.ExpectedPeer(
            enrolmentID: record.enrolmentId,
            officeID: reviewedOffice.officeID,
            officeTransportID: reviewedOffice.transportID,
            officeApplicationKey: reviewedOffice.applicationPublicKey,
            phoneTransportID: actualTransportID,
            phoneApplicationKey: actualApplicationKey,
            minimumGeneration: prior?.generation ?? 1)
        let now = clock()
        let binding = try OfficePeerBinding.verify(
            signedBinding, root: pair.root, expected: expected,
            now: Int64(now.timeIntervalSince1970))
        try recheck(record: record, code: code, at: now)
        let decision = try await highWater.accept(binding)
        try recheck(record: record, code: code, at: clock())
        try await approvedPeerStore.save(
            signedBinding, organizationID: pair.root.organizationID,
            enrolmentID: record.enrolmentId, officeID: reviewedOffice.officeID,
            officeTransportID: reviewedOffice.transportID,
            officeApplicationKey: reviewedOffice.applicationPublicKey)
        try recheck(record: record, code: code, at: clock())
        return Approval(binding: binding, highWater: decision)
    }

    /// Re-evaluate the saved approval each time a connection is requested. Keychain storage is
    /// not proof of a current entitlement: the vendor and administrator signatures, live lease,
    /// actual phone keys and independent generation high-water all have to agree again.
    func currentApprovedPeer() async throws -> OfficePeerBinding.Verified {
        guard let record = manager.record, record.source == .office,
              let profile = manager.profile else { throw Refusal.noDesktopEnrolment }
        guard manager.evaluateLease()?.isInForce == true, !manager.contentLocked,
              record.revoked != true else { throw Refusal.inactiveLease }
        guard let code = licence(for: record, profile: profile) else { throw Refusal.missingLicence }
        let pair = try OfficeInlineEntitlement.verify(
            profileDocument: record.document, licenceCode: code,
            profileKeys: profileKeys, licenceKey: licenceKey, now: clock())
        guard let saved = try await approvedPeerStore.read(
            organizationID: pair.root.organizationID,
            enrolmentID: record.enrolmentId) else { throw Refusal.noApprovedOffice }
        guard let retained = try await highWater.read(
            organizationID: pair.root.organizationID,
            enrolmentID: record.enrolmentId) else { throw Refusal.approvalSuperseded }
        let actualTransportID = try await transportID()
        let actualApplicationKey = try await phoneApplicationKey()
        let expected = OfficePeerBinding.ExpectedPeer(
            enrolmentID: record.enrolmentId,
            officeID: saved.officeID,
            officeTransportID: saved.officeTransportID,
            officeApplicationKey: saved.officeApplicationKey,
            phoneTransportID: actualTransportID,
            phoneApplicationKey: actualApplicationKey,
            minimumGeneration: retained.generation)
        let now = clock()
        let binding = try OfficePeerBinding.verify(
            saved.signedBinding, root: pair.root, expected: expected,
            now: Int64(now.timeIntervalSince1970))
        guard binding.payload.generation == retained.generation,
              binding.payloadSHA256 == retained.payloadSHA256 else {
            throw Refusal.approvalSuperseded
        }
        try recheck(record: record, code: code, at: now)
        return binding
    }

    /// Open only the certificate-pinned LAN handshake. The engine has no managed folders, so
    /// a change during its async startup can be stopped before any content share exists.
    func connectToApprovedOffice(lanAddress: String) async throws {
        let before = try await currentApprovedPeer()
        try await OfficeTransportIdentity.shared.startManagedOffice(
            transportID: before.payload.officeTransportID, lanAddress: lanAddress)
        do {
            let after = try await currentApprovedPeer()
            guard after.payloadSHA256 == before.payloadSHA256 else {
                throw Refusal.approvalSuperseded
            }
        } catch {
            await OfficeTransportIdentity.shared.stop()
            throw error
        }
    }

    private func licence(for record: OrgEnrolmentRecord, profile: ConfigProfile) -> String? {
        record.activatedLicenceCode ?? profile.licenceCode ?? currentLicence()
    }

    private func recheck(record: OrgEnrolmentRecord, code: String, at now: Date) throws {
        guard let latest = manager.record, latest.source == .office,
              latest.enrolmentId == record.enrolmentId,
              latest.document == record.document,
              let profile = manager.profile,
              licence(for: latest, profile: profile) == code else { throw Refusal.changedDuringApproval }
        guard manager.evaluateLease()?.isInForce == true, !manager.contentLocked,
              latest.revoked != true else { throw Refusal.inactiveLease }
        _ = try OfficeInlineEntitlement.verify(
            profileDocument: latest.document, licenceCode: code,
            profileKeys: profileKeys, licenceKey: licenceKey, now: now)
    }
}
