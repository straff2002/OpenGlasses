import CryptoKit
import Foundation
import XCTest
@testable import OpenGlasses

@MainActor
final class PortableOfficePairingGateTests: XCTestCase {
    func testActualPhoneIdentityAndLiveEntitlementGateAdministratorBinding() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let vendor = Curve25519.Signing.PrivateKey()
        let licensor = Curve25519.Signing.PrivateKey()
        let administrator = Curve25519.Signing.PrivateKey()
        let office = Curve25519.Signing.PrivateKey()
        let phone = Curve25519.Signing.PrivateKey()
        let code = try LicenseService.makeCode(payload: .init(
            feature: "field_assist", licensee: "Northbridge", issued: now.addingTimeInterval(-60),
            expires: now.addingTimeInterval(86_400), organizationID: "northbridge",
            profileID: "northbridge-field"),
            privateKeyBase64: licensor.rawRepresentation.base64EncodedString())
        let profile = ConfigProfile(
            keyId: "vendor-test", profileId: "northbridge-field", organizationName: "Northbridge",
            issued: now.addingTimeInterval(-60), policyExpiry: now.addingTimeInterval(86_400),
            leaseDays: 30, licenceCode: code, officeAuthority: .init(
                organizationID: "northbridge",
                administratorPublicKey: administrator.publicKey.rawRepresentation.base64EncodedString(),
                transportPolicy: "privateLan"), schemaVersion: 2)
        let document = try ProfileVerification.makeDocument(profile,
            privateKeyBase64: vendor.rawRepresentation.base64EncodedString())
        let manager = OrgProfileManager()
        manager.profile = profile
        manager.record = OrgEnrolmentRecord(document: document, source: .office,
                                            enrolmentId: "phone-one", activatedLicenceCode: code,
                                            revoked: false)
        let highWater = OfficePeerHighWaterStore()
        let service = OfficePairingService(
            manager: manager, currentLicence: { code },
            transportID: { "transport-phone-one" },
            phoneApplicationKey: { phone.publicKey.rawRepresentation },
            highWater: highWater,
            profileKeys: ["vendor-test": vendor.publicKey.rawRepresentation.base64EncodedString()],
            licenceKey: licensor.publicKey.rawRepresentation.base64EncodedString(), clock: { now })
        let reviewed = OfficePairingService.ReviewedOffice(
            officeID: "office-one", transportID: "transport-office-one",
            applicationPublicKey: office.publicKey.rawRepresentation)
        func signed(_ phoneID: String) throws -> Data {
            let payload = OfficePeerBinding.Payload(
                version: 1, kind: "avenkin.office-peer-binding", organizationID: "northbridge",
                profileID: "northbridge-field", enrolmentID: "phone-one", officeID: "office-one",
                generation: 1, officeTransportID: "transport-office-one",
                officeApplicationKey: office.publicKey.rawRepresentation.base64EncodedString(),
                phoneTransportID: phoneID,
                phoneApplicationKey: phone.publicKey.rawRepresentation.base64EncodedString(),
                issuedAt: Int64(now.timeIntervalSince1970) - 60,
                expiresAt: Int64(now.timeIntervalSince1970) + 3_600)
            let bytes = try JSONEncoder().encode(payload)
            let signature = try administrator.signature(for: OfficePeerBinding.domain + bytes)
            return try JSONEncoder().encode(OfficePeerBinding.Envelope(
                payload: bytes.base64EncodedString(), signature: signature.base64EncodedString()))
        }
        do {
            _ = try await service.approve(signed("another-phone"), reviewedOffice: reviewed)
            XCTFail("signed binding for another transport identity was accepted")
        } catch {
            XCTAssertEqual(error as? OfficePeerBinding.Refusal, .wrongPeer)
        }
        let before = try await highWater.read(organizationID: "northbridge", enrolmentID: "phone-one")
        XCTAssertNil(before)
        let accepted = try await service.approve(signed("transport-phone-one"), reviewedOffice: reviewed,
                                                 lanHint: "192.168.1.2:22000")
        XCTAssertEqual(accepted.binding.payload.phoneTransportID, "transport-phone-one")
        let retained = try await highWater.read(organizationID: "northbridge", enrolmentID: "phone-one")
        XCTAssertEqual(retained?.generation, 1)
        let reopened = try await service.currentApprovedPeer()
        XCTAssertEqual(reopened.binding.payload.officeTransportID, "transport-office-one")
        // The policy comes from the vendor-signed profile; the address only from the saved approval.
        XCTAssertEqual(reopened.transportPolicy, .privateLan)
        XCTAssertEqual(reopened.lanHint, "tcp://192.168.1.2:22000")
        try await service.connectToApprovedOffice()
        let started = await OfficeTransportIdentity.shared.started()
        XCTAssertEqual(started, .init(transportID: "transport-office-one", policy: .privateLan,
                                      lanHint: "tcp://192.168.1.2:22000"))
        await OfficeTransportIdentity.shared.stop()
        do {
            try await service.connectToApprovedOffice(lanHint: "tcp://203.0.113.9:22000")
            XCTFail("an address off the private network was dialled")
        } catch {
            XCTAssertEqual(error as? OfficePairingService.Refusal, .noOfficeAddress)
        }
        let notStarted = await OfficeTransportIdentity.shared.isRunning()
        XCTAssertFalse(notStarted)

        manager.status = .lapsed
        do {
            _ = try await service.currentApprovedPeer()
            XCTFail("lapsed management lease allowed saved approval to reopen")
        } catch {
            XCTAssertEqual(error as? OfficePairingService.Refusal, .inactiveLease)
        }
        do {
            try await service.connectToApprovedOffice()
            XCTFail("lapsed management lease opened a connection")
        } catch {
            XCTAssertEqual(error as? OfficePairingService.Refusal, .inactiveLease)
        }
        let stopped = await OfficeTransportIdentity.shared.isRunning()
        XCTAssertFalse(stopped)
    }
}
