import CryptoKit
import Foundation
import XCTest
@testable import OpenGlasses

final class OfficeManagedJobTests: XCTestCase {
    private let now: Int64 = 1_800_000_000
    private func fixture(_ name: String, extension ext: String) throws -> Data {
        #if SWIFT_PACKAGE
        let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")
        #else
        let url = Bundle(for: Self.self).url(forResource: name, withExtension: ext)
        #endif
        return try Data(contentsOf: XCTUnwrap(url))
    }
    private func trust(enrolment: String = "fixture-phone") throws -> OfficeManagedJob.Trust {
        let data = try fixture("managed-job-fixture-keys", extension: "json")
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try .init(organizationID: "fixture-org", enrolmentID: enrolment,
                         officeID: "fixture-office", generation: 1,
                         officeTransportID: XCTUnwrap(keys["officeTransportID"] as? String),
                         phoneTransportID: XCTUnwrap(keys["phoneTransportID"] as? String),
                         officeApplicationKey: XCTUnwrap(Data(base64Encoded:
                            XCTUnwrap(keys["officeApplicationKey"] as? String))))
    }
    private func envelope() throws -> Data { try fixture("managed-job-v1", extension: "json") }
    private func officeFixtureKey() throws -> Curve25519.Signing.PrivateKey {
        let seed = Data(SHA256.hash(data: Data("Avenkin public fixture office key v1".utf8)))
        return try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    }
    private func changed(_ mutation: (inout [String: Any]) -> Void) throws -> Data {
        let e = try JSONDecoder().decode(OfficeManagedJob.Envelope.self, from: envelope())
        let raw = try XCTUnwrap(Data(base64Encoded: e.payload))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        mutation(&object)
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let key = try officeFixtureKey()
        let signature = try key.signature(for: OfficeManagedJob.domain + bytes)
        return try JSONEncoder().encode(OfficeManagedJob.Envelope(
            payload: bytes.base64EncodedString(), signature: signature.base64EncodedString()))
    }
    private func refuses(_ data: Data, _ refusal: OfficeManagedJob.Refusal,
                         context: OfficeManagedJob.Trust? = nil,
                         previous: OfficeManagedJob.HighWater? = nil) throws {
        let context = try context ?? trust()
        XCTAssertThrowsError(try OfficeManagedJob.verify(data, trust: context, now: now,
                                                         highWater: previous)) {
            XCTAssertEqual($0 as? OfficeManagedJob.Refusal, refusal)
        }
    }
    func testGoGoldenBindsRecipientAndExactJobBytes() throws {
        let verified = try OfficeManagedJob.verify(envelope(), trust: trust(), now: now)
        XCTAssertEqual(verified.payload.sequence, 7)
        XCTAssertFalse(verified.isReplay)
        try OfficeManagedJob.verifyBytes(fixture("managed-job-v1", extension: "ogjob"), for: verified)
        XCTAssertThrowsError(try OfficeManagedJob.verifyBytes(Data("changed".utf8), for: verified)) {
            XCTAssertEqual($0 as? OfficeManagedJob.Refusal, .contentMismatch)
        }
        let replay = try OfficeManagedJob.verify(envelope(), trust: trust(), now: now,
                                                 highWater: verified.highWater)
        XCTAssertTrue(replay.isReplay)
    }
    func testForeignBindingExpiryAndBadSignatureRefused() throws {
        try refuses(envelope(), .wrongBinding, context: trust(enrolment: "other-phone"))
        for field in ["organizationID", "enrolmentID", "officeID", "phoneTransportID"] {
            try refuses(changed { $0[field] = "other" }, .wrongBinding)
        }
        try refuses(changed { $0["expiresAt"] = now }, .notCurrentlyValid)
        let e = try JSONDecoder().decode(OfficeManagedJob.Envelope.self, from: envelope())
        let bad = try JSONEncoder().encode(OfficeManagedJob.Envelope(
            payload: e.payload, signature: Data(repeating: 0, count: 64).base64EncodedString()))
        try refuses(bad, .badSignature)
    }
    func testRollbackConflictAndInvalidFieldsRefused() throws {
        let v = try OfficeManagedJob.verify(envelope(), trust: trust(), now: now)
        try refuses(changed { $0["sequence"] = 6 }, .rollback, previous: v.highWater)
        try refuses(changed { $0["messageID"] = "0123456789abcdef0123456789abcdef" },
                    .sequenceConflict, previous: v.highWater)
        try refuses(changed { $0["jobBytes"] = OfficeManagedJob.maximumJobBytes + 1 }, .invalidFields)
        try refuses(changed { $0["jobSHA256"] = String(repeating: "A", count: 64) }, .invalidFields)
    }
    func testClosedSchemaRefusesDuplicatesAndUnknownFields() throws {
        try refuses(changed { $0["extra"] = "ignored" }, .malformed)
        let e = try JSONDecoder().decode(OfficeManagedJob.Envelope.self, from: envelope())
        let raw = try XCTUnwrap(Data(base64Encoded: e.payload))
        let duplicate = try XCTUnwrap(String(data: raw, encoding: .utf8))
            .replacingOccurrences(of: "\"version\":1", with: "\"version\":1,\"version\":1")
        let key = try officeFixtureKey()
        let bytes = Data(duplicate.utf8)
        let signature = try key.signature(for: OfficeManagedJob.domain + bytes)
        let bad = try JSONEncoder().encode(OfficeManagedJob.Envelope(
            payload: bytes.base64EncodedString(), signature: signature.base64EncodedString()))
        try refuses(bad, .malformed)
    }
}
