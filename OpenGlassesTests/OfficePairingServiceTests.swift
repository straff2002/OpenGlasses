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

    private func enrolledManager() throws -> (OrgProfileManager, String, String) {
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
        var seams = OrgProfileManager.Seams()
        seams.now = { [now] in now }
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

    private func binding(phoneTransportID: String = "transport-phone-one") throws -> Data {
        let payload = OfficePeerBinding.Payload(
            version: 1, kind: "avenkin.office-peer-binding", organizationID: "northbridge",
            profileID: "northbridge-field", enrolmentID: "phone-one", officeID: "office-one",
            generation: 1, officeTransportID: "transport-office-one",
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
        XCTAssertEqual(reopened.payload.officeID, "office-one")
    }
}
