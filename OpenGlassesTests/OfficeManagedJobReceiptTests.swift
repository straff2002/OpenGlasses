import CryptoKit
import Foundation
import XCTest
@testable import OpenGlasses

/// The managed-job receipt as the office checks it, against the Go golden fixture.
final class OfficeManagedJobReceiptTests: XCTestCase {
    private let now: Int64 = 1_800_000_000
    private func fixture(_ name: String, extension ext: String) throws -> Data {
        #if SWIFT_PACKAGE
        let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")
        #else
        let url = Bundle(for: Self.self).url(forResource: name, withExtension: ext)
        #endif
        return try Data(contentsOf: XCTUnwrap(url))
    }
    private func keys() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(
            with: fixture("managed-job-fixture-keys", extension: "json")) as? [String: Any])
    }
    private func trust(generation: Int64 = 1) throws -> OfficeManagedJobReceipt.Trust {
        let keys = try keys()
        return try .init(organizationID: "fixture-org", enrolmentID: "fixture-phone",
                         officeID: "fixture-office", generation: generation,
                         phoneTransportID: XCTUnwrap(keys["phoneTransportID"] as? String),
                         phoneApplicationKey: XCTUnwrap(Data(base64Encoded:
                            XCTUnwrap(keys["phoneApplicationKey"] as? String))))
    }
    /// The office's own record of the message: what verifying the golden job gives.
    private func expected() throws -> OfficeManagedJobReceipt.Expected {
        let keys = try keys()
        let job = try OfficeManagedJob.verify(
            fixture("managed-job-v1", extension: "json"),
            trust: .init(organizationID: "fixture-org", enrolmentID: "fixture-phone",
                         officeID: "fixture-office", generation: 1,
                         officeTransportID: XCTUnwrap(keys["officeTransportID"] as? String),
                         phoneTransportID: XCTUnwrap(keys["phoneTransportID"] as? String),
                         officeApplicationKey: XCTUnwrap(Data(base64Encoded:
                            XCTUnwrap(keys["officeApplicationKey"] as? String)))),
            now: now)
        return .init(messageID: job.payload.messageID, sequence: job.payload.sequence,
                     payloadSHA256: job.payloadSHA256, jobSHA256: job.payload.jobSHA256)
    }
    private func receipt() throws -> Data { try fixture("managed-job-receipt-v1", extension: "json") }
    private func payloadBytes() throws -> Data {
        let envelope = try JSONDecoder().decode(OfficeManagedJobReceipt.Envelope.self, from: receipt())
        return try XCTUnwrap(Data(base64Encoded: envelope.payload))
    }
    /// The fictional phone key the fixture generator derives from a public label.
    private func phoneFixtureKey() throws -> Curve25519.Signing.PrivateKey {
        let seed = Data(SHA256.hash(data: Data("Avenkin public fixture phone application key v1".utf8)))
        return try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    }
    private func signed(_ payload: Data) throws -> Data {
        let signature = try phoneFixtureKey().signature(for: OfficeManagedJobReceipt.domain + payload)
        return try JSONEncoder().encode(OfficeManagedJobReceipt.Envelope(
            payload: payload.base64EncodedString(), signature: signature.base64EncodedString()))
    }
    private func changed(_ mutation: (inout [String: Any]) -> Void) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: payloadBytes()) as? [String: Any])
        mutation(&object)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
    private func refuses(_ data: Data, _ refusal: OfficeManagedJobReceipt.Refusal,
                         trust: OfficeManagedJobReceipt.Trust? = nil,
                         expected: OfficeManagedJobReceipt.Expected? = nil,
                         line: UInt = #line) throws {
        XCTAssertThrowsError(try OfficeManagedJobReceipt.verify(
            data, trust: trust ?? self.trust(), expected: expected ?? self.expected()), line: line) {
            XCTAssertEqual($0 as? OfficeManagedJobReceipt.Refusal, refusal, line: line)
        }
    }

    func testGoGoldenReceiptIsForTheGoldenJob() throws {
        let verified = try OfficeManagedJobReceipt.verify(receipt(), trust: trust(), expected: expected())
        XCTAssertEqual(verified.outcome, "received")
        XCTAssertEqual(verified.sequence, 7)
        XCTAssertEqual(verified.receivedAt, 1_800_000_100)
        XCTAssertEqual(try OfficeManagedJobReceipt.payload(payloadBytes()), verified)
        // The fixture phone key is the one the keys file names, so a receipt signed here verifies.
        XCTAssertNoThrow(try OfficeManagedJobReceipt.verify(signed(payloadBytes()), trust: trust(),
                                                           expected: expected()))
    }

    func testAnotherKeyBindingOrMessageIsRefused() throws {
        let other = Curve25519.Signing.PrivateKey()
        let stranger = try JSONEncoder().encode(OfficeManagedJobReceipt.Envelope(
            payload: payloadBytes().base64EncodedString(),
            signature: other.signature(for: OfficeManagedJobReceipt.domain + payloadBytes()).base64EncodedString()))
        try refuses(stranger, .badSignature)
        // Signed under another domain: the phone's key, but not a receipt signature.
        let wrongDomain = try JSONEncoder().encode(OfficeManagedJobReceipt.Envelope(
            payload: payloadBytes().base64EncodedString(),
            signature: phoneFixtureKey().signature(for: OfficeManagedJob.domain + payloadBytes()).base64EncodedString()))
        try refuses(wrongDomain, .badSignature)
        try refuses(receipt(), .wrongBinding, trust: trust(generation: 2))
        let e = try expected()
        try refuses(receipt(), .wrongMessage, expected: .init(
            messageID: "0123456789abcdef0123456789abcdef", sequence: e.sequence,
            payloadSHA256: e.payloadSHA256, jobSHA256: e.jobSHA256))
        try refuses(receipt(), .wrongMessage, expected: .init(
            messageID: e.messageID, sequence: e.sequence,
            payloadSHA256: e.payloadSHA256, jobSHA256: String(repeating: "0", count: 64)))
    }

    func testClosedSchemaAndFieldRules() throws {
        try refuses(signed(changed { $0["extra"] = "ignored" }), .malformed)
        try refuses(signed(changed { $0["outcome"] = "accepted" }), .invalidFields)
        try refuses(signed(changed { $0["receivedAt"] = 0 }), .invalidFields)
        XCTAssertNil(OfficeManagedJobReceipt.payload(try changed { $0["outcome"] = "accepted" }))
        XCTAssertNil(OfficeManagedJobReceipt.payload(try changed { $0["extra"] = 1 }))
        XCTAssertNil(OfficeManagedJobReceipt.payload(try changed { $0["kind"] = "avenkin.managed-job" }))
        XCTAssertNil(OfficeManagedJobReceipt.payload(Data()))
        let duplicate = try XCTUnwrap(String(data: payloadBytes(), encoding: .utf8))
            .replacingOccurrences(of: "\"version\":1", with: "\"version\":1,\"version\":1")
        XCTAssertNil(OfficeManagedJobReceipt.payload(Data(duplicate.utf8)))
    }
}
