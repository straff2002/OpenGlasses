import CryptoKit
import Foundation
import XCTest
@testable import OpenGlasses

@MainActor
final class OfficePairingServiceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let vendor = Curve25519.Signing.PrivateKey()
    private let licensor = Curve25519.Signing.PrivateKey()
    private let administrator = Curve25519.Signing.PrivateKey()
    private let office = Curve25519.Signing.PrivateKey()
    private let phone = Curve25519.Signing.PrivateKey()
    private lazy var clock = CommissionTestClock(now)
    private var keychainItems: [String] = []

    override func tearDown() async throws {
        for item in keychainItems { try? KeychainService.deleteItem(item) }
    }

    /// A vendor-signed profile naming `administrator` as the organisation's administrator key.
    private func profileDocument(code: String, transportPolicy: String = "privateLan",
                                 administrator: Curve25519.Signing.PrivateKey? = nil) throws -> String {
        let profile = ConfigProfile(
            keyId: "vendor-test", profileId: "northbridge-field", organizationName: "Northbridge",
            issued: now.addingTimeInterval(-60), policyExpiry: now.addingTimeInterval(86_400),
            leaseDays: 30, licenceCode: code, officeAuthority: .init(
                organizationID: "northbridge",
                administratorPublicKey: (administrator ?? self.administrator).publicKey
                    .rawRepresentation.base64EncodedString(),
                transportPolicy: transportPolicy), schemaVersion: 2)
        return try ProfileVerification.makeDocument(profile,
            privateKeyBase64: vendor.rawRepresentation.base64EncodedString())
    }

    private func enrolledManager(transportPolicy: String = "privateLan") throws -> (OrgProfileManager, String, String) {
        let code = try LicenseService.makeCode(payload: .init(
            feature: "field_assist", licensee: "Northbridge", issued: now.addingTimeInterval(-60),
            expires: now.addingTimeInterval(86_400), organizationID: "northbridge",
            profileID: "northbridge-field"),
            privateKeyBase64: licensor.rawRepresentation.base64EncodedString())
        let document = try profileDocument(code: code, transportPolicy: transportPolicy)
        var seams = OrgProfileManager.Seams()
        seams.now = { [clock] in clock.now }
        seams.verificationKeys = ["vendor-test": vendor.publicKey.rawRepresentation.base64EncodedString()]
        seams.licenceKey = licensor.publicKey.rawRepresentation.base64EncodedString()
        seams.resolvableVaultIds = { [] }
        seams.saveRecord = { _ in }
        seams.activateLicence = { _ in }
        seams.installEnvelope = { _, _ in }
        seams.clearEnvelope = {}
        seams.withholdLicence = { _ in }
        seams.newEnrolmentId = { "phone-one" }
        let manager = OrgProfileManager(seams: seams)
        let review = try manager.review(document: document, source: .office, enteredLicence: code).get()
        try manager.apply(review).get()
        return (manager, code, document)
    }

    private func binding(phoneTransportID: String = "transport-phone-one", generation: Int64 = 1) throws -> Data {
        let payload = OfficePeerBinding.Payload(
            version: 1, kind: "avenkin.office-peer-binding", organizationID: "northbridge",
            profileID: "northbridge-field", enrolmentID: "phone-one", officeID: "office-one",
            generation: generation, officeTransportID: "transport-office-one",
            officeApplicationKey: office.publicKey.rawRepresentation.base64EncodedString(),
            phoneTransportID: phoneTransportID,
            phoneApplicationKey: phone.publicKey.rawRepresentation.base64EncodedString(),
            issuedAt: Int64(now.timeIntervalSince1970) - 60,
            expiresAt: Int64(now.timeIntervalSince1970) + 3_600)
        let bytes = try JSONEncoder().encode(payload)
        let signature = try administrator.signature(for: OfficePeerBinding.domain + bytes)
        return try JSONEncoder().encode(OfficePeerBinding.Envelope(
            payload: bytes.base64EncodedString(), signature: signature.base64EncodedString()))
    }

    func testLiveDesktopEnrolmentBindsActualPhoneAndReviewedOfficeBeforeHighWaterCommit() async throws {
        let (manager, code, _) = try enrolledManager()
        let prefix = "office.pairing.service.tests.\(UUID().uuidString)."
        let approvedPrefix = "office.pairing.approved.tests.\(UUID().uuidString)."
        let scope = try OfficePeerHighWaterStore.scopeID(organizationID: "northbridge", enrolmentID: "phone-one")
        defer {
            try? KeychainService.deleteItem(prefix + scope)
            try? KeychainService.deleteItem(approvedPrefix + scope)
        }
        let highWater = OfficePeerHighWaterStore(keyPrefix: prefix)
        let approvedStore = OfficeApprovedPeerStore(keyPrefix: approvedPrefix)
        let service = OfficePairingService(
            manager: manager, currentLicence: { code },
            transportID: { "transport-phone-one" },
            phoneApplicationKey: { self.phone.publicKey.rawRepresentation },
            highWater: highWater, approvedPeerStore: approvedStore,
            profileKeys: ["vendor-test": vendor.publicKey.rawRepresentation.base64EncodedString()],
            licenceKey: licensor.publicKey.rawRepresentation.base64EncodedString(), clock: { self.now })
        let reviewed = OfficePairingService.ReviewedOffice(
            officeID: "office-one", transportID: "transport-office-one",
            applicationPublicKey: office.publicKey.rawRepresentation)
        do {
            _ = try await service.currentApprovedPeer()
            XCTFail("a phone with no saved approval cannot connect")
        } catch {
            XCTAssertEqual(error as? OfficePairingService.Refusal, .noApprovedOffice)
        }
        let wrongPhone = try binding(phoneTransportID: "other-phone")
        do {
            _ = try await service.approve(wrongPhone, reviewedOffice: reviewed)
            XCTFail("a signed binding for another transport identity must be refused")
        } catch {
            XCTAssertEqual(error as? OfficePeerBinding.Refusal, .wrongPeer)
        }
        let before = try await highWater.read(organizationID: "northbridge", enrolmentID: "phone-one")
        XCTAssertNil(before)
        let accepted = try await service.approve(binding(), reviewedOffice: reviewed)
        XCTAssertEqual(accepted.binding.payload.phoneTransportID, "transport-phone-one")
        let retained = try await highWater.read(organizationID: "northbridge", enrolmentID: "phone-one")
        XCTAssertEqual(retained?.generation, 1)
        let reopened = try await service.currentApprovedPeer()
        XCTAssertEqual(reopened.binding.payload.officeID, "office-one")
        XCTAssertEqual(reopened.transportPolicy, .privateLan, "the policy is the vendor-signed profile's")
        XCTAssertNil(reopened.lanHint)
    }

    // MARK: - The managed connection

    private struct Started: Equatable {
        let transportID: String
        let policy: OfficePairingService.TransportPolicy
        let lanHint: String
    }

    private var started: [Started] = []
    private var stops = 0
    private var onStart: () -> Void = {}
    private var manager: OrgProfileManager?
    private var licenceCode = ""
    /// This phone's transport identity, as the engine reports it.
    private var phoneTransportID = "transport-phone-one"

    /// A phone enrolled under `transportPolicy`, its pairing service (whose engine calls are
    /// recorded) and the store the approval is kept in.
    private func pairedService(transportPolicy: String = "privateLan")
        throws -> (OfficePairingService, OfficeApprovedPeerStore) {
        let (manager, code, _) = try enrolledManager(transportPolicy: transportPolicy)
        self.manager = manager
        self.licenceCode = code
        let highWaterPrefix = "office.pairing.service.tests.\(UUID().uuidString)."
        let approvedPrefix = "office.pairing.approved.tests.\(UUID().uuidString)."
        let scope = try OfficePeerHighWaterStore.scopeID(organizationID: "northbridge", enrolmentID: "phone-one")
        keychainItems += [highWaterPrefix + scope, approvedPrefix + scope]
        let approvedStore = OfficeApprovedPeerStore(keyPrefix: approvedPrefix)
        let service = OfficePairingService(
            manager: manager, currentLicence: { code },
            transportID: { [unowned self] in self.phoneTransportID },
            phoneApplicationKey: { [phone] in phone.publicKey.rawRepresentation },
            highWater: OfficePeerHighWaterStore(keyPrefix: highWaterPrefix), approvedPeerStore: approvedStore,
            profileKeys: ["vendor-test": vendor.publicKey.rawRepresentation.base64EncodedString()],
            licenceKey: licensor.publicKey.rawRepresentation.base64EncodedString(),
            clock: { [clock] in clock.now },
            startManagedOffice: { [unowned self] id, policy, hint in
                self.started.append(Started(transportID: id, policy: policy, lanHint: hint))
                self.onStart()
            },
            stopManagedOffice: { [unowned self] in self.stops += 1 })
        return (service, approvedStore)
    }

    private var reviewed: OfficePairingService.ReviewedOffice {
        .init(officeID: "office-one", transportID: "transport-office-one",
              applicationPublicKey: office.publicKey.rawRepresentation)
    }

    func testTheApprovalsPrivateAddressIsKeptAndDialledUnderTheProfilesPolicy() async throws {
        let (service, _) = try pairedService()
        _ = try await service.approve(binding(), reviewedOffice: reviewed, lanHint: "192.168.1.24:22000")
        let approved = try await service.currentApprovedPeer()
        XCTAssertEqual(approved.lanHint, "tcp://192.168.1.24:22000")
        try await service.connectToApprovedOffice()
        XCTAssertEqual(started, [Started(transportID: "transport-office-one", policy: .privateLan,
                                         lanHint: "tcp://192.168.1.24:22000")])
        XCTAssertEqual(stops, 0)
    }

    func testOfficeNetworkOnlyWithNoAddressNeverStarts() async throws {
        let (service, _) = try pairedService()
        _ = try await service.approve(binding(), reviewedOffice: reviewed)
        do {
            try await service.connectToApprovedOffice()
            XCTFail("an office-network-only organisation needs the office's address")
        } catch {
            XCTAssertEqual(error as? OfficePairingService.Refusal, .noOfficeAddress)
        }
        XCTAssertEqual(started, [])
    }

    func testFromAnywhereStartsWithOrWithoutTheAddress() async throws {
        let (service, store) = try pairedService(transportPolicy: "automatic")
        _ = try await service.approve(binding(), reviewedOffice: reviewed)
        try await service.connectToApprovedOffice()
        try await service.rememberLanHint("10.1.2.3:22000")
        let saved = try await store.read(organizationID: "northbridge", enrolmentID: "phone-one")
        XCTAssertEqual(saved?.lanHint, "tcp://10.1.2.3:22000")
        try await service.connectToApprovedOffice()
        XCTAssertEqual(started, [
            Started(transportID: "transport-office-one", policy: .automatic, lanHint: ""),
            Started(transportID: "transport-office-one", policy: .automatic, lanHint: "tcp://10.1.2.3:22000"),
        ])
    }

    func testAnAddressOffThePrivateNetworkIsNeverKeptOrDialled() async throws {
        let (service, store) = try pairedService(transportPolicy: "automatic")
        _ = try await service.approve(binding(), reviewedOffice: reviewed, lanHint: "8.8.8.8:22000")
        let saved = try await store.read(organizationID: "northbridge", enrolmentID: "phone-one")
        XCTAssertNotNil(saved)
        XCTAssertNil(saved?.lanHint)
        do {
            try await service.rememberLanHint("tcp://8.8.8.8:22000")
            XCTFail("a public address is not kept")
        } catch {
            XCTAssertEqual(error as? OfficeApprovedPeerStore.Refusal, .corruptState)
        }
        do {
            try await service.connectToApprovedOffice(lanHint: "office.example.com:22000")
            XCTFail("a typed address that is not private is not dialled")
        } catch {
            XCTAssertEqual(error as? OfficePairingService.Refusal, .noOfficeAddress)
        }
        XCTAssertEqual(started, [])
    }

    func testATypedAddressIsTriedOnceAndKeptOnlyWhenRemembered() async throws {
        let (service, store) = try pairedService()
        _ = try await service.approve(binding(), reviewedOffice: reviewed, lanHint: "192.168.1.24:22000")
        try await service.connectToApprovedOffice(lanHint: "tcp://192.168.7.9:22000")
        XCTAssertEqual(started.last?.lanHint, "tcp://192.168.7.9:22000")
        var saved = try await store.read(organizationID: "northbridge", enrolmentID: "phone-one")
        XCTAssertEqual(saved?.lanHint, "tcp://192.168.1.24:22000", "a test alone changes nothing saved")
        try await service.rememberLanHint("tcp://192.168.7.9:22000")
        saved = try await store.read(organizationID: "northbridge", enrolmentID: "phone-one")
        XCTAssertEqual(saved?.lanHint, "tcp://192.168.7.9:22000")
    }

    func testAPairingThatExpiresWhileStartingIsStoppedAgain() async throws {
        let (service, _) = try pairedService()
        _ = try await service.approve(binding(), reviewedOffice: reviewed, lanHint: "192.168.1.24:22000")
        // The binding is valid for an hour: it lapses while the engine starts.
        onStart = { [clock] in clock.now = clock.now.addingTimeInterval(3_600) }
        do {
            try await service.connectToApprovedOffice()
            XCTFail("the approval is checked again after the engine starts")
        } catch {
            XCTAssertEqual(error as? OfficePeerBinding.Refusal, .notCurrentlyValid)
        }
        XCTAssertEqual(started.count, 1)
        XCTAssertEqual(stops, 1, "the engine is stopped when the approval no longer verifies")
        XCTAssertEqual(OfficeFieldConnectionPolicy.afterFailure(OfficePeerBinding.Refusal.notCurrentlyValid),
                       .stop(.pairingExpired))
    }

    // MARK: - The managed folders

    private let folders = OfficeManagedFolderMemoryTransport()

    private func assertFoldersStayClosed(_ service: OfficePairingService, line: UInt = #line,
                                         _ expected: (Error) -> Bool) async {
        do {
            try await service.openFoldersWithApprovedOffice(folders)
            XCTFail("the folders opened", line: line)
        } catch {
            XCTAssertTrue(expected(error), "\(error)", line: line)
        }
        let starts = await folders.starts
        let open = await folders.isOpen
        XCTAssertEqual(starts, [], "the transport was never handed a binding", line: line)
        XCTAssertFalse(open, line: line)
    }

    func testTheFoldersOpenWithTheBindingVerifiedAtThatMoment() async throws {
        let (service, _) = try pairedService()
        _ = try await service.approve(binding(), reviewedOffice: reviewed, lanHint: "192.168.1.24:22000")
        try await service.openFoldersWithApprovedOffice(folders)
        let starts = await folders.starts
        XCTAssertEqual(starts.count, 1)
        XCTAssertEqual(starts.first?.policy, "privateLan")
        XCTAssertEqual(starts.first?.lanHint, "tcp://192.168.1.24:22000")
        // Exactly the closed object the transport takes, from the verified binding and nothing else.
        let handed = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(XCTUnwrap(starts.first?.bindingJSON).utf8)) as? [String: Any])
        XCTAssertEqual(Set(handed.keys), OfficeManagedFolderMemoryTransport.bindingFields)
        XCTAssertEqual(handed["organizationID"] as? String, "northbridge")
        XCTAssertEqual(handed["enrolmentID"] as? String, "phone-one")
        XCTAssertEqual(handed["officeID"] as? String, "office-one")
        XCTAssertEqual(handed["generation"] as? Int, 1)
        XCTAssertEqual(handed["officeTransportID"] as? String, "transport-office-one")
        XCTAssertEqual(handed["officeApplicationKey"] as? String,
                       office.publicKey.rawRepresentation.base64EncodedString())
        XCTAssertEqual(handed["phoneApplicationKey"] as? String,
                       phone.publicKey.rawRepresentation.base64EncodedString())
        let open = await folders.isOpen
        let stops = await folders.stops
        XCTAssertTrue(open)
        XCTAssertEqual(stops, 0)
        XCTAssertEqual(started, [], "the handshake-only connection is a different call")
    }

    func testAnUnpairedPhoneOrOneWithNoOfficeAddressOpensNoFolder() async throws {
        let (service, _) = try pairedService()
        await assertFoldersStayClosed(service) { $0 as? OfficePairingService.Refusal == .noApprovedOffice }
        _ = try await service.approve(binding(), reviewedOffice: reviewed)
        await assertFoldersStayClosed(service) { $0 as? OfficePairingService.Refusal == .noOfficeAddress }
    }

    func testAForeignBindingLeavesTheFoldersClosed() async throws {
        let (service, store) = try pairedService(transportPolicy: "automatic")
        _ = try await service.approve(binding(), reviewedOffice: reviewed)
        // The saved approval is replaced by a correctly signed binding for another phone.
        try await store.save(binding(phoneTransportID: "transport-phone-two"), organizationID: "northbridge",
                             enrolmentID: "phone-one", officeID: "office-one",
                             officeTransportID: "transport-office-one",
                             officeApplicationKey: office.publicKey.rawRepresentation)
        await assertFoldersStayClosed(service) { $0 as? OfficePeerBinding.Refusal == .wrongPeer }

        // And one for this phone that is not the generation this phone accepted.
        try await store.save(binding(generation: 2), organizationID: "northbridge",
                             enrolmentID: "phone-one", officeID: "office-one",
                             officeTransportID: "transport-office-one",
                             officeApplicationKey: office.publicKey.rawRepresentation)
        await assertFoldersStayClosed(service) { $0 as? OfficePairingService.Refusal == .approvalSuperseded }
    }

    func testAPhoneWhoseOwnIdentityChangedLeavesTheFoldersClosed() async throws {
        let (service, _) = try pairedService(transportPolicy: "automatic")
        _ = try await service.approve(binding(), reviewedOffice: reviewed)
        phoneTransportID = "transport-phone-restored-elsewhere"
        await assertFoldersStayClosed(service) { $0 as? OfficePeerBinding.Refusal == .wrongPeer }
    }

    func testALapsedLeaseLeavesTheFoldersClosed() async throws {
        let (service, _) = try pairedService(transportPolicy: "automatic")
        _ = try await service.approve(binding(), reviewedOffice: reviewed)
        // Past the 30-day management period, with no renewal.
        clock.now = now.addingTimeInterval(31 * 86_400)
        await assertFoldersStayClosed(service) { $0 as? OfficePairingService.Refusal == .inactiveLease }
        XCTAssertEqual(OfficeFieldConnectionPolicy.afterFailure(OfficePairingService.Refusal.inactiveLease),
                       .stop(.managementLapsed))
    }

    func testAChangedProfileLeavesTheFoldersClosed() async throws {
        let (service, _) = try pairedService(transportPolicy: "automatic")
        _ = try await service.approve(binding(), reviewedOffice: reviewed)
        // The organisation's profile is replaced by one naming another administrator key.
        let manager = try XCTUnwrap(self.manager)
        let replacement = try profileDocument(code: licenceCode, transportPolicy: "automatic",
                                              administrator: Curve25519.Signing.PrivateKey())
        let review = try manager.review(document: replacement, source: .office, enteredLicence: licenceCode).get()
        try manager.apply(review).get()
        await assertFoldersStayClosed(service) { $0 as? OfficePeerBinding.Refusal == .badSignature }
    }

    func testAnApprovalThatStopsVerifyingWhileTheFoldersStartClosesThem() async throws {
        let (service, _) = try pairedService(transportPolicy: "automatic")
        _ = try await service.approve(binding(), reviewedOffice: reviewed)
        // The binding is valid for an hour: it lapses while the engine starts.
        await folders.whenStarting { [clock] in clock.now = clock.now.addingTimeInterval(3_600) }
        do {
            try await service.openFoldersWithApprovedOffice(folders)
            XCTFail("the approval is checked again after the folders start")
        } catch {
            XCTAssertEqual(error as? OfficePeerBinding.Refusal, .notCurrentlyValid)
        }
        let starts = await folders.starts
        let stops = await folders.stops
        let open = await folders.isOpen
        XCTAssertEqual(starts.count, 1)
        XCTAssertEqual(stops, 1)
        XCTAssertFalse(open, "the folders are closed when the approval no longer verifies")
    }

    func testAProfileChangedWhileTheFoldersStartClosesThem() async throws {
        let (service, _) = try pairedService(transportPolicy: "automatic")
        _ = try await service.approve(binding(), reviewedOffice: reviewed)
        let manager = try XCTUnwrap(self.manager)
        let replacement = try profileDocument(code: licenceCode, transportPolicy: "automatic",
                                              administrator: Curve25519.Signing.PrivateKey())
        await folders.whenStarting { @MainActor in
            if let review = try? manager.review(document: replacement, source: .office,
                                                enteredLicence: self.licenceCode).get() {
                try? manager.apply(review).get()
            }
        }
        do {
            try await service.openFoldersWithApprovedOffice(folders)
            XCTFail("the approval is checked again after the folders start")
        } catch {
            XCTAssertEqual(error as? OfficePeerBinding.Refusal, .badSignature)
        }
        let open = await folders.isOpen
        XCTAssertFalse(open)
    }

    // MARK: - The saved route hint

    func testARecordSavedBeforeTheAddressExistedReadsWithNone() async throws {
        let prefix = "office.pairing.approved.tests.\(UUID().uuidString)."
        let scope = try OfficePeerHighWaterStore.scopeID(organizationID: "northbridge", enrolmentID: "phone-one")
        keychainItems.append(prefix + scope)
        struct Earlier: Encodable {
            let version: Int, scopeID: String, officeID: String, officeTransportID: String
            let officeApplicationKey: Data, signedBinding: Data
        }
        let earlier = Earlier(version: 1, scopeID: scope, officeID: "office-one",
                              officeTransportID: "transport-office-one",
                              officeApplicationKey: office.publicKey.rawRepresentation, signedBinding: try binding())
        try KeychainService.upsertDataAtomically(JSONEncoder().encode(earlier), for: prefix + scope,
                                                 accessibility: .afterFirstUnlockThisDeviceOnly)
        let store = OfficeApprovedPeerStore(keyPrefix: prefix)
        let read = try await store.read(organizationID: "northbridge", enrolmentID: "phone-one")
        XCTAssertEqual(read?.officeID, "office-one")
        XCTAssertNil(read?.lanHint)
    }

    func testASavedAddressThatIsNotPrivateIsRefusedOnRead() async throws {
        let prefix = "office.pairing.approved.tests.\(UUID().uuidString)."
        let scope = try OfficePeerHighWaterStore.scopeID(organizationID: "northbridge", enrolmentID: "phone-one")
        keychainItems.append(prefix + scope)
        let record = OfficeApprovedPeerStore.Stored(
            version: 1, scopeID: scope, officeID: "office-one", officeTransportID: "transport-office-one",
            officeApplicationKey: office.publicKey.rawRepresentation, signedBinding: try binding(),
            lanHint: "tcp://8.8.8.8:22000")
        try KeychainService.upsertDataAtomically(JSONEncoder().encode(record), for: prefix + scope,
                                                 accessibility: .afterFirstUnlockThisDeviceOnly)
        let store = OfficeApprovedPeerStore(keyPrefix: prefix)
        do {
            _ = try await store.read(organizationID: "northbridge", enrolmentID: "phone-one")
            XCTFail("only a private address is ever saved")
        } catch {
            XCTAssertEqual(error as? OfficeApprovedPeerStore.Refusal, .corruptState)
        }
        XCTAssertEqual(OfficeApprovedPeerStore.lanHint("192.168.1.24:22000"), "tcp://192.168.1.24:22000")
        XCTAssertEqual(OfficeApprovedPeerStore.lanHint("tcp://10.0.0.1:22000"), "tcp://10.0.0.1:22000")
        XCTAssertNil(OfficeApprovedPeerStore.lanHint("quic://10.0.0.1:22000"))
        XCTAssertNil(OfficeApprovedPeerStore.lanHint("tcp://172.32.0.1:22000"))
    }
}
