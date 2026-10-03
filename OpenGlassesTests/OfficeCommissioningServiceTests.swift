import Combine
import CryptoKit
import Foundation
import XCTest
@testable import OpenGlasses

/// Joining an office by its code, driven end to end against a fake transport: the phone's own
/// identities and enrolment in the redemption, the comparison code while the office decides, the
/// office's answers, and — on approval — the existing verifiers, review and pairing gate.
@MainActor
final class OfficeCommissioningServiceTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let vendor = Curve25519.Signing.PrivateKey()
    private let licensor = Curve25519.Signing.PrivateKey()
    private let administrator = Curve25519.Signing.PrivateKey()
    private let office = Curve25519.Signing.PrivateKey()
    private let phoneTransportID = "transport-phone-one"
    private let officeTransportID = "transport-office-one"
    private let officeID = "office-one"

    private var clock: CommissionTestClock!
    private var keychainItems: [String] = []
    private var phoneAccount = ""
    private var highWater: OfficePeerHighWaterStore!
    private var approvedStore: OfficeApprovedPeerStore!
    private var highWaterPrefix = ""
    private var approvedPrefix = ""

    override func setUp() async throws {
        clock = CommissionTestClock(start)
        phoneAccount = "office.commissioning.tests.phone.\(UUID().uuidString)"
        highWaterPrefix = "office.commissioning.tests.highwater.\(UUID().uuidString)."
        approvedPrefix = "office.commissioning.tests.approved.\(UUID().uuidString)."
        highWater = OfficePeerHighWaterStore(keyPrefix: highWaterPrefix)
        approvedStore = OfficeApprovedPeerStore(keyPrefix: approvedPrefix)
        keychainItems = [phoneAccount]
    }

    override func tearDown() async throws {
        for organization in ["northbridge", "other-org"] {
            if let scope = try? OfficePeerHighWaterStore.scopeID(organizationID: organization, enrolmentID: "phone-one") {
                keychainItems += [highWaterPrefix + scope, approvedPrefix + scope]
            }
        }
        for item in keychainItems { try? KeychainService.deleteItem(item) }
    }

    // MARK: - Fixtures for this test

    private var phone: OfficePhoneIdentity { OfficePhoneIdentity(account: phoneAccount) }

    private func licence(organization: String, profile: String) throws -> String {
        try LicenseService.makeCode(payload: .init(
            feature: "field_assist", licensee: organization == "northbridge" ? "Northbridge" : "Other Org",
            issued: start.addingTimeInterval(-60), expires: start.addingTimeInterval(86_400),
            organizationID: organization, profileID: profile),
            privateKeyBase64: licensor.rawRepresentation.base64EncodedString())
    }

    private func profileDocument(organization: String = "northbridge", name: String = "Northbridge",
                                 profile: String = "northbridge-field") throws -> (document: String, licence: String) {
        let code = try licence(organization: organization, profile: profile)
        let config = ConfigProfile(
            keyId: "vendor-test", profileId: profile, organizationName: name,
            issued: start.addingTimeInterval(-60), policyExpiry: start.addingTimeInterval(86_400),
            leaseDays: 30, licenceCode: code, officeAuthority: .init(
                organizationID: organization,
                administratorPublicKey: administrator.publicKey.rawRepresentation.base64EncodedString(),
                transportPolicy: "privateLan"), schemaVersion: 2)
        let document = try ProfileVerification.makeDocument(
            config, privateKeyBase64: vendor.rawRepresentation.base64EncodedString())
        return (document, code)
    }

    private var vendorKeys: [String: String] {
        ["vendor-test": vendor.publicKey.rawRepresentation.base64EncodedString()]
    }

    private func makeManager() -> OrgProfileManager {
        var seams = OrgProfileManager.Seams()
        seams.now = { [clock] in clock!.now }
        seams.verificationKeys = vendorKeys
        seams.licenceKey = licensor.publicKey.rawRepresentation.base64EncodedString()
        seams.resolvableVaultIds = { [] }
        var record: OrgEnrolmentRecord?
        seams.loadRecord = { record }
        seams.saveRecord = { record = $0 }
        seams.readSetting = { _ in nil }
        seams.writeSetting = { _, _ in }
        seams.activateLicence = { _ in }
        seams.storedLicenceCode = { nil }
        seams.clearLicence = {}
        seams.installEnvelope = { _, _ in }
        seams.clearEnvelope = {}
        seams.withholdLicence = { _ in }
        seams.activeJobId = { nil }
        var issued = 0
        seams.newEnrolmentId = {
            issued += 1
            return issued == 1 ? "phone-one" : "phone-\(issued)"
        }
        return OrgProfileManager(seams: seams)
    }

    private func invitationJSON(organization: String = "northbridge") -> String {
        let expiresAt = Int64(start.timeIntervalSince1970) + 900
        return """
        {"invitationEnvelope":"{\\"payload\\":\\"aW52aXRhdGlvbg==\\",\\"signature\\":\\"c2ln\\"}",
         "invitationSHA256":"\(String(repeating: "0", count: 64))","organizationID":"\(organization)",
         "officeID":"\(officeID)","officeApplicationKey":"\(office.publicKey.rawRepresentation.base64EncodedString())",
         "officeTransportID":"\(officeTransportID)","address":"192.168.1.24:22443",
         "issuedAt":\(Int64(start.timeIntervalSince1970)),"expiresAt":\(expiresAt)}
        """
    }

    private func binding(enrolmentID: String = "phone-one", phoneTransport: String? = nil,
                         phoneKey: Data) throws -> String {
        let payload = OfficePeerBinding.Payload(
            version: 1, kind: "avenkin.office-peer-binding", organizationID: "northbridge",
            profileID: "northbridge-field", enrolmentID: enrolmentID, officeID: officeID,
            generation: 1, officeTransportID: officeTransportID,
            officeApplicationKey: office.publicKey.rawRepresentation.base64EncodedString(),
            phoneTransportID: phoneTransport ?? phoneTransportID,
            phoneApplicationKey: phoneKey.base64EncodedString(),
            issuedAt: Int64(start.timeIntervalSince1970) - 60,
            expiresAt: Int64(start.timeIntervalSince1970) + 3_600)
        let bytes = try JSONEncoder().encode(payload)
        let signature = try administrator.signature(for: OfficePeerBinding.domain + bytes)
        return String(decoding: try JSONEncoder().encode(OfficePeerBinding.Envelope(
            payload: bytes.base64EncodedString(), signature: signature.base64EncodedString())), as: UTF8.self)
    }

    private func approval(enrolmentID: String = "phone-one", setup: (document: String, licence: String),
                          binding: String, officeAddress: String = "192.168.1.24:22000") throws -> String {
        let json = try JSONSerialization.data(withJSONObject: [
            "status": "approved", "enrolmentID": enrolmentID, "profileDocument": setup.document,
            "licenceCode": setup.licence, "peerBinding": binding, "decisionEnvelope": "{}",
            "officeAddress": officeAddress,
        ])
        return String(decoding: json, as: UTF8.self)
    }

    /// The addresses the managed connection was asked to dial, and whether it fails.
    private var dialled: [String] = []
    private var connectionFails = false

    private func makeService(manager: OrgProfileManager, transport: FakeCommissionTransport?,
                             pause: ((UInt64) async throws -> Void)? = nil) -> OfficeCommissioningService {
        var seams = OfficeCommissioningService.Seams()
        seams.transport = { transport }
        seams.phoneTransportID = { [phoneTransportID] in phoneTransportID }
        let identity = phone
        seams.phoneApplicationKey = { try await identity.publicKey() }
        seams.signRedemption = { try await identity.signCommissionRedemption($0) }
        seams.highWater = highWater
        seams.approvedPeerStore = approvedStore
        seams.profileKeys = vendorKeys
        seams.licenceKey = licensor.publicKey.rawRepresentation.base64EncodedString()
        seams.now = { [clock] in clock!.now }
        seams.pause = pause ?? { _ in await Task.yield() }
        seams.appVersion = "1.0.0"
        seams.appBuild = "100"
        seams.connectOffice = { [unowned self] pairing, address in
            // The saved approval must already verify when the connection is asked for.
            _ = try await pairing.currentApprovedPeer()
            self.dialled.append(address)
            if self.connectionFails { throw FakeCommissionTransport.Failure.network }
        }
        return OfficeCommissioningService(manager: manager, seams: seams)
    }

    private let qr = "avenkin-commission:fake"

    // MARK: - Approval

    func testApprovalIsReviewedThenAppliedUnderTheChosenEnrolmentAndTheBindingKept() async throws {
        let manager = makeManager()
        let phoneKey = try await phone.publicKey()
        let setup = try profileDocument()
        let transport = FakeCommissionTransport(invitation: invitationJSON(), answers: [
            .success(#"{"status":"awaiting"}"#),
            .success(try approval(setup: setup, binding: binding(phoneKey: phoneKey))),
        ])
        let service = makeService(manager: manager, transport: transport)
        var seen: [OfficeCommissioningService.Stage] = []
        let watch = service.$stage.sink { seen.append($0) }
        defer { watch.cancel() }

        service.start(qrText: qr)
        await waitForStage(service) { if case .reviewing = $0 { return true }; return false }

        // The redemption carried this phone's own values, chosen before anything arrived.
        let requests = await transport.signingRequests
        XCTAssertEqual(requests, [.init(enrolmentID: "phone-one", phoneTransportID: phoneTransportID,
                                        phoneApplicationKey: phoneKey.base64EncodedString(),
                                        existingEnrolment: "")])
        let sealed = await transport.sealedRedemptions
        XCTAssertEqual(sealed.count, 1)
        let code = CommissionFixtures.comparison(invitationSHA256: CommissionFixtures.digest(
            try OfficeCommissioning.decodeInvitation(invitationJSON()).invitationEnvelope),
            redemptionSHA256: CommissionFixtures.digest(sealed[0]))
        XCTAssertTrue(seen.contains(.waiting(code: code)), "the comparison code is shown while the office decides")
        // Reviewing: nothing is applied or kept yet.
        XCTAssertNil(manager.record)
        let keptBefore = try await highWater.read(organizationID: "northbridge", enrolmentID: "phone-one")
        XCTAssertNil(keptBefore)

        service.confirm()
        await waitForStage(service) { $0 == .paired("Northbridge", officeConnected: true) }
        XCTAssertEqual(dialled, ["tcp://192.168.1.24:22000"], "the approval's address, in the engine's form")
        XCTAssertEqual(manager.record?.enrolmentId, "phone-one")
        XCTAssertEqual(manager.record?.source, .office)
        let kept = try await highWater.read(organizationID: "northbridge", enrolmentID: "phone-one")
        XCTAssertEqual(kept?.generation, 1)
        let approved = try await approvedStore.read(organizationID: "northbridge", enrolmentID: "phone-one")
        XCTAssertEqual(approved?.officeID, officeID)
        XCTAssertEqual(approved?.officeTransportID, officeTransportID)
    }

    func testDecliningTheReviewAppliesNothing() async throws {
        let manager = makeManager()
        let phoneKey = try await phone.publicKey()
        let transport = FakeCommissionTransport(invitation: invitationJSON(), answers: [
            .success(try approval(setup: profileDocument(), binding: binding(phoneKey: phoneKey))),
        ])
        let service = makeService(manager: manager, transport: transport)
        service.start(qrText: qr)
        await waitForStage(service) { if case .reviewing = $0 { return true }; return false }
        service.dismiss()
        XCTAssertEqual(service.stage, .idle)
        XCTAssertNil(manager.record)
        let kept = try await highWater.read(organizationID: "northbridge", enrolmentID: "phone-one")
        XCTAssertNil(kept)
    }

    func testAReviewLeftInTheBackgroundIsNotAnApproval() async throws {
        let manager = makeManager()
        let phoneKey = try await phone.publicKey()
        let transport = FakeCommissionTransport(invitation: invitationJSON(), answers: [
            .success(try approval(setup: profileDocument(), binding: binding(phoneKey: phoneKey))),
        ])
        let service = makeService(manager: manager, transport: transport)
        service.start(qrText: qr)
        await waitForStage(service) { if case .reviewing = $0 { return true }; return false }
        service.handleBackground()
        XCTAssertEqual(service.stage, .idle)
        XCTAssertNil(manager.record)
    }

    func testABindingForAnotherPhoneAppliesNothing() async throws {
        let manager = makeManager()
        let phoneKey = try await phone.publicKey()
        let transport = FakeCommissionTransport(invitation: invitationJSON(), answers: [
            .success(try approval(setup: profileDocument(),
                                  binding: binding(phoneTransport: "another-phone", phoneKey: phoneKey))),
        ])
        let service = makeService(manager: manager, transport: transport)
        service.start(qrText: qr)
        await waitForStage(service) { if case .reviewing = $0 { return true }; return false }
        service.confirm()
        await waitForStage(service) { $0 == .failed(.bindingDidNotVerify) }
        XCTAssertNil(manager.record, "the binding is checked before the profile is applied")
    }

    func testABindingNotSignedByTheProfilesAdministratorAppliesNothing() async throws {
        let manager = makeManager()
        let phoneKey = try await phone.publicKey()
        let forged = try binding(phoneKey: phoneKey)
            .replacingOccurrences(of: #""signature":""#, with: #""signature":"AA"#)
        let transport = FakeCommissionTransport(invitation: invitationJSON(), answers: [
            .success(try approval(setup: profileDocument(), binding: forged)),
        ])
        let service = makeService(manager: manager, transport: transport)
        service.start(qrText: qr)
        await waitForStage(service) { if case .reviewing = $0 { return true }; return false }
        service.confirm()
        await waitForStage(service) { $0 == .failed(.bindingDidNotVerify) }
        XCTAssertNil(manager.record)
    }

    func testAnApprovalNamingAnotherEnrolmentIsRefused() async throws {
        let manager = makeManager()
        let phoneKey = try await phone.publicKey()
        let transport = FakeCommissionTransport(invitation: invitationJSON(), answers: [
            .success(try approval(enrolmentID: "someone-else", setup: profileDocument(),
                                  binding: binding(enrolmentID: "someone-else", phoneKey: phoneKey))),
        ])
        let service = makeService(manager: manager, transport: transport)
        service.start(qrText: qr)
        await waitForStage(service) { $0 == .failed(.approvalForAnotherPhone) }
        XCTAssertNil(manager.record)
    }

    func testASetupForAnotherOrganisationThanTheCodeNamedIsRefused() async throws {
        let manager = makeManager()
        let phoneKey = try await phone.publicKey()
        let other = try profileDocument(organization: "other-org", name: "Other Org", profile: "other-field")
        let transport = FakeCommissionTransport(invitation: invitationJSON(), answers: [
            .success(try approval(setup: other, binding: binding(phoneKey: phoneKey))),
        ])
        let service = makeService(manager: manager, transport: transport)
        service.start(qrText: qr)
        await waitForStage(service) { $0 == .failed(.otherOrganisationsSetup) }
        XCTAssertNil(manager.record)
    }

    func testASetupThatFailsVerificationIsNotReviewed() async throws {
        let manager = makeManager()
        let phoneKey = try await phone.publicKey()
        let setup = try profileDocument()
        let otherLicence = try licence(organization: "other-org", profile: "other-field")
        let transport = FakeCommissionTransport(invitation: invitationJSON(), answers: [
            .success(try approval(setup: (setup.document, otherLicence), binding: binding(phoneKey: phoneKey))),
        ])
        let service = makeService(manager: manager, transport: transport)
        service.start(qrText: qr)
        await waitForStage(service) { if case .failed(.setupDidNotVerify) = $0 { return true }; return false }
        XCTAssertNil(manager.record)
    }

    // MARK: - Refusals and the network

    func testEachRefusalEndsTheExchange() async throws {
        for reason in OfficeCommissioning.RefusalReason.allCases {
            let transport = FakeCommissionTransport(invitation: invitationJSON(), answers: [
                .success(#"{"status":"refused","reason":"\#(reason.rawValue)"}"#),
            ])
            let service = makeService(manager: makeManager(), transport: transport)
            service.start(qrText: qr)
            await waitForStage(service) { $0 == .refused(reason) }
        }
    }

    func testRetryAfterANetworkFailureSendsTheSameRedemption() async throws {
        let manager = makeManager()
        let phoneKey = try await phone.publicKey()
        let transport = FakeCommissionTransport(invitation: invitationJSON(), answers: [
            .success(#"{"status":"awaiting"}"#),
            .failure(FakeCommissionTransport.Failure.network),
            .failure(FakeCommissionTransport.Failure.network),
            .failure(FakeCommissionTransport.Failure.network),
        ])
        let service = makeService(manager: manager, transport: transport)
        service.start(qrText: qr)
        await waitForStage(service) { $0 == .networkFailure }

        await transport.queue([.success(#"{"status":"awaiting"}"#),
                               .success(try approval(setup: profileDocument(), binding: binding(phoneKey: phoneKey)))])
        service.retry()
        await waitForStage(service) { if case .reviewing = $0 { return true }; return false }

        let signed = await transport.signingRequests.count
        let sealed = await transport.sealedRedemptions
        let sent = await transport.exchangedRedemptions
        XCTAssertEqual(signed, 1, "a retry never builds a new redemption")
        XCTAssertEqual(sealed.count, 1)
        XCTAssertEqual(sent.count, 6)
        XCTAssertEqual(Set(sent), Set(sealed), "every exchange carries the one redemption")
    }

    func testWaitingStopsWhenTheCodeExpires() async throws {
        let transport = FakeCommissionTransport(invitation: invitationJSON(), answers: [])
        let clock = clock!
        let service = makeService(manager: makeManager(), transport: transport, pause: { nanoseconds in
            clock.now = clock.now.addingTimeInterval(TimeInterval(nanoseconds) / 1_000_000_000 * 100)
            await Task.yield()
        })
        service.start(qrText: qr)
        await waitForStage(service) { $0 == .expired }
        let asked = await transport.exchangedRedemptions.count
        XCTAssertEqual(asked, 5, "asked every 2 s (here 200 s per pause) until 900 s had passed")
    }

    func testCancellingStopsAsking() async throws {
        let transport = FakeCommissionTransport(invitation: invitationJSON(), answers: [])
        let service = makeService(manager: makeManager(), transport: transport, pause: { _ in
            try await Task.sleep(nanoseconds: 20_000_000)
        })
        service.start(qrText: qr)
        await waitForStage(service) { if case .waiting = $0 { return true }; return false }
        service.dismiss()
        let asked = await transport.exchangedRedemptions.count
        try await Task.sleep(nanoseconds: 100_000_000)
        let later = await transport.exchangedRedemptions.count
        XCTAssertEqual(service.stage, .idle)
        XCTAssertLessThanOrEqual(later, asked + 1)
    }

    // MARK: - Before connecting

    func testAPhoneEnrolledElsewhereRefusesBeforeConnecting() async throws {
        let manager = makeManager()
        let other = try profileDocument(organization: "other-org", name: "Other Org", profile: "other-field")
        try manager.apply(manager.review(document: other.document, source: .office,
                                         enteredLicence: other.licence).get()).get()
        let transport = FakeCommissionTransport(invitation: invitationJSON(), answers: [])
        let service = makeService(manager: manager, transport: transport)
        service.start(qrText: qr)
        await waitForStage(service) { $0 == .notStarted(.enrolledElsewhere(organization: "Other Org")) }
        let signed = await transport.signingRequests.count
        let asked = await transport.exchangedRedemptions.count
        XCTAssertEqual(signed, 0)
        XCTAssertEqual(asked, 0)
    }

    func testThePhoneAlreadyInTheOrganisationKeepsItsEnrolment() async throws {
        let manager = makeManager()
        let setup = try profileDocument()
        try manager.apply(manager.review(document: setup.document, source: .office,
                                         enteredLicence: setup.licence).get()).get()
        let transport = FakeCommissionTransport(invitation: invitationJSON(), answers: [
            .success(#"{"status":"refused","reason":"policy"}"#),
        ])
        let service = makeService(manager: manager, transport: transport)
        service.start(qrText: qr)
        await waitForStage(service) { $0 == .refused(.policy) }
        let requests = await transport.signingRequests
        XCTAssertEqual(requests.first?.enrolmentID, "phone-one")
        XCTAssertEqual(requests.first?.existingEnrolment, "northbridge")
    }

    func testACodeTheTransportRefusesIsNotAnswered() async throws {
        let transport = FakeCommissionTransport(invitation: nil, answers: [])
        let service = makeService(manager: makeManager(), transport: transport)
        service.start(qrText: try CommissionFixtures.text("commission-qr-v1.txt"))
        await waitForStage(service) { $0 == .notStarted(.malformed) }
        clock.now = Date(timeIntervalSince1970: 1_800_000_900)
        service.start(qrText: try CommissionFixtures.text("commission-qr-v1.txt"))
        await waitForStage(service) { $0 == .notStarted(.expired) }
        let signed = await transport.signingRequests.count
        XCTAssertEqual(signed, 0)
    }

    func testABuildWithoutTheOfficeTransportSaysSo() {
        let service = makeService(manager: makeManager(), transport: nil)
        service.start(qrText: qr)
        XCTAssertEqual(service.stage, .notStarted(.unsupportedBuild))
    }

    // MARK: - The office connection

    private func pairedOutcome(officeAddress: String) async throws -> (OrgProfileManager, OfficeCommissioningService.Stage) {
        let manager = makeManager()
        let phoneKey = try await phone.publicKey()
        let transport = FakeCommissionTransport(invitation: invitationJSON(), answers: [
            .success(try approval(setup: profileDocument(), binding: binding(phoneKey: phoneKey),
                                  officeAddress: officeAddress)),
        ])
        let service = makeService(manager: manager, transport: transport)
        service.start(qrText: qr)
        await waitForStage(service) { if case .reviewing = $0 { return true }; return false }
        service.confirm()
        await waitForStage(service) { if case .paired = $0 { return true }; return false }
        return (manager, service.stage)
    }

    func testAnOfficeThatCannotBeReachedYetLeavesThePairingKept() async throws {
        connectionFails = true
        let (manager, stage) = try await pairedOutcome(officeAddress: "192.168.1.24:22000")
        XCTAssertEqual(stage, .paired("Northbridge", officeConnected: false))
        XCTAssertEqual(dialled, ["tcp://192.168.1.24:22000"])
        XCTAssertEqual(manager.record?.enrolmentId, "phone-one")
        let kept = try await highWater.read(organizationID: "northbridge", enrolmentID: "phone-one")
        XCTAssertEqual(kept?.generation, 1)
    }

    func testAnAddressOffThePrivateNetworkIsNeverDialled() async throws {
        for address in ["8.8.8.8:22000", "office.example.com:22000", ""] {
            dialled = []
            let (_, stage) = try await pairedOutcome(officeAddress: address)
            XCTAssertEqual(stage, .paired("Northbridge", officeConnected: false), address)
            XCTAssertEqual(dialled, [], address)
            for organization in ["northbridge"] {
                let scope = try OfficePeerHighWaterStore.scopeID(organizationID: organization, enrolmentID: "phone-one")
                try? KeychainService.deleteItem(highWaterPrefix + scope)
                try? KeychainService.deleteItem(approvedPrefix + scope)
            }
        }
    }
}
