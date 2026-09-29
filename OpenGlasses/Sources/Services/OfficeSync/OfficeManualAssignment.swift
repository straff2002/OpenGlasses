import CryptoKit
import Foundation

/// FX1 draft contract. The caller supplies trust established by commissioning, never a key
/// from the message or transport connection. Production commissioning is not wired yet.
enum OfficeManualAssignment {
    static let domain = Data("Avenkin.ManualAssignment.v1\0".utf8)
    static let maximumEnvelopeBytes = 32_768
    static let maximumSafeInteger: Int64 = 9_007_199_254_740_991

    struct Payload: Codable, Equatable, Sendable {
        let version: Int
        let kind: String
        let assignmentID: String
        let organizationID: String
        let enrolmentID: String
        let officeID: String
        let generation: Int64
        let setID: String
        let sequence: Int64
        let issuedAt: Int64
        let expiresAt: Int64
        let vaultID: String
        let vaultVersion: String
        let publisherID: String
        let archiveSHA256: String
        let archiveBytes: Int64
    }

    struct Envelope: Codable {
        let payload: String
        let signature: String
    }

    struct Trust: Sendable {
        let organizationID: String
        let enrolmentID: String
        let officeID: String
        let generation: Int64
        let setID: String
        let publicKey: Data
        let maximumArchiveBytes: Int64
    }

    /// Retain outside installed vaults, including after uninstall. Supplied only for this
    /// organization/enrolment/set scope. The durable commit store is a later integration gate.
    struct HighWater: Codable, Equatable, Sendable {
        let generation: Int64
        let sequence: Int64
        let payloadSHA256: String
    }

    struct Verified: Sendable {
        let payload: Payload
        let payloadSHA256: String
        let isReplay: Bool
        fileprivate init(payload: Payload, payloadSHA256: String, isReplay: Bool) {
            self.payload = payload
            self.payloadSHA256 = payloadSHA256
            self.isReplay = isReplay
        }
        var highWater: HighWater {
            HighWater(generation: payload.generation, sequence: payload.sequence,
                      payloadSHA256: payloadSHA256)
        }
        /// Does not expose a transport address or capability URL.
        var scopeID: String {
            let fields = [payload.organizationID, payload.enrolmentID, payload.setID]
            return Self.digest(Data(fields.joined(separator: "\0").utf8))
        }
        private static func digest(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }

    enum Refusal: Error, Equatable {
        case malformed
        case badSignature
        case unsupportedVersion
        case wrongRecipientOrAuthority
        case invalidFields
        case notCurrentlyValid
        case exceedsPolicy
        case rollback
        case sequenceConflict
    }

    /// Signature covers the exact decoded payload bytes, without re-encoding JSON. This is
    /// deliberately a different domain from profiles, jobs, publisher archives and receipts.
    static func verify(_ data: Data, trust: Trust, now: Int64,
                       highWater: HighWater? = nil) throws -> Verified {
        guard data.count <= maximumEnvelopeBytes,
              flatObject(data, keys: ["payload", "signature"]),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              let bytes = Data(base64Encoded: envelope.payload),
              let signature = Data(base64Encoded: envelope.signature) else { throw Refusal.malformed }
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: trust.publicKey),
              key.isValidSignature(signature, for: domain + bytes) else { throw Refusal.badSignature }
        guard flatObject(bytes, keys: ["version", "kind", "assignmentID", "organizationID", "enrolmentID",
              "officeID", "generation", "setID", "sequence", "issuedAt", "expiresAt", "vaultID",
              "vaultVersion", "publisherID", "archiveSHA256", "archiveBytes"]),
              let p = try? JSONDecoder().decode(Payload.self, from: bytes) else { throw Refusal.malformed }
        guard p.version == 1, p.kind == "avenkin.manual-assignment" else { throw Refusal.unsupportedVersion }
        guard p.organizationID == trust.organizationID, p.enrolmentID == trust.enrolmentID,
              p.officeID == trust.officeID, p.generation == trust.generation,
              p.setID == trust.setID else { throw Refusal.wrongRecipientOrAuthority }
        guard [p.organizationID, p.enrolmentID, p.officeID, p.setID, p.vaultID, p.publisherID].allSatisfy(safeIdentifier),
              isHex(p.assignmentID, count: 32), isHex(p.archiveSHA256, count: 64),
              !p.vaultVersion.isEmpty, p.vaultVersion.utf8.count <= 80,
              p.vaultVersion.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7e }),
              p.generation > 0, p.generation <= maximumSafeInteger,
              p.sequence > 0, p.sequence <= maximumSafeInteger,
              p.issuedAt > 0, p.expiresAt > p.issuedAt, p.expiresAt <= maximumSafeInteger,
              p.archiveBytes > 0, p.archiveBytes <= maximumSafeInteger else { throw Refusal.invalidFields }
        guard now >= p.issuedAt, now < p.expiresAt else { throw Refusal.notCurrentlyValid }
        guard p.archiveBytes <= trust.maximumArchiveBytes else { throw Refusal.exceedsPolicy }
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        var replay = false
        if let previous = highWater {
            guard p.generation >= previous.generation else { throw Refusal.rollback }
            if p.generation == previous.generation {
                guard p.sequence >= previous.sequence else { throw Refusal.rollback }
                if p.sequence == previous.sequence {
                    guard digest == previous.payloadSHA256 else { throw Refusal.sequenceConflict }
                    replay = true
                }
            }
        }
        return Verified(payload: p, payloadSHA256: digest, isReplay: replay)
    }

    /// v1 is a flat, closed schema. Reject duplicate/unknown keys and non-integer number
    /// spellings before platform decoders can give ambiguous input different meanings.
    static func flatObject(_ data: Data, keys expected: Set<String>) -> Bool {
        let b = Array(data)
        var i = 0
        func whitespace() { while i < b.count && [9, 10, 13, 32].contains(b[i]) { i += 1 } }
        func take(_ byte: UInt8) -> Bool {
            whitespace()
            guard i < b.count, b[i] == byte else { return false }
            i += 1
            return true
        }
        func stringToken() -> Data? {
            whitespace()
            let start = i
            guard i < b.count, b[i] == 34 else { return nil }
            i += 1
            while i < b.count {
                let c = b[i]
                i += 1
                if c == 34 { return Data(b[start..<i]) }
                if c == 92 {
                    guard i < b.count else { return nil }
                    i += 1
                }
            }
            return nil
        }
        guard take(123) else { return false }
        var seen = Set<String>()
        while true {
            guard let token = stringToken(), let key = try? JSONDecoder().decode(String.self, from: token),
                  expected.contains(key), seen.insert(key).inserted, take(58) else { return false }
            whitespace()
            guard i < b.count else { return false }
            if b[i] == 34 {
                guard stringToken() != nil else { return false }
            } else {
                let start = i
                if b[i] == 45 { i += 1 }
                let digitStart = i
                while i < b.count && (48...57).contains(b[i]) { i += 1 }
                guard i > digitStart, !(b[digitStart] == 48 && i - digitStart > 1), let number = String(bytes: b[start..<i], encoding: .utf8),
                      Int64(number) != nil else { return false }
            }
            whitespace()
            guard i < b.count else { return false }
            if b[i] == 125 { i += 1; break }
            guard take(44) else { return false }
        }
        whitespace()
        return i == b.count && seen == expected
    }

    static func safeIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 80, value != ".", value != ".." else { return false }
        return value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0)
            || (97...122).contains($0) || $0 == 45 || $0 == 95 || $0 == 46 }
    }

    private static func isHex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
