import CryptoKit
import Foundation
import XCTest
@testable import OpenGlasses

/// The publisher grant and the assignment receipt as the phone reads and writes them, against the
/// Go golden fixtures and the contract's negative cases (Contracts/office-bulk.md §9).
final class OfficeBulkTests: XCTestCase {
    private typealias F = OfficeCheckInFixtures

    private func assertRefused<T>(_ expected: OfficeBulk.Refusal, _ name: String, line: UInt = #line,
                                  _ body: () throws -> T) {
        XCTAssertThrowsError(try body(), name, line: line) {
            XCTAssertEqual($0 as? OfficeBulk.Refusal, expected, name, line: line)
        }
    }

    static func publisher() throws -> Curve25519.Signing.PrivateKey {
        try OfficeCheckInFixtures.key("Avenkin public fixture organisation publisher key v1")
    }

    private func readGrant(_ data: Data, organizationID: String = "fixture-organisation",
                           profileID: String = "fixture-profile") throws -> OfficeBulk.VerifiedGrant {
        try OfficeBulk.grant(data, administratorKey: F.administrator().publicKey.rawRepresentation,
                             organizationID: organizationID, profileID: profileID)
    }

    private func resigned(_ change: (inout [String: Any]) -> Void,
                          by key: Curve25519.Signing.PrivateKey? = nil) throws -> Data {
        try F.changed("office-publisher-grant-v1", domain: OfficeBulk.grantDomain,
                      by: key ?? F.administrator(), change)
    }

    func testTheGoldenGrantNamesTheOrganisationsOwnPublisherAndItsKey() throws {
        let grant = try readGrant(F.data("office-publisher-grant-v1"))
        XCTAssertEqual(grant.payload.publisherID, "org.fixture-organisation")
        XCTAssertEqual(grant.payload.publisherName, "Fixture Organisation")
        XCTAssertEqual(grant.payload.publisherKey, try Self.publisher().publicKey.rawRepresentation.base64EncodedString())
        XCTAssertEqual(grant.payload.sequence, 1)
        XCTAssertEqual(grant.payloadSHA256, OfficeBulk.digest(try F.payload("office-publisher-grant-v1")))
        // Live inside its window, and never past the profile's own term.
        let p = grant.payload
        XCTAssertTrue(p.isLive(now: F.now, policyExpiry: nil))
        XCTAssertFalse(p.isLive(now: p.issuedAt - 1, policyExpiry: nil))
        XCTAssertFalse(p.isLive(now: p.expiresAt, policyExpiry: nil))
        XCTAssertFalse(p.isLive(now: F.now, policyExpiry: Date(timeIntervalSince1970: TimeInterval(F.now))))
        XCTAssertTrue(p.isLive(now: F.now, policyExpiry: Date(timeIntervalSince1970: TimeInterval(F.now + 1))))
    }

    func testAGrantIsTheAdministratorsForThisOrganisationAndOnlyForItsOwnPublisher() throws {
        let payload = try F.payload("office-publisher-grant-v1")
        for (name, signer) in [("the office application key", try F.office()), ("the publisher itself", try Self.publisher()),
                               ("the phone", try F.phone())] {
            assertRefused(.badSignature, name) {
                try self.readGrant(F.signed(payload, domain: OfficeBulk.grantDomain, by: signer))
            }
        }
        // The administrator's key signs bindings, results and removals too; none of those is a grant.
        let bindingDomain = Data("Avenkin.OfficePeerBinding.v1\0".utf8)
        for domain in [OfficeBulk.receiptDomain, bindingDomain, OfficeCheckIn.removalDomain] {
            assertRefused(.badSignature, "under another message's domain") {
                try self.readGrant(F.signed(payload, domain: domain, by: F.administrator()))
            }
        }
        assertRefused(.wrongOrganisation, "another profile") {
            try self.readGrant(F.data("office-publisher-grant-v1"), profileID: "another-profile")
        }
        assertRefused(.wrongOrganisation, "another organisation") {
            try self.readGrant(self.resigned {
                $0["organizationID"] = "another-organisation"
                $0["publisherID"] = "org.another-organisation"
            })
        }
        let cases: [(String, (inout [String: Any]) -> Void)] = [
            ("a publisher that is not the organisation's own", { $0["publisherID"] = "lennox" }),
            ("another organisation's publisher", { $0["publisherID"] = "org.another-organisation" }),
            ("a prefix that only looks like its own", { $0["publisherID"] = "org.fixture-organisation-two" }),
            ("a short key", { $0["publisherKey"] = "AAAA" }),
            ("a name that needs an escape", { $0["publisherName"] = "Fixture \"Organisation\"" }),
            ("no name", { $0["publisherName"] = "" }),
            ("a status v1 does not have", { $0["status"] = "suspended" }),
            ("sequence zero", { $0["sequence"] = 0 }),
            ("a lifetime over the cap", { $0["expiresAt"] = F.now + 500 * 86_400 }),
            ("another kind", { $0["kind"] = OfficeBulk.receiptKind }),
        ]
        for (name, change) in cases {
            assertRefused(.invalidFields, name) { try self.readGrant(self.resigned(change)) }
        }
        // A name of its own under the organisation's prefix is allowed.
        XCTAssertEqual(try readGrant(resigned { $0["publisherID"] = "org.fixture-organisation.service" })
            .payload.publisherID, "org.fixture-organisation.service")
        XCTAssertTrue(OfficeBulk.isOrganisationPublisher("org.fixture-organisation", organizationID: "fixture-organisation"))
        XCTAssertFalse(OfficeBulk.isOrganisationPublisher("org.fixture-organisation", organizationID: "fixture"))
        for (name, change) in [
            ("an extra member", { $0["vaultID"] = "x" }),
            ("a missing member", { $0["sequence"] = nil }),
            ("a nested value", { $0["sequence"] = ["n": 1] }),
        ] as [(String, (inout [String: Any]) -> Void)] {
            assertRefused(.malformed, name) { try self.readGrant(self.resigned(change)) }
        }
    }

