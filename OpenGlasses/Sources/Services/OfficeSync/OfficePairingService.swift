import Foundation

/// Last trust gate before a managed connection. Approval follows a person's comparison of the
/// desktop's displayed identity; a later connection rechecks it. `connectToApprovedOffice` opens
/// no shared folder; `openFoldersWithApprovedOffice` opens the two managed folders, and is the
/// only place a binding is handed to the transport. `renew(withResult:waiting:)` is the only place
/// a binding replaces the saved one without a person, and `remove(withRemoval:)` the only place an
/// office ends an enrolment. Any further content-share caller must repeat the gate at the point
/// of sharing.
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

    /// The vendor-signed profile's routing policy (`officeAuthority.transportPolicy`), re-read
    /// from the verified profile on every connection. The binding and the office carry none.
    enum TransportPolicy: String, Sendable {
        /// The office's own network only; the saved LAN address is the only address dialled.
        case privateLan
        /// Direct when possible, else a community relay; the LAN address is tried first.
        case automatic
    }

    /// A saved approval that verified again just now, with how it may be reached.
    struct ApprovedOffice: Sendable {
        let binding: OfficePeerBinding.Verified
        let transportPolicy: TransportPolicy
        /// `tcp://a.b.c.d:port` on a private network, or nil. Unsigned: a shortcut, never trust.
        let lanHint: String?
        /// The administrator key the vendor-verified profile names: the key that signed the
        /// binding, and the only one a check-in result or a removal is accepted under.
        let administratorPublicKey: Data
    }

    enum Refusal: Error, Equatable {
        case noDesktopEnrolment
        case inactiveLease
        case missingLicence
        case noApprovedOffice
        case approvalSuperseded
        case changedDuringApproval
        /// The organisation connects on the office network only and no office address is saved.
        case noOfficeAddress
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
    private let startManagedOffice: (String, TransportPolicy, String) async throws -> Void
    private let stopManagedOffice: () async -> Void

    init(manager: OrgProfileManager? = nil,
         currentLicence: (() -> String?)? = nil,
         transportID: @escaping () async throws -> String = { try await OfficeTransportIdentity.shared.deviceID() },
         phoneApplicationKey: @escaping () async throws -> Data = { try await OfficePhoneIdentity.shared.publicKey() },
         highWater: OfficePeerHighWaterStore = .shared,
         approvedPeerStore: OfficeApprovedPeerStore = .shared,
         profileKeys: [String: String] = ProfileVerification.productionKeys,
         licenceKey: String = LicenseService.productionPublicKeyBase64,
         clock: @escaping () -> Date = Date.init,
         startManagedOffice: @escaping (String, TransportPolicy, String) async throws -> Void = {
             try await OfficeTransportIdentity.shared.startManagedOffice(transportID: $0, policy: $1, lanHint: $2)
         },
         stopManagedOffice: @escaping () async -> Void = { await OfficeTransportIdentity.shared.stop() }) {
        self.manager = manager ?? .shared
        self.currentLicence = currentLicence ?? { LicenseService.shared.storedCode }
        self.transportID = transportID
        self.phoneApplicationKey = phoneApplicationKey
        self.highWater = highWater
        self.approvedPeerStore = approvedPeerStore
        self.profileKeys = profileKeys
        self.licenceKey = licenceKey
        self.clock = clock
        self.startManagedOffice = startManagedOffice
        self.stopManagedOffice = stopManagedOffice
    }

    /// `lanHint` is the office's private-LAN address when one came with the approval, kept as a
    /// route shortcut. Anything that is not a private IPv4 `a.b.c.d:port` is not kept.
    func approve(_ signedBinding: Data, reviewedOffice: ReviewedOffice,
                 lanHint: String? = nil) async throws -> Approval {
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
            officeApplicationKey: reviewedOffice.applicationPublicKey,
            lanHint: lanHint.flatMap(OfficeApprovedPeerStore.lanHint))
        try recheck(record: record, code: code, at: clock())
        return Approval(binding: binding, highWater: decision)
    }

    /// Re-evaluate the saved approval each time a connection is requested. Keychain storage is
    /// not proof of a current entitlement: the vendor and administrator signatures, live lease,
    /// actual phone keys and independent generation high-water all have to agree again.
    func currentApprovedPeer() async throws -> ApprovedOffice {
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
        // `validOfficeAuthority` admits only these two, so an unknown value means a changed profile.
        guard let policy = TransportPolicy(rawValue: pair.root.transportPolicy) else {
            throw OfficePeerBinding.Refusal.untrustedProfile
        }
        return ApprovedOffice(binding: binding, transportPolicy: policy, lanHint: saved.lanHint,
                              administratorPublicKey: pair.root.administratorPublicKey)
    }

    /// Open only the certificate-pinned managed connection, under the policy in the verified
    /// profile. The engine has no managed folders, so a change during its async startup can be
    /// stopped before any content share exists. `lanHint` replaces the saved address for one
    /// connection test (the pairing sheet's typed address); it is not saved here.
    func connectToApprovedOffice(lanHint override: String? = nil) async throws {
        let before = try await currentApprovedPeer()
        var hint = before.lanHint
        if let override {
            guard let checked = OfficeApprovedPeerStore.lanHint(override) else { throw Refusal.noOfficeAddress }
            hint = checked
        }
        if before.transportPolicy == .privateLan, hint == nil { throw Refusal.noOfficeAddress }
        try await startManagedOffice(before.binding.payload.officeTransportID,
                                     before.transportPolicy, hint ?? "")
        do {
            let after = try await currentApprovedPeer()
            guard after.binding.payloadSHA256 == before.binding.payloadSHA256,
                  after.transportPolicy == before.transportPolicy else {
                throw Refusal.approvalSuperseded
            }
        } catch {
            await stopManagedOffice()
            throw error
        }
    }

    /// Open the managed connection with its `control` and `records` folders
    /// (Contracts/office-folders.md). The binding the transport is given comes only from
    /// `currentApprovedPeer()` at this moment: the profile, licence, lease, administrator
    /// signature, this phone's own keys and the generation high-water have all just agreed. The
    /// transport verifies none of that itself. The approval is checked again once the engine has
    /// started; if it no longer verifies, or is no longer the same one, the folders are closed.
    func openFoldersWithApprovedOffice(_ transport: any OfficeManagedFolderTransport) async throws {
        let before = try await currentApprovedPeer()
        if before.transportPolicy == .privateLan, before.lanHint == nil { throw Refusal.noOfficeAddress }
        try await transport.startFolders(bindingJSON: Self.managedBindingJSON(before),
                                         policy: before.transportPolicy.rawValue,
                                         lanHint: before.lanHint ?? "")
        do {
            let after = try await currentApprovedPeer()
            guard after.binding.payloadSHA256 == before.binding.payloadSHA256,
                  after.transportPolicy == before.transportPolicy else {
                throw Refusal.approvalSuperseded
            }
        } catch {
            await transport.stop()
            throw error
        }
    }

    /// The closed object the transport's managed folders take, from a binding verified just now.
    /// Private: no other value may be turned into one.
    private static func managedBindingJSON(_ office: ApprovedOffice) throws -> String {
        let p = office.binding.payload
        let fields: [String: Any] = [
            "organizationID": p.organizationID, "enrolmentID": p.enrolmentID, "officeID": p.officeID,
            "generation": NSNumber(value: p.generation), "officeTransportID": p.officeTransportID,
            "officeApplicationKey": p.officeApplicationKey, "phoneApplicationKey": p.phoneApplicationKey,
            // What check-in, renewal and removal are read against (Contracts/office-check-in.md).
            "profileID": p.profileID, "bindingSHA256": office.binding.payloadSHA256,
            "administratorKey": office.administratorPublicKey.base64EncodedString(),
        ]
        let data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Check-in, renewal and removal (Contracts/office-check-in.md)

    /// Take in the office's result for the one check-in this phone is waiting on (contract §7),
    /// in the contract's order and stopping at the first failure with nothing changed:
    ///
    /// 1. signed by the administrator key from the vendor-verified profile, and naming this
    ///    phone's organisation, enrolment, office and transport identity;
    /// 2. for exactly `waiting`: its challenge and the digest of the check-in as published;
    /// 3. carrying a binding that passes the binding verifier against this phone's own keys and
    ///    the office identities saved when a person approved the pairing, and is a renewal of the
    ///    binding the check-in named: the same identities and a higher generation;
    /// 4. with the profile, licence and lease in force, checked again;
    /// 5. then committed: the generation high-water mark, the saved binding, and last the lease,
    ///    from this phone's own clock.
    ///
    /// The binding held must still be inside its validity window and the lease in force: renewal
    /// is before the end. A crash between the steps of 5 is repaired by taking the same result in
    /// again while `waiting` is still kept: the same generation with the same digest is an exact
    /// repeat. The caller forgets `waiting` once this returns, so the same result later fits no
    /// check-in and renews nothing.
    @discardableResult
    func renew(withResult data: Data, waiting: OfficeCheckIn.Waiting) async throws -> Approval {
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
        func expected(minimumGeneration: Int64) -> OfficePeerBinding.ExpectedPeer {
            .init(enrolmentID: record.enrolmentId, officeID: saved.officeID,
                  officeTransportID: saved.officeTransportID,
                  officeApplicationKey: saved.officeApplicationKey,
                  phoneTransportID: actualTransportID, phoneApplicationKey: actualApplicationKey,
                  minimumGeneration: minimumGeneration)
        }
        let now = clock()
        let seconds = Int64(now.timeIntervalSince1970)

        let result = try OfficeCheckIn.result(
            data, administratorKey: pair.root.administratorPublicKey,
            organizationID: pair.root.organizationID, enrolmentID: record.enrolmentId,
            officeID: saved.officeID, phoneTransportID: actualTransportID, waiting: waiting)

        // The saved binding, still inside its window. After a crash in step 5 it may be the one
        // the high-water mark has already moved past, so it is not held to that mark here.
        let held = try OfficePeerBinding.verify(saved.signedBinding, root: pair.root,
                                                expected: expected(minimumGeneration: 1), now: seconds)
        guard held.payload.generation <= retained.generation else { throw Refusal.approvalSuperseded }
        // Both bindings verified against the same expected peer and profile, so every identity
        // is already the same; what is left of "a renewal" is the generation.
        let next = try OfficePeerBinding.verify(result.peerBinding, root: pair.root,
                                                expected: expected(minimumGeneration: retained.generation),
                                                now: seconds)
        if next.payloadSHA256 == held.payloadSHA256 {
            // Already saved: a crash before the lease step. An exact repeat, for a check-in that
            // named the binding before it.
            guard next.payloadSHA256 == retained.payloadSHA256,
                  waiting.generation < next.payload.generation else { throw OfficeCheckIn.Refusal.notARenewal }
        } else {
            guard waiting.generation == held.payload.generation,
                  waiting.bindingSHA256 == held.payloadSHA256,
                  next.payload.generation > held.payload.generation else {
                throw OfficeCheckIn.Refusal.notARenewal
            }
        }

        try recheck(record: record, code: code, at: now)
        // A second binding at the retained generation is refused here as a conflict; the exact
        // one is a repeat.
        let decision = try await highWater.accept(next)
        try recheck(record: record, code: code, at: clock())
        try await approvedPeerStore.save(
            result.peerBinding, organizationID: pair.root.organizationID,
            enrolmentID: record.enrolmentId, officeID: saved.officeID,
            officeTransportID: saved.officeTransportID,
            officeApplicationKey: saved.officeApplicationKey, lanHint: saved.lanHint)
        try recheck(record: record, code: code, at: clock())
        guard manager.renewLease(officeBinding: next) else { throw Refusal.changedDuringApproval }
        return Approval(binding: next, highWater: decision)
    }

    /// Take in an office's removal (contract §8): signed by the administrator key from the
    /// vendor-verified profile, and naming this phone's own organisation, profile, enrolment and
    /// transport identity. The enrolment is then revoked exactly as a signed revocation heard from
    /// a hosted profile revokes it. An exact repeat changes nothing. After this the gate above no
    /// longer passes, so no further managed connection opens for the enrolment.
    func remove(withRemoval data: Data) async throws -> OfficeCheckIn.VerifiedRemoval {
        guard let record = manager.record, record.source == .office,
              let profile = manager.profile else { throw Refusal.noDesktopEnrolment }
        guard let code = licence(for: record, profile: profile) else { throw Refusal.missingLicence }
        let pair = try OfficeInlineEntitlement.verify(
            profileDocument: record.document, licenceCode: code,
            profileKeys: profileKeys, licenceKey: licenceKey, now: clock())
        let actualTransportID = try await transportID()
        let removal = try OfficeCheckIn.removal(
            data, administratorKey: pair.root.administratorPublicKey,
            organizationID: pair.root.organizationID, profileID: pair.root.profileID,
            enrolmentID: record.enrolmentId, phoneTransportID: actualTransportID)
        guard let latest = manager.record, latest.source == .office,
              latest.enrolmentId == record.enrolmentId, latest.document == record.document,
              manager.revoke(officeRemoval: removal) else { throw Refusal.changedDuringApproval }
        return removal
    }

    /// Keep a LAN address that has just reached the office, for the next connection. Only on
    /// the approval that verifies now; a non-private address is refused.
    func rememberLanHint(_ hint: String) async throws {
        let current = try await currentApprovedPeer()
        // A verified binding names this phone's organisation and enrolment.
        try await approvedPeerStore.updateLanHint(hint, organizationID: current.binding.payload.organizationID,
                                                  enrolmentID: current.binding.payload.enrolmentID)
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

extension OfficeCheckIn.Held {
    /// The binding a check-in is made under: only from an approval that verified just now.
    init?(_ office: OfficePairingService.ApprovedOffice) {
        let p = office.binding.payload
        guard let officeKey = Data(base64Encoded: p.officeApplicationKey),
              let phoneKey = Data(base64Encoded: p.phoneApplicationKey) else { return nil }
        self.init(organizationID: p.organizationID, profileID: p.profileID, enrolmentID: p.enrolmentID,
                  officeID: p.officeID, phoneTransportID: p.phoneTransportID, generation: p.generation,
                  bindingSHA256: office.binding.payloadSHA256, officeApplicationKey: officeKey,
                  phoneApplicationKey: phoneKey, administratorKey: office.administratorPublicKey)
    }
}
