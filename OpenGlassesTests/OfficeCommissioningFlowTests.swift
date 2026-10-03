import CryptoKit
import Foundation
import XCTest
@testable import OpenGlasses

/// Joining an office by its code (Contracts/commissioning.md): the pure decisions, and the
/// transport's answers as the phone reads them, against the contract's public fixtures.
final class OfficeCommissioningFlowTests: XCTestCase {
    private let now: Int64 = 1_800_000_000

    /// The fictional office's public key, from the published fixture keys.
    private static let fixtureOfficeKey: String = {
        (try! CommissionFixtures.keys())["officeApplicationKey"] as! String
    }()

    private func invitation(organizationID: String = "fixture-organisation",
                            issuedAt: Int64 = 1_800_000_000,
                            expiresAt: Int64 = 1_800_000_900) -> OfficeCommissioning.Invitation {
        try! OfficeCommissioning.decodeInvitation("""
        {"invitationEnvelope":"{}","invitationSHA256":"\(String(repeating: "a", count: 64))",
         "organizationID":"\(organizationID)","officeID":"office-6c20b57a74ba2a4be634f3dd",
         "officeApplicationKey":"\(Self.fixtureOfficeKey)",
         "officeTransportID":"DQB4YVC-VNAIUQE-UNBOI3L-YIZRPME-WG6DM7S-GSGGKBY-BGA7SBN-Q2OHOAZ",
         "address":"192.168.1.24:22443","issuedAt":\(issuedAt),"expiresAt":\(expiresAt)}
        """)
    }

    // MARK: - The scanned text

    func testOnlyTheOfficeCodeRoutesToCommissioning() throws {
        let qr = try CommissionFixtures.text("commission-qr-v1.txt")
        XCTAssertEqual(qr.count, 938, "the contract states the fixture's length")
        XCTAssertTrue(OfficeCommissioning.isCommissioningCode(qr))
        XCTAssertTrue(OfficeCommissioning.isCommissioningCode(qr + "\n"),
                      "routed to commissioning, where the transport refuses inexact text")
        XCTAssertFalse(OfficeCommissioning.isCommissioningCode("openglasses://enrol?url=https%3A%2F%2Fexample.com"))
        XCTAssertFalse(OfficeCommissioning.isCommissioningCode("https://config.example.com/profile.txt"))
        XCTAssertFalse(OfficeCommissioning.isCommissioningCode("avenkin://commission"))
    }

    func testARefusedCodeIsCalledExpiredOnlyWhenItsWindowHasPassed() throws {
        let qr = try CommissionFixtures.text("commission-qr-v1.txt")
        XCTAssertEqual(OfficeCommissioningFlow.unreadable(qrText: qr, now: 1_800_000_900), .expired)
        XCTAssertEqual(OfficeCommissioningFlow.unreadable(qrText: qr, now: 1_800_000_899), .malformed)
        XCTAssertEqual(OfficeCommissioningFlow.unreadable(qrText: "avenkin-commission:%%%", now: now), .malformed)
        XCTAssertEqual(OfficeCommissioningFlow.unreadable(qrText: "hello", now: now), .malformed)
    }

    // MARK: - Before connecting (contract §4)

    func testAPhoneEnrolledToAnotherOrganisationRefusesBeforeConnecting() {
        let code = invitation()
        XCTAssertNil(OfficeCommissioningFlow.beforeConnecting(code, current: .none, now: now))
        let same = OfficeCommissioningFlow.CurrentEnrolment(isManaged: true, organizationID: "fixture-organisation",
                                                            organizationName: "Fixture")
        XCTAssertNil(OfficeCommissioningFlow.beforeConnecting(code, current: same, now: now))
        XCTAssertEqual(OfficeCommissioningFlow.existingEnrolment(same), "fixture-organisation")
        XCTAssertEqual(OfficeCommissioningFlow.existingEnrolment(.none), "")

        let other = OfficeCommissioningFlow.CurrentEnrolment(isManaged: true, organizationID: "northbridge",
                                                             organizationName: "Northbridge")
        XCTAssertEqual(OfficeCommissioningFlow.beforeConnecting(code, current: other, now: now),
                       .enrolledElsewhere(organization: "Northbridge"))
        // A hosted (schema-1) profile names no office organisation, so it cannot be the same one.
        let hosted = OfficeCommissioningFlow.CurrentEnrolment(isManaged: true, organizationID: nil,
                                                              organizationName: "Hosted Co")
        XCTAssertEqual(OfficeCommissioningFlow.beforeConnecting(code, current: hosted, now: now),
                       .enrolledElsewhere(organization: "Hosted Co"))
    }

