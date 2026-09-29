import CryptoKit
import Foundation
import XCTest
@testable import OpenGlasses

final class OfficeManualAssignmentTests: XCTestCase {
    private let now: Int64 = 1_800_000_000
    private func fixture(_ name: String, extension ext: String) throws -> Data {
        #if SWIFT_PACKAGE
        let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")
        #else
        let url = Bundle(for: Self.self).url(forResource: name, withExtension: ext)
        #endif
        return try Data(contentsOf: XCTUnwrap(url))
    }
    private func publicKey() throws -> Data {
        let keys = try JSONSerialization.jsonObject(with: fixture("manual-fixture-keys", extension: "json")) as? [String: Any]
        return try XCTUnwrap(Data(base64Encoded: XCTUnwrap(keys?["officePublicKey"] as? String)))
    }
    private func trust(enrolment: String = "fixture-phone", maximum: Int64 = 1_048_576) throws -> OfficeManualAssignment.Trust {
        .init(organizationID: "fixture-org", enrolmentID: enrolment, officeID: "fixture-office",
              generation: 1, setID: "fixture-set", publicKey: try publicKey(), maximumArchiveBytes: maximum)
    }
    private func envelope() throws -> Data { try fixture("manual-assignment-v1", extension: "json") }
    private func officeFixtureKey() throws -> Curve25519.Signing.PrivateKey {
        let seed = Data(SHA256.hash(data: Data("Avenkin public fixture office key v1".utf8)))
        return try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    }
    private func changed(_ mutation: (inout [String: Any]) -> Void) throws -> Data {
        let envelope = try JSONDecoder().decode(OfficeManualAssignment.Envelope.self, from: self.envelope())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(Data(base64Encoded: envelope.payload))) as? [String: Any])
        mutation(&object)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let key = try officeFixtureKey()
        let signature = try key.signature(for: OfficeManualAssignment.domain + data)
        return try JSONEncoder().encode(OfficeManualAssignment.Envelope(payload: data.base64EncodedString(), signature: signature.base64EncodedString()))
    }
    private func refuses(_ data: Data, _ refusal: OfficeManualAssignment.Refusal,
                         context: OfficeManualAssignment.Trust? = nil,
                         previous: OfficeManualAssignment.HighWater? = nil) throws {
        let context = try context ?? trust()
        XCTAssertThrowsError(try OfficeManualAssignment.verify(data, trust: context, now: now, highWater: previous)) {
            XCTAssertEqual($0 as? OfficeManualAssignment.Refusal, refusal)
        }
    }
    func testGoGoldenVerifiesAndExactReplayIsClassified() throws {
        let verified = try OfficeManualAssignment.verify(envelope(), trust: trust(), now: now)
        XCTAssertEqual(verified.payload.sequence, 7)
        XCTAssertFalse(verified.isReplay)
        let replay = try OfficeManualAssignment.verify(envelope(), trust: trust(), now: now, highWater: verified.highWater)
        XCTAssertTrue(replay.isReplay)
        XCTAssertEqual(verified.scopeID, replay.scopeID)
    }
    func testForeignRecipientAndAuthorityNeverVerify() throws {
        try refuses(envelope(), .wrongRecipientOrAuthority, context: trust(enrolment: "another-phone"))
        for field in ["organizationID", "enrolmentID", "officeID", "setID"] {
            try refuses(changed { $0[field] = "foreign" }, .wrongRecipientOrAuthority)
        }
        try refuses(changed { $0["generation"] = 2 }, .wrongRecipientOrAuthority)
    }
    func testExpiredFutureAndPolicyExceededAssignmentsAreRefused() throws {
        try refuses(changed { $0["expiresAt"] = now }, .notCurrentlyValid)
        try refuses(changed { $0["issuedAt"] = now + 1 }, .notCurrentlyValid)
        try refuses(envelope(), .exceedsPolicy, context: trust(maximum: 1))
    }
    func testUnsupportedUnsafeAndMalformedClaimsAreRefused() throws {
        try refuses(changed { $0["version"] = 2 }, .unsupportedVersion)
        try refuses(changed { $0["vaultID"] = "../escape" }, .invalidFields)
        try refuses(changed { $0["sequence"] = 0 }, .invalidFields)
        try refuses(changed { $0["archiveSHA256"] = String(repeating: "A", count: 64) }, .invalidFields)
        try refuses(Data(repeating: 65, count: 32_769), .malformed)
    }
    func testTamperingAndAnotherSignatureDomainAreRefused() throws {
        var e = try JSONDecoder().decode(OfficeManualAssignment.Envelope.self, from: envelope())
        let raw = try XCTUnwrap(Data(base64Encoded: e.payload))
        let key = try officeFixtureKey()
        let signature = try key.signature(for: Data("Avenkin.Job.v1\0".utf8) + raw)
        e = .init(payload: e.payload, signature: signature.base64EncodedString())
        try refuses(JSONEncoder().encode(e), .badSignature)
        try refuses(JSONEncoder().encode(OfficeManualAssignment.Envelope(payload: (raw + Data(" ".utf8)).base64EncodedString(), signature: e.signature)), .badSignature)
    }
    func testRollbackAndSameSequenceDifferentPayloadAreRefused() throws {
        let v = try OfficeManualAssignment.verify(envelope(), trust: trust(), now: now)
        try refuses(changed { $0["sequence"] = 6 }, .rollback, previous: v.highWater)
        try refuses(changed { $0["vaultVersion"] = "2.0.0" }, .sequenceConflict, previous: v.highWater)
        let newerGeneration = OfficeManualAssignment.HighWater(generation: 2, sequence: 1, payloadSHA256: "")
        try refuses(envelope(), .rollback, previous: newerGeneration)
    }
    func testAmbiguousOrExtendedJSONCannotChangeContractMeaning() throws {
        let e = try JSONDecoder().decode(OfficeManualAssignment.Envelope.self, from: envelope())
        let text = try XCTUnwrap(String(data: XCTUnwrap(Data(base64Encoded: e.payload)), encoding: .utf8))
        let key = try officeFixtureKey()
        let variants = [
            text.replacingOccurrences(of: "\"enrolmentID\":\"fixture-phone\"", with: "\"enrolmentID\":\"foreign\",\"enrolmentID\":\"fixture-phone\""),
            text.replacingOccurrences(of: "\"version\":1", with: "\"version\":1.0"),
            text.replacingOccurrences(of: "\"version\":1", with: "\"version\":1e0"),
            text.replacingOccurrences(of: "\"version\":1", with: "\"version\":01"),
        ]
        for variant in variants {
            XCTAssertNotEqual(variant, text)
            let raw = Data(variant.utf8)
            let sig = try key.signature(for: OfficeManualAssignment.domain + raw)
            try refuses(JSONEncoder().encode(OfficeManualAssignment.Envelope(payload: raw.base64EncodedString(), signature: sig.base64EncodedString())), .malformed)
        }
        try refuses(changed { $0["undeclaredClaim"] = "ignored" }, .malformed)
        let envelopeText = try XCTUnwrap(String(data: envelope(), encoding: .utf8))
        let duplicate = envelopeText.replacingOccurrences(of: "\"payload\":", with: "\"payload\":\"ignored\",\"payload\":")
        try refuses(Data(duplicate.utf8), .malformed)
    }
    func testScopeRetainsHighWaterAcrossOfficeReplacement() throws {
        let v = try OfficeManualAssignment.verify(envelope(), trust: trust(), now: now)
        let replacement = try changed { $0["officeID"] = "replacement-office"; $0["generation"] = 2; $0["sequence"] = 1 }
        let replacementTrust = OfficeManualAssignment.Trust(organizationID: "fixture-org", enrolmentID: "fixture-phone", officeID: "replacement-office", generation: 2, setID: "fixture-set", publicKey: try publicKey(), maximumArchiveBytes: 1_048_576)
        let next = try OfficeManualAssignment.verify(replacement, trust: replacementTrust, now: now, highWater: v.highWater)
        XCTAssertEqual(next.scopeID, v.scopeID)
        XCTAssertFalse(next.isReplay)
    }
}
