import CryptoKit
import XCTest
@testable import OpenGlasses

/// What an office says about a recorded-job bundle (Contracts/recorded-session.md §6), as the
/// phone reads it, against the Go golden fixtures and receipts signed here with the fixture keys.
final class OfficeRecordingReceiptTests: XCTestCase {
    private typealias F = OfficeCheckInFixtures
    private typealias R = OfficeRecordingReceipt

    private func trust(key: Data? = nil) throws -> R.Trust {
        let held = try F.held()
        return R.Trust(organizationID: held.organizationID, enrolmentID: held.enrolmentID, officeID: held.officeID,
                       phoneTransportID: held.phoneTransportID, officeApplicationKey: key ?? held.officeApplicationKey)
    }

    private func sent() throws -> R.Sent {
        let manifest = try F.payload("recording-bundle-manifest-v1")
        return R.Sent(bundleID: try XCTUnwrap(try F.fields(manifest)["bundleID"] as? String),
                      manifestSHA256: OfficeCheckIn.digest(manifest), generation: 1)
    }

    private func refusal(_ data: Data, trust: R.Trust? = nil, sent: R.Sent? = nil) throws -> R.Refusal? {
        do {
            _ = try R.read(data, trust: trust ?? self.trust(), sent: sent ?? self.sent())
            return nil
        } catch let refusal as R.Refusal {
            return refusal
        }
    }

    private func changed(_ change: (inout [String: Any]) -> Void) throws -> Data {
        try F.changed("recording-receipt-received-v1", domain: R.domain, by: F.office(), change)
    }

    func testTheGoldenReceiptsAreTheOfficesAndForTheBundleSealed() throws {
        let received = try R.read(F.data("recording-receipt-received-v1"), trust: trust(), sent: sent())
        XCTAssertEqual(received.status, "received")
        XCTAssertEqual(received.at, F.now + 7_200)
        XCTAssertEqual(received.reason, "")

        let refused = try R.read(F.data("recording-receipt-refused-v1"), trust: trust(), sent: sent())
        XCTAssertEqual(refused.status, "refused")
        XCTAssertEqual(refused.reason, "digest")

        let published = try R.read(F.data("recording-receipt-published-v1"), trust: trust(), sent: sent())
        XCTAssertEqual(published.status, "published")
        XCTAssertEqual(published.vaultID, "fixture-organisation-vault")
        XCTAssertEqual(published.vaultVersion, "1.0.0")
    }

    func testAReceiptIsReadAgainstTheBindingAndThePhonesOwnRecord() throws {
        let received = try F.data("recording-receipt-received-v1")
        XCTAssertEqual(try refusal(received, trust: trust(key: F.phone().publicKey.rawRepresentation)), .badSignature)
        // A manifest is not a receipt, whoever signed it.
        XCTAssertEqual(try refusal(F.data("recording-bundle-manifest-v1"),
                                   trust: trust(key: F.phone().publicKey.rawRepresentation)), .badSignature)

        XCTAssertEqual(try refusal(try changed { $0["organizationID"] = "another-organisation" }), .wrongBinding)
        XCTAssertEqual(try refusal(try changed { $0["enrolmentID"] = "another-enrolment" }), .wrongBinding)
        XCTAssertEqual(try refusal(try changed { $0["officeID"] = "another-office" }), .wrongBinding)
        XCTAssertEqual(try refusal(try changed {
            $0["phoneTransportID"] = "DQB4YVC-VNAIUQE-UNBOI3L-YIZRPME-WG6DM7S-GSGGKBY-BGA7SBN-Q2OHOAZ"
        }), .wrongBinding)

        let own = try sent()
        XCTAssertEqual(try refusal(received, sent: .init(bundleID: String(repeating: "0", count: 32),
                                                         manifestSHA256: own.manifestSHA256, generation: 1)), .anotherBundle)
        XCTAssertEqual(try refusal(received, sent: .init(bundleID: own.bundleID,
                                                         manifestSHA256: String(repeating: "0", count: 64), generation: 1)), .anotherBundle)
        // The receipt names the generation the manifest was sealed under, whatever the binding is now.
        XCTAssertEqual(try refusal(received, sent: .init(bundleID: own.bundleID, manifestSHA256: own.manifestSHA256,
                                                         generation: 2)), .anotherBundle)
        XCTAssertEqual(try refusal(try changed { $0["generation"] = 2 }), .anotherBundle)

        XCTAssertEqual(try refusal(Data()), .malformed)
        XCTAssertEqual(try refusal(Data(#"{"payload":"e30=","signature":"AA==","extra":1}"#.utf8)), .malformed)
        XCTAssertEqual(try refusal(Data(repeating: 0x20, count: R.maximumMessageBytes + 1)), .malformed)
        XCTAssertEqual(try refusal(try changed { $0["trim"] = 1 }), .malformed)
        XCTAssertEqual(try refusal(try changed { $0["reason"] = nil }), .malformed)
    }

    func testEachStatusCarriesOnlyItsOwnMembers() throws {
        let bad: [(String, Data)] = [
            ("a status the contract does not name", try changed { $0["status"] = "seen" }),
            ("received with a reason", try changed { $0["reason"] = "digest" }),
            ("received with a vault", try changed { $0["vaultID"] = "vault"; $0["vaultVersion"] = "1.0.0" }),
            ("refused with no reason", try changed { $0["status"] = "refused" }),
            ("refused for a reason of its own", try changed { $0["status"] = "refused"; $0["reason"] = "busy" }),
            ("published with no vault", try changed { $0["status"] = "published" }),
            ("published with a vault that is a path", try changed {
                $0["status"] = "published"; $0["vaultID"] = "../vault"; $0["vaultVersion"] = "1.0.0"
            }),
            ("no time", try changed { $0["at"] = 0 }),
            ("another kind of message", try changed { $0["kind"] = "avenkin.recording-bundle" }),
            ("another version", try changed { $0["version"] = 2 }),
        ]
        for (what, data) in bad {
            XCTAssertEqual(try refusal(data), .invalidFields, what)
        }
        // A manifest digest that is not one cannot be the phone's own record either.
        XCTAssertEqual(try refusal(try changed { $0["manifestSHA256"] = "abc" }), .invalidFields)
        for status in ["reviewed", "rejected"] {
            XCTAssertNil(try refusal(try changed { $0["status"] = status }), status)
        }
        for reason in R.refusalReasons {
            XCTAssertNil(try refusal(try changed { $0["status"] = "refused"; $0["reason"] = reason }), reason)
        }
    }
}
