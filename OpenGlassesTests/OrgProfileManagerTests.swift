import XCTest
import CryptoKit
@testable import OpenGlasses

/// Plan CT PR 2 — enrolling, loading and removing a profile, over in-memory seams: no
/// `UserDefaults`, no `LicenseService`, no process-wide envelope.
@MainActor
final class OrgProfileManagerTests: XCTestCase {

    private let keyId = "test-key"
    private var signingKey: Curve25519.Signing.PrivateKey!
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    // In-memory world the seams write to.
    private var settings: [SettingKey: ProfileValue] = [:]
    private var storedRecord: OrgEnrolmentRecord?
    private var storedLicence: String?
    private var activations: [String] = []
    private var licenceFails = false
    private var envelope: (ProfileApplier.Result, String)?
    private var envelopeCleared = 0

    override func setUp() {
        super.setUp()
        signingKey = Curve25519.Signing.PrivateKey()
        settings = [:]
        storedRecord = nil
        storedLicence = nil
        activations = []
        licenceFails = false
        envelope = nil
        envelopeCleared = 0
    }

    private func makeManager() -> OrgProfileManager {
        var seams = OrgProfileManager.Seams()
        seams.verificationKeys = [keyId: signingKey.publicKey.rawRepresentation.base64EncodedString()]
        seams.licenceKey = signingKey.publicKey.rawRepresentation.base64EncodedString()
        let fixedNow = now
        seams.now = { fixedNow }
        seams.resolvableVaultIds = { ["refrigeration", "hvac_rtu"] }
        seams.loadRecord = { [unowned self] in self.storedRecord }
        seams.saveRecord = { [unowned self] in self.storedRecord = $0 }
        seams.readSetting = { [unowned self] in self.settings[$0] }
        seams.writeSetting = { [unowned self] key, value in self.settings[key] = value }
        seams.activateLicence = { [unowned self] code in
            if self.licenceFails { throw LicenseService.LicenseError.badSignature }
            self.activations.append(code)
            self.storedLicence = code
        }
        seams.storedLicenceCode = { [unowned self] in self.storedLicence }
        seams.clearLicence = { [unowned self] in self.storedLicence = nil }
        seams.installEnvelope = { [unowned self] result, name in self.envelope = (result, name) }
        seams.clearEnvelope = { [unowned self] in self.envelope = nil; self.envelopeCleared += 1 }
        seams.newEnrolmentId = { "enrol123" }
        return OrgProfileManager(seams: seams)
    }

    private func licence() throws -> String {
        let payload = LicenseService.LicensePayload(feature: "field_assist", licensee: "Northbridge",
                                                    issued: now, expires: now.addingTimeInterval(86_400 * 365))
        return try LicenseService.makeCode(payload: payload,
                                           privateKeyBase64: signingKey.rawRepresentation.base64EncodedString())
    }

    private func document(profileId: String = "northbridge", name: String = "Northbridge Mechanical",
                          licenceCode: String? = nil,
                          settings: [String: RawSetting] = [
                              "fieldAssistEnabled": RawSetting(.bool(true), .default),
                              "fieldAssistDefaultVaultId": RawSetting(.string("hvac_rtu"), .default),
                              "remoteInvokeCaptureEnabled": RawSetting(.bool(false), .ceiling),
                              "organizationDisplayName": RawSetting(.string("Northbridge Mechanical"), .default),
                          ]) throws -> String {
        let profile = ConfigProfile(keyId: keyId, profileId: profileId, organizationName: name,
                                    issued: now, leaseDays: 30, licenceCode: licenceCode, settings: settings)
        return try ProfileVerification.makeDocument(profile,
                                                    privateKeyBase64: signingKey.rawRepresentation.base64EncodedString())
    }

    private func enrol(_ manager: OrgProfileManager, _ document: String,
                       source: ProfileSource = .link) throws {
        let review = try manager.review(document: document, source: source).get()
        try manager.apply(review).get()
    }

    // MARK: - Enrolment