    func testALaterGrantReplacesAnEarlierOneAndARevocationIsReadWhenever() throws {
        let grant = try readGrant(F.data("office-publisher-grant-v1"))
        // Long after it would have expired, a revocation still reads; it is never live.
        let revoked = try readGrant(resigned {
            $0["sequence"] = 2
            $0["status"] = "revoked"
        })
        XCTAssertFalse(revoked.payload.isLive(now: F.now, policyExpiry: nil))
        XCTAssertEqual(OfficeBulk.standing(heldSequence: 1, heldSHA256: grant.payloadSHA256, arriving: revoked), .newer)
        XCTAssertEqual(OfficeBulk.standing(heldSequence: 1, heldSHA256: grant.payloadSHA256, arriving: grant), .same)
        XCTAssertEqual(OfficeBulk.standing(heldSequence: 1, heldSHA256: revoked.payloadSHA256, arriving: grant), .conflict)
        // Once revoked, the grant it replaced never comes back.
        XCTAssertEqual(OfficeBulk.standing(heldSequence: 2, heldSHA256: revoked.payloadSHA256, arriving: grant), .older)
    }

    func testOnlyAClosedAssignmentReceiptIsOneThePhoneSigns() throws {
        for outcome in ["received", "installed"] {
            let payload = try F.payload("office-bulk-assignment-receipt-\(outcome)-v1")
            let receipt = try XCTUnwrap(OfficeBulk.receiptPayload(payload))
            XCTAssertEqual(receipt.outcome, outcome)
            XCTAssertEqual(receipt.setID, "fixture-manuals")
            XCTAssertEqual(receipt.archiveSHA256, OfficeBulk.digest(try F.file("office-bulk-vault-v1", extension: "zip")))
            XCTAssertEqual(try OfficeBulk.receipt(F.data("office-bulk-assignment-receipt-\(outcome)-v1"),
                                                  phoneApplicationKey: F.phone().publicKey.rawRepresentation), receipt)
        }
        let payload = try F.payload("office-bulk-assignment-receipt-installed-v1")
        assertRefused(.badSignature, "signed by the office") {
            try OfficeBulk.receipt(F.signed(payload, domain: OfficeBulk.receiptDomain, by: F.office()),
                                   phoneApplicationKey: F.phone().publicKey.rawRepresentation)
        }
        assertRefused(.badSignature, "under the job receipt's domain") {
            try OfficeBulk.receipt(F.signed(payload, domain: OfficeManagedJobReceipt.domain, by: F.phone()),
                                   phoneApplicationKey: F.phone().publicKey.rawRepresentation)
        }
        var fields = try F.fields(payload)
        fields["outcome"] = "refused"
        XCTAssertNil(OfficeBulk.receiptPayload(try JSONSerialization.data(withJSONObject: fields)))
        fields["outcome"] = "installed"
        fields["path"] = "x"
        XCTAssertNil(OfficeBulk.receiptPayload(try JSONSerialization.data(withJSONObject: fields)))
        // No other message is an assignment receipt.
        for name in ["office-publisher-grant-v1", "office-bulk-assignment-v1", "office-report-receipt-full-v1",
                     "office-removal-receipt-v1"] {
            XCTAssertNil(OfficeBulk.receiptPayload(try F.payload(name)), name)
        }
    }
}