    func testACodeOutsideItsWindowRefusesBeforeConnecting() {
        let code = invitation()
        XCTAssertEqual(OfficeCommissioningFlow.beforeConnecting(code, current: .none, now: 1_800_000_900), .expired)
        XCTAssertEqual(OfficeCommissioningFlow.beforeConnecting(code, current: .none, now: 1_799_999_999), .expired)
        XCTAssertNil(OfficeCommissioningFlow.beforeConnecting(code, current: .none, now: 1_800_000_899))
    }

    // MARK: - The redemption

    func testThePhoneSignsExactlyTheDomainZeroByteAndPayloadItSeals() throws {
        let payload = try CommissionFixtures.payload("commission-redemption-v1.json")
        let exact = OfficeCommissioning.SigningInput(
            payload: payload.base64EncodedString(),
            signingInput: (Data("Avenkin.CommissionRedemption.v1".utf8) + [0] + payload).base64EncodedString())
        let checked = try XCTUnwrap(OfficeCommissioningFlow.checkedSigningInput(exact))
        XCTAssertEqual(checked.payload, payload)

        // The fixture's own signature covers exactly these bytes.
        let keys = try CommissionFixtures.keys()
        let phoneKey = try Curve25519.Signing.PublicKey(rawRepresentation: XCTUnwrap(
            Data(base64Encoded: XCTUnwrap(keys["phoneApplicationKey"] as? String))))
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(CommissionFixtures.text("commission-redemption-v1.json").utf8)) as? [String: String])
        let signature = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(envelope["signature"])))
        XCTAssertTrue(phoneKey.isValidSignature(signature, for: checked.signingInput))

        let otherPayload = OfficeCommissioning.SigningInput(
            payload: Data("{}".utf8).base64EncodedString(), signingInput: exact.signingInput)
        XCTAssertNil(OfficeCommissioningFlow.checkedSigningInput(otherPayload))
        let noDomain = OfficeCommissioning.SigningInput(payload: exact.payload,
                                                        signingInput: payload.base64EncodedString())
        XCTAssertNil(OfficeCommissioningFlow.checkedSigningInput(noDomain))
    }

    // MARK: - The comparison code

    func testTheFixtureComparisonCodeShowsInThreeGroups() throws {
        let code = try CommissionFixtures.text("commission-comparison-v1.txt")
        XCTAssertEqual(code, "EGVW-EFKZ-2ZDB")
        XCTAssertEqual(OfficeCommissioningFlow.comparisonGroups(code), ["EGVW", "EFKZ", "2ZDB"])
        for bad in ["EGVW-EFKZ", "EGVW-EFKZ-2ZD", "egvw-efkz-2zdb", "EGVW-EFKZ-2ZDU", "EGVW EFKZ 2ZDB", ""] {
            XCTAssertNil(OfficeCommissioningFlow.comparisonGroups(bad), bad)
        }
    }

    /// The fake transport's comparison is the contract's derivation: digests of the exact
    /// envelope bytes, then the code. Pinned to the fixture so the fake cannot drift.
    func testTheFakeTransportDerivesTheFixtureComparisonCode() throws {
        let invitation = try CommissionFixtures.text("commission-invitation-v1.json")
        let redemption = try CommissionFixtures.text("commission-redemption-v1.json")
        let keys = try CommissionFixtures.keys()
        XCTAssertEqual(CommissionFixtures.digest(invitation), keys["invitationSHA256"] as? String)
        XCTAssertEqual(CommissionFixtures.digest(redemption), keys["redemptionSHA256"] as? String)
        XCTAssertEqual(CommissionFixtures.comparison(invitationSHA256: CommissionFixtures.digest(invitation),
                                                     redemptionSHA256: CommissionFixtures.digest(redemption)),
                       "EGVW-EFKZ-2ZDB")
    }

    // MARK: - The office's answers

    func testAnswersDecode() throws {
        XCTAssertEqual(try OfficeCommissioning.decodeDecision(#"{"status":"awaiting"}"#), .awaiting)
        let approved = try OfficeCommissioning.decodeDecision("""
        {"status":"approved","enrolmentID":"fixture-enrolment","profileDocument":"P.S",
         "licenceCode":"L.S","peerBinding":"{}","decisionEnvelope":"{}"}
        """)
        XCTAssertEqual(approved, .approved(.init(enrolmentID: "fixture-enrolment", profileDocument: "P.S",
                                                 licenceCode: "L.S", peerBinding: "{}", decisionEnvelope: "{}")))
        for reason in OfficeCommissioning.RefusalReason.allCases {
            XCTAssertEqual(try OfficeCommissioning.decodeDecision(
                #"{"status":"refused","reason":"\#(reason.rawValue)"}"#), .refused(reason))
        }
        // The contract's closed set: the fixture's reason is one of them.
        let refusal = try XCTUnwrap(JSONSerialization.jsonObject(
            with: CommissionFixtures.payload("commission-refusal-v1.json")) as? [String: Any])
        XCTAssertNotNil(OfficeCommissioning.RefusalReason(rawValue: try XCTUnwrap(refusal["reason"] as? String)))

        for bad in [#"{"status":"refused","reason":"because"}"#,
                    #"{"status":"approved","enrolmentID":"x","profileDocument":"","licenceCode":"L","peerBinding":"{}","decisionEnvelope":"{}"}"#,
                    #"{"status":"approved","enrolmentID":"x"}"#,
                    #"{"status":"maybe"}"#, "not json"] {
            XCTAssertThrowsError(try OfficeCommissioning.decodeDecision(bad), bad)
        }
    }

    func testAnApprovalForAnotherEnrolmentIsRefusedByThePhone() {
        let approval = OfficeCommissioning.Approval(enrolmentID: "someone-else", profileDocument: "P",
                                                    licenceCode: "L", peerBinding: "B", decisionEnvelope: "D")
        XCTAssertEqual(OfficeCommissioningFlow.afterAnswer(.approved(approval), chosenEnrolmentID: "phone-one",
                                                           expiresAt: now + 900, now: now),
                       .failed(.approvalForAnotherPhone))
        let mine = OfficeCommissioning.Approval(enrolmentID: "phone-one", profileDocument: "P",
                                                licenceCode: "L", peerBinding: "B", decisionEnvelope: "D")
        XCTAssertEqual(OfficeCommissioningFlow.afterAnswer(.approved(mine), chosenEnrolmentID: "phone-one",
                                                           expiresAt: now + 900, now: now),
                       .approved(mine))
    }

    func testWaitingEndsAtTheCodesExpiry() {
        XCTAssertEqual(OfficeCommissioningFlow.afterAnswer(.awaiting, chosenEnrolmentID: "p",
                                                           expiresAt: now + 1, now: now), .keepWaiting)
        XCTAssertEqual(OfficeCommissioningFlow.afterAnswer(.awaiting, chosenEnrolmentID: "p",
                                                           expiresAt: now, now: now), .expired)
        XCTAssertEqual(OfficeCommissioningFlow.afterAnswer(.refused(.policy), chosenEnrolmentID: "p",
                                                           expiresAt: now + 1, now: now), .refused(.policy))
        XCTAssertTrue(OfficeCommissioningFlow.shouldAsk(expiresAt: now + 1, now: now))
        XCTAssertFalse(OfficeCommissioningFlow.shouldAsk(expiresAt: now, now: now))
    }

    func testANetworkBlipIsRetriedQuietlyThenThePersonIsAsked() {
        XCTAssertEqual(OfficeCommissioningFlow.afterNetworkFailure(consecutive: 1, expiresAt: now + 60, now: now),
                       .tryAgainQuietly)
        XCTAssertEqual(OfficeCommissioningFlow.afterNetworkFailure(consecutive: 2, expiresAt: now + 60, now: now),
                       .tryAgainQuietly)
        XCTAssertEqual(OfficeCommissioningFlow.afterNetworkFailure(consecutive: 3, expiresAt: now + 60, now: now),
                       .offerRetry)
        XCTAssertEqual(OfficeCommissioningFlow.afterNetworkFailure(consecutive: 1, expiresAt: now, now: now),
                       .expired)
    }

    func testTheSetupMustBeForTheOrganisationTheCodeNamed() {
        XCTAssertTrue(OfficeCommissioningFlow.setupMatchesInvitation(profileOrganizationID: "fixture-organisation",
                                                                     invitation: invitation()))
        XCTAssertFalse(OfficeCommissioningFlow.setupMatchesInvitation(profileOrganizationID: "northbridge",
                                                                      invitation: invitation()))
        XCTAssertFalse(OfficeCommissioningFlow.setupMatchesInvitation(profileOrganizationID: nil,
                                                                      invitation: invitation()))
    }
}