    func testEnrolmentActivatesTheLicenceWritesStartingValuesAndRaisesTheCeiling() throws {
        settings[.fieldAssistEnabled] = .bool(false)
        let code = try licence()
        let manager = makeManager()
        try enrol(manager, try document(licenceCode: code))

        XCTAssertEqual(activations, [code])
        XCTAssertEqual(settings[.fieldAssistEnabled], .bool(true))
        XCTAssertEqual(settings[.fieldAssistDefaultVaultId], .string("hvac_rtu"))
        XCTAssertEqual(envelope?.1, "Northbridge Mechanical")
        XCTAssertEqual(envelope?.0.ceilings[.remoteInvokeCaptureEnabled], .bool(false))
        XCTAssertEqual(envelope?.0.owned[.organizationDisplayName], .string("Northbridge Mechanical"))
        XCTAssertTrue(manager.isManaged)

        let record = try XCTUnwrap(storedRecord)
        XCTAssertEqual(record.enrolmentId, "enrol123")
        XCTAssertEqual(record.source, .link)
        XCTAssertTrue(record.activatedLicence)
        XCTAssertEqual(record.priorStartingValues["fieldAssistEnabled"], .bool(false))
        XCTAssertNil(record.priorStartingValues["fieldAssistDefaultVaultId"], "it was unset before")
        XCTAssertEqual(Set(record.wroteStartingKeys), ["fieldAssistEnabled", "fieldAssistDefaultVaultId"])
    }

    func testAFailedLicenceActivationChangesNothing() throws {
        licenceFails = true
        let manager = makeManager()
        let review = try manager.review(document: try document(licenceCode: try licence()), source: .link).get()
        guard case .failure(.licence) = manager.apply(review) else { return XCTFail("expected a licence refusal") }
        XCTAssertTrue(settings.isEmpty)
        XCTAssertNil(envelope)
        XCTAssertNil(storedRecord)
        XCTAssertFalse(manager.isManaged)
    }

    func testAnotherOrganisationsProfileIsRefusedUntilTheFirstIsRemoved() throws {
        let manager = makeManager()
        try enrol(manager, try document())
        let other = try document(profileId: "someone-else", name: "Someone Else")
        guard case .failure(.managedByAnother(let name)) = manager.review(document: other, source: .link) else {
            return XCTFail("expected managedByAnother")
        }
        XCTAssertEqual(name, "Northbridge Mechanical")
    }

    func testARenewalKeepsThePersonsOriginalValuesAndTheEnrolment() throws {
        settings[.fieldAssistEnabled] = .bool(false)
        let manager = makeManager()
        try enrol(manager, try document())
        // The person changes nothing; the organisation re-issues the same profile.
        let review = try manager.review(document: try document(), source: .link).get()
        XCTAssertTrue(review.replacesCurrent)
        try manager.apply(review).get()
        XCTAssertEqual(storedRecord?.priorStartingValues["fieldAssistEnabled"], .bool(false),
                       "a renewal must not record the organisation's own value as the person's")
        XCTAssertEqual(storedRecord?.enrolmentId, "enrol123")
    }

    func testARevocationDocumentIsNotAProfile() throws {
        let revocation = ProfileRevocation(keyId: keyId, profileId: "northbridge", issued: now)
        let text = try ProfileVerification.makeDocument(revocation,
                                                        privateKeyBase64: signingKey.rawRepresentation.base64EncodedString())
        guard case .failure(.revocation) = makeManager().review(document: text, source: .link) else {
            return XCTFail("expected a revocation refusal")
        }
    }

    func testAnExpiredPolicyIsRefusedAtReview() throws {
        let profile = ConfigProfile(keyId: keyId, profileId: "p", organizationName: "Northbridge",
                                    issued: now.addingTimeInterval(-86_400 * 10),
                                    policyExpiry: now.addingTimeInterval(-1), leaseDays: 30)
        let text = try ProfileVerification.makeDocument(profile,
                                                        privateKeyBase64: signingKey.rawRepresentation.base64EncodedString())
        guard case .failure(.verification(.policyExpired)) = makeManager().review(document: text, source: .link) else {
            return XCTFail("expected policyExpired")
        }
    }

