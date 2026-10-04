import CryptoKit
import Foundation
import XCTest
@testable import OpenGlasses

/// The golden fixtures of the check-in contract (Contracts/fixtures/office-check-in-*,
/// office-removal-*), made by the Go reference implementation with the clock at `now`. Every key
/// is derived from a public label (seed = SHA-256(label)) and has no authority, which is what
/// lets a test sign a changed message the way the office or the administrator would.
enum OfficeCheckInFixtures {
    static let now: Int64 = 1_800_000_000

    private final class Anchor {}

    static func data(_ name: String) throws -> Data { try file(name, extension: "json") }

    static func file(_ name: String, extension ext: String) throws -> Data {
        #if SWIFT_PACKAGE
        let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")
        #else
        let url = Bundle(for: Anchor.self).url(forResource: name, withExtension: ext)
        #endif
        return try Data(contentsOf: XCTUnwrap(url, "fixture \(name).\(ext)"))
    }

    static func key(_ label: String) throws -> Curve25519.Signing.PrivateKey {
        try Curve25519.Signing.PrivateKey(rawRepresentation: Data(SHA256.hash(data: Data(label.utf8))))
    }
    static func office() throws -> Curve25519.Signing.PrivateKey { try key("Avenkin public fixture office key v1") }
    static func phone() throws -> Curve25519.Signing.PrivateKey { try key("Avenkin public fixture phone key v1") }
    static func administrator() throws -> Curve25519.Signing.PrivateKey {
        try key("Avenkin public fixture administrator key v1")
    }

    static func envelope(_ data: Data) throws -> OfficeCheckIn.Envelope {
        try JSONDecoder().decode(OfficeCheckIn.Envelope.self, from: data)
    }

    /// The decoded payload of a fixture envelope.
    static func payload(_ name: String) throws -> Data {
        try XCTUnwrap(Data(base64Encoded: envelope(data(name)).payload))
    }

    static func fields(_ payload: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
    }

    /// Exact payload bytes under a signature, written out as the transport writes an envelope.
    static func sealed(_ payload: Data, signature: Data) -> Data {
        Data(#"{"payload":"\#(payload.base64EncodedString())","signature":"\#(signature.base64EncodedString())"}"#.utf8)
    }

    static func signed(_ payload: Data, domain: Data, by key: Curve25519.Signing.PrivateKey) throws -> Data {
        sealed(payload, signature: try key.signature(for: domain + payload))
    }

    /// A fixture message with its payload changed, signed again by `key` under `domain`.
    static func changed(_ name: String, domain: Data, by key: Curve25519.Signing.PrivateKey,
                        _ change: (inout [String: Any]) -> Void) throws -> Data {
        var object = try fields(payload(name))
        change(&object)
        return try signed(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
                          domain: domain, by: key)
    }

    /// The binding the fixture phone holds: generation 1.
    static func held() throws -> OfficeCheckIn.Held {
        let bytes = try payload("office-check-in-binding-v1")
        let b = try fields(bytes)
        func text(_ key: String) throws -> String { try XCTUnwrap(b[key] as? String) }
        return try OfficeCheckIn.Held(
            organizationID: text("organizationID"), profileID: text("profileID"),
            enrolmentID: text("enrolmentID"), officeID: text("officeID"),
            phoneTransportID: text("phoneTransportID"), generation: 1,
            bindingSHA256: OfficeCheckIn.digest(bytes),
            officeApplicationKey: office().publicKey.rawRepresentation,
            phoneApplicationKey: phone().publicKey.rawRepresentation,
            administratorKey: administrator().publicKey.rawRepresentation)
    }

    /// The fixture check-in, as the one the phone is waiting on.
    static func waiting() throws -> OfficeCheckIn.Waiting {
        let held = try held()
        let challenge = try fields(payload("office-check-in-challenge-v1"))
        return try OfficeCheckIn.Waiting(
            challengeID: XCTUnwrap(challenge["challengeID"] as? String),
            checkInSHA256: OfficeCheckIn.digest(data("office-check-in-v1")),
            generation: held.generation, bindingSHA256: held.bindingSHA256)
    }
}
