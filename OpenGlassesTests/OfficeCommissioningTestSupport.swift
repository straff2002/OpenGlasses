import CryptoKit
import Foundation
import XCTest
@testable import OpenGlasses

/// The public commissioning fixtures (Contracts/fixtures/commission-*), read from the checkout.
enum CommissionFixtures {
    // `#filePath` is fixed at compile time, so it resolves the same on a developer machine and CI.
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    static func text(_ name: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent("Contracts/fixtures/\(name)"), encoding: .utf8)
    }

    static func keys() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text("commission-fixture-keys.json").utf8))
            as? [String: Any])
    }

    /// The decoded payload of a fixture envelope.
    static func payload(_ name: String) throws -> Data {
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text(name).utf8)) as? [String: Any])
        return try XCTUnwrap(Data(base64Encoded: XCTUnwrap(envelope["payload"] as? String)))
    }

    static func digest(_ envelope: String) -> String {
        SHA256.hash(data: Data(envelope.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Contract §2.3, written out independently of the transport: the fake answers with it, and
    /// the fixture pins it.
    static func comparison(invitationSHA256: String, redemptionSHA256: String) -> String {
        func raw(_ hex: String) -> Data {
            var bytes = Data()
            var index = hex.startIndex
            while index < hex.endIndex {
                let next = hex.index(index, offsetBy: 2)
                bytes.append(UInt8(hex[index..<next], radix: 16)!)
                index = next
            }
            return bytes
        }
        let sum = Array(SHA256.hash(data: Data("Avenkin.CommissionComparison.v1\0".utf8)
                                    + raw(invitationSHA256) + raw(redemptionSHA256)))
        var bits: UInt64 = 0
        for byte in sum.prefix(8) { bits = bits << 8 | UInt64(byte) }
        let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        var out = ""
        for n in 0..<12 {
            if n > 0 && n % 4 == 0 { out.append("-") }
            out.append(alphabet[Int((bits >> (59 - 5 * UInt64(n))) & 31)])
        }
        return out
    }
}

/// A stand-in for the pinned Go connection. It builds real redemption payloads (so the phone's
/// purpose-bound signer accepts them), checks the phone's signature when sealing, and answers the
/// exchange from a script.
actor FakeCommissionTransport: OfficeCommissionTransport {
    struct SigningRequest: Equatable {
        let enrolmentID: String
        let phoneTransportID: String
        let phoneApplicationKey: String
        let existingEnrolment: String
    }

    enum Failure: Error { case unreadable, network, badSignature }

    private let invitationJSON: String?
    private var answers: [Result<String, Error>]
    private let whenOutOfAnswers: String
    private(set) var readCount = 0
    private(set) var signingRequests: [SigningRequest] = []
    private(set) var sealedRedemptions: [String] = []
    private(set) var exchangedRedemptions: [String] = []

    init(invitation: String?, answers: [Result<String, Error>],
         whenOutOfAnswers: String = #"{"status":"awaiting"}"#) {
        invitationJSON = invitation
        self.answers = answers
        self.whenOutOfAnswers = whenOutOfAnswers
    }

    func queue(_ more: [Result<String, Error>]) { answers.append(contentsOf: more) }

    func readQR(_ qrText: String, now: Int64) async throws -> String {
        readCount += 1
        guard let invitationJSON else { throw Failure.unreadable }
        return invitationJSON
    }

    func redemptionSigningInput(invitationEnvelope: String, enrolmentID: String,
                                phoneTransportID: String, phoneApplicationKey: String,
                                appVersion: String, appBuild: String,
                                existingEnrolment: String, now: Int64) async throws -> String {
        signingRequests.append(.init(enrolmentID: enrolmentID, phoneTransportID: phoneTransportID,
                                     phoneApplicationKey: phoneApplicationKey,
                                     existingEnrolment: existingEnrolment))
        let payload = try JSONSerialization.data(withJSONObject: [
            "version": 1, "kind": "avenkin.commission-redemption",
            "invitationSHA256": CommissionFixtures.digest(invitationEnvelope),
            "invitation": "fake-invitation", "enrolmentID": enrolmentID,
            "phoneTransportID": phoneTransportID, "phoneApplicationKey": phoneApplicationKey,
            "appVersion": appVersion, "appBuild": appBuild, "existingEnrolment": existingEnrolment,
            "createdAt": now,
        ], options: [.sortedKeys])
        let signingInput = OfficeCommissioningFlow.redemptionDomain + payload
        let json = try JSONSerialization.data(withJSONObject: [
            "payload": payload.base64EncodedString(), "signingInput": signingInput.base64EncodedString(),
        ])
        return String(decoding: json, as: UTF8.self)
    }

    func sealRedemption(invitationEnvelope: String, payloadBase64: String,
                        signatureBase64: String) async throws -> String {
        guard let payload = Data(base64Encoded: payloadBase64),
              let signature = Data(base64Encoded: signatureBase64),
              let fields = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let keyText = fields["phoneApplicationKey"] as? String,
              let key = Data(base64Encoded: keyText),
              let verifier = try? Curve25519.Signing.PublicKey(rawRepresentation: key),
              verifier.isValidSignature(signature, for: OfficeCommissioningFlow.redemptionDomain + payload) else {
            throw Failure.badSignature
        }
        let envelope = #"{"payload":"\#(payloadBase64)","signature":"\#(signatureBase64)"}"#
        sealedRedemptions.append(envelope)
        return envelope
    }

    func comparison(invitationEnvelope: String, redemptionEnvelope: String) async throws -> String {
        CommissionFixtures.comparison(invitationSHA256: CommissionFixtures.digest(invitationEnvelope),
                                      redemptionSHA256: CommissionFixtures.digest(redemptionEnvelope))
    }

    func exchange(invitationEnvelope: String, redemptionEnvelope: String) async throws -> String {
        exchangedRedemptions.append(redemptionEnvelope)
        guard !answers.isEmpty else { return whenOutOfAnswers }
        return try answers.removeFirst().get()
    }
}

/// A clock a test moves by hand.
final class CommissionTestClock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}

@MainActor
func waitForStage(_ service: OfficeCommissioningService, timeout: TimeInterval = 3,
                  file: StaticString = #filePath, line: UInt = #line,
                  _ predicate: (OfficeCommissioningService.Stage) -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !predicate(service.stage) {
        if Date() > deadline {
            XCTFail("stage stayed \(service.stage)", file: file, line: line)
            return
        }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
}