    // MARK: - Removal

    func testRemovalPutsBackThePersonsValuesClearsTheLicenceItBroughtAndLiftsTheCeiling() throws {
        settings[.fieldAssistEnabled] = .bool(false)
        let manager = makeManager()
        try enrol(manager, try document(licenceCode: try licence()))

        try manager.remove().get()
        XCTAssertEqual(settings[.fieldAssistEnabled], .bool(false))
        XCTAssertNil(settings[.fieldAssistDefaultVaultId], "an unset value is unset again")
        XCTAssertNil(storedLicence)
        XCTAssertNil(envelope)
        XCTAssertEqual(envelopeCleared, 1)
        XCTAssertNil(storedRecord)
        XCTAssertFalse(manager.isManaged)
    }

    func testRemovalLeavesALicenceSomebodyEnteredByHand() throws {
        let manager = makeManager()
        try enrol(manager, try document())       // no licence in the profile
        storedLicence = "typed-by-hand"
        try manager.remove().get()
        XCTAssertEqual(storedLicence, "typed-by-hand")
    }

    func testAnMDMDeliveredProfileCannotBeRemovedOnThePhone() throws {
        let manager = makeManager()
        try enrol(manager, try document(), source: .managedConfig)
        guard case .failure(.notRemovable) = manager.remove() else { return XCTFail("expected notRemovable") }
        XCTAssertTrue(manager.isManaged)
        XCTAssertNotNil(envelope)
    }

    // MARK: - Launch

    func testLaunchReverifiesTheStoredDocumentAndRestoresTheCeiling() throws {
        try enrol(makeManager(), try document())
        envelope = nil

        let relaunched = makeManager()
        relaunched.loadAtLaunch()
        XCTAssertTrue(relaunched.isManaged)
        XCTAssertNil(relaunched.loadProblem)
        XCTAssertEqual(envelope?.0.ceilings[.remoteInvokeCaptureEnabled], .bool(false))
    }

    func testATamperedStoredDocumentLeavesThePhoneUnmanagedAndSaysWhy() throws {
        try enrol(makeManager(), try document())
        let record = try XCTUnwrap(storedRecord)
        let parts = record.document.split(separator: ".").map(String.init)
        let payload = try XCTUnwrap(Data(base64Encoded: parts[0]))
        let tampered = String(decoding: payload, as: UTF8.self)
            .replacingOccurrences(of: "\"leaseDays\":30", with: "\"leaseDays\":365")
        storedRecord = OrgEnrolmentRecord(
            document: "\(Data(tampered.utf8).base64EncodedString()).\(parts[1])",
            source: record.source, enrolmentId: record.enrolmentId, enrolledAt: record.enrolledAt,
            priorStartingValues: record.priorStartingValues, wroteStartingKeys: record.wroteStartingKeys,
            activatedLicence: record.activatedLicence)

        let relaunched = makeManager()
        relaunched.loadAtLaunch()
        XCTAssertFalse(relaunched.isManaged)
        XCTAssertNotNil(relaunched.loadProblem)
        XCTAssertEqual(envelopeCleared, 1)
    }

    // MARK: - Review copy

    func testTheReviewNamesWhatItLocksSetsAndSupplies() throws {
        let review = try makeManager().review(document: try document(licenceCode: try licence()), source: .link).get()
        XCTAssertEqual(review.organizationName, "Northbridge Mechanical")
        XCTAssertEqual(review.lockLines, ["Remote camera, recording and transcript requests are off"])
        XCTAssertEqual(review.startingValueLines.count, 2)
        XCTAssertEqual(review.organizationLines, ["Its name on the customer sign-off sheet"])
        XCTAssertTrue(review.carriesLicence)
        XCTAssertTrue(review.dropLines.isEmpty)
    }
}
