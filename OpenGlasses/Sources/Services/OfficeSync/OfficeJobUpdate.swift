import CryptoKit
import Foundation

/// The messages of the job-update contract (Contracts/job-updates.md) as this phone reads and
/// writes them: the office's signed update on a job the phone already has, and the phone's
/// receipt for it.
///
/// Messages only. An update that verifies is information to keep and show against the job it
/// names. It never edits a job, starts one, or is an instruction to anything; its text is the
/// office's words and untrusted content.
enum OfficeJobUpdate {
    static let domain = Data("Avenkin.JobUpdate.v1\0".utf8)
    static let receiptDomain = Data("Avenkin.JobUpdateReceipt.v1\0".utf8)
    static let kind = "avenkin.job-update"
    static let receiptKind = "avenkin.job-update-receipt"
    static let outcomeReceived = "received"
    static let maximumMessageBytes = 16_384
    static let maximumBodyBytes = 4_000
    static let maximumPartBytes = 200
    static let maximumQuantity: Int64 = 1_000_000
    static let maximumLifetime: Int64 = 30 * 86_400
    static let maximumSafeInteger: Int64 = 9_007_199_254_740_991
    static let partStates = ["ordered", "dispatched", "arrived", "substituted", "unavailable"]

    /// The kinds this version defines. Any other well-formed kind word is kept and shown as a note.
    enum UpdateKind: String, Sendable {
        case parts, schedule, note
    }

    /// What the phone held for the job when it committed an update.
    enum JobState: String, Codable, Sendable {
        case held, finished, unknown
    }

    struct Envelope: Codable, Sendable {
        let payload: String
        let signature: String
    }

    /// The closed payload. Every member is always present; one that does not apply is empty or 0.
    struct Update: Codable, Equatable, Sendable {
        let version: Int
        let kind: String
        let updateID: String
        let organizationID: String
        let enrolmentID: String
        let officeID: String
        let generation: Int64
        let officeTransportID: String
        let phoneTransportID: String
        let jobID: String
        let sequence: Int64
        let issuedAt: Int64
        let expiresAt: Int64
        let updateKind: String
        let body: String
        let part: String
        let quantity: Int64
        let partState: String
        let expectedOn: String
        let scheduledFor: Int64
        let scheduledUntil: Int64
    }

    struct Verified: Equatable, Sendable {
        let payload: Update
        /// SHA-256 of the decoded payload bytes: what a receipt names.
        let payloadSHA256: String
    }

    struct Receipt: Codable, Equatable, Sendable {
        let version: Int
        let kind: String
        let updateID: String
        let updateSHA256: String
        let organizationID: String
        let enrolmentID: String
        let officeID: String
        let generation: Int64
        let phoneTransportID: String
        let jobID: String
        let sequence: Int64
        let outcome: String
        let jobState: String
        let receivedAt: Int64
    }

    /// The binding an update is read against. It comes from the pairing gate passing now, never
    /// from the update.
    struct Trust: Equatable, Sendable {
        let organizationID: String
        let enrolmentID: String
        let officeID: String
        let generation: Int64
        let officeTransportID: String
        let phoneTransportID: String
        let officeApplicationKey: Data
    }

    /// Where an arriving update stands to what is held at its job and sequence.
    enum Standing: Equatable, Sendable {
        case new, same, conflict
    }

    enum Refusal: Error, Equatable {
        case malformed
        case badSignature
        case invalidFields
        /// For another organisation, enrolment, office, generation or device.
        case wrongBinding
        /// Not yet issued, or run out. It waits; it is not remembered as refused.
        case notCurrentlyValid
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - The update

    private static let updateFields: Set<String> = [
        "version", "kind", "updateID", "organizationID", "enrolmentID", "officeID", "generation",
        "officeTransportID", "phoneTransportID", "jobID", "sequence", "issuedAt", "expiresAt", "updateKind",
        "body", "part", "quantity", "partState", "expectedOn", "scheduledFor", "scheduledUntil"]

    /// The phone's check of an update (contract §3): signed by the office application key of
    /// the binding held, for exactly that binding, in form, and inside its window.
    static func read(_ data: Data, trust: Trust, now: Int64) throws -> Verified {
        let raw = try open(data, domain: domain, key: trust.officeApplicationKey, fields: updateFields)
        guard let u = try? JSONDecoder().decode(Update.self, from: raw) else { throw Refusal.malformed }
        guard u.organizationID == trust.organizationID, u.enrolmentID == trust.enrolmentID,
              u.officeID == trust.officeID, u.generation == trust.generation,
              u.officeTransportID == trust.officeTransportID,
              u.phoneTransportID == trust.phoneTransportID else { throw Refusal.wrongBinding }
        guard valid(u) else { throw Refusal.invalidFields }
        guard now >= u.issuedAt, now < u.expiresAt else { throw Refusal.notCurrentlyValid }
        return Verified(payload: u, payloadSHA256: digest(raw))
    }

    /// A sequence is taken once: the same bytes again are the same update, other bytes at a held
    /// sequence are a conflict. Order means nothing.
    static func standing(heldSHA256: String?, arriving: Verified) -> Standing {
        guard let heldSHA256 else { return .new }
        return heldSHA256 == arriving.payloadSHA256 ? .same : .conflict
    }

    static func valid(_ u: Update) -> Bool {
        guard u.version == 1, u.kind == kind, hex(u.updateID, count: 32),
              [u.organizationID, u.enrolmentID, u.officeID, u.jobID].allSatisfy(OfficeManualAssignment.safeIdentifier),
              instant(u.generation), canonicalDeviceID(u.officeTransportID), canonicalDeviceID(u.phoneTransportID),
              instant(u.sequence), instant(u.issuedAt), instant(u.expiresAt), u.expiresAt > u.issuedAt,
              u.expiresAt - u.issuedAt <= maximumLifetime, kindWord(u.updateKind) else { return false }
        // Each member by its own rule, whatever the kind.
        guard text(u.body, maximum: maximumBodyBytes, lines: true),
              text(u.part, maximum: maximumPartBytes, lines: false),
              (0...maximumQuantity).contains(u.quantity),
              u.partState.isEmpty || partStates.contains(u.partState),
              u.expectedOn.isEmpty || day(u.expectedOn),
              (0...maximumSafeInteger).contains(u.scheduledFor),
              (0...maximumSafeInteger).contains(u.scheduledUntil),
              u.scheduledUntil == 0 || (u.scheduledFor > 0 && u.scheduledUntil > u.scheduledFor) else { return false }
        let noParts = u.part.isEmpty && u.quantity == 0 && u.partState.isEmpty && u.expectedOn.isEmpty
        let noSchedule = u.scheduledFor == 0 && u.scheduledUntil == 0
        switch UpdateKind(rawValue: u.updateKind) {
        case .note?: return !u.body.isEmpty && noParts && noSchedule
        case .parts?: return !u.part.isEmpty && !u.partState.isEmpty && noSchedule
        case .schedule?: return u.scheduledFor > 0 && noParts
        // A kind this version does not define: kept, and shown as a note.
        case nil: return true
        }
    }

    // MARK: - The receipt

    private static let receiptFields: Set<String> = [
        "version", "kind", "updateID", "updateSHA256", "organizationID", "enrolmentID", "officeID",
        "generation", "phoneTransportID", "jobID", "sequence", "outcome", "jobState", "receivedAt"]

    /// The receipt these exact bytes state, or nil unless they are a closed, flat update receipt
    /// within the field rules. The phone signs nothing else under the receipt domain.
    static func receiptPayload(_ raw: Data) -> Receipt? {
        guard !raw.isEmpty, raw.count <= maximumMessageBytes,
              OfficeManualAssignment.flatObject(raw, keys: receiptFields),
              let r = try? JSONDecoder().decode(Receipt.self, from: raw), valid(r) else { return nil }
        return r
    }

    /// The office's check of a receipt: signed by the phone application key from the binding,
    /// never from the receipt.
    static func receipt(_ data: Data, phoneApplicationKey: Data) throws -> Receipt {
        let raw = try open(data, domain: receiptDomain, key: phoneApplicationKey, fields: receiptFields)
        guard let r = try? JSONDecoder().decode(Receipt.self, from: raw) else { throw Refusal.malformed }
        guard valid(r) else { throw Refusal.invalidFields }
        return r
    }

    private static func valid(_ r: Receipt) -> Bool {
        r.version == 1 && r.kind == receiptKind && hex(r.updateID, count: 32) && hex(r.updateSHA256, count: 64)
            && [r.organizationID, r.enrolmentID, r.officeID, r.jobID].allSatisfy(OfficeManualAssignment.safeIdentifier)
            && instant(r.generation) && canonicalDeviceID(r.phoneTransportID) && instant(r.sequence)
            && r.outcome == outcomeReceived && JobState(rawValue: r.jobState) != nil && instant(r.receivedAt)
    }

    // MARK: - Signed bytes and field rules

    private static func open(_ data: Data, domain: Data, key: Data, fields: Set<String>) throws -> Data {
        guard !data.isEmpty, data.count <= maximumMessageBytes,
              OfficeManualAssignment.flatObject(data, keys: ["payload", "signature"]),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              let raw = Data(base64Encoded: envelope.payload),
              raw.base64EncodedString() == envelope.payload,
              let signature = Data(base64Encoded: envelope.signature), signature.count == 64,
              signature.base64EncodedString() == envelope.signature else { throw Refusal.malformed }
        guard let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: key),
              publicKey.isValidSignature(signature, for: domain + raw) else { throw Refusal.badSignature }
        guard OfficeManualAssignment.flatObject(raw, keys: fields) else { throw Refusal.malformed }
        return raw
    }

    private static func hex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func instant(_ value: Int64) -> Bool { value > 0 && value <= maximumSafeInteger }

    private static func canonicalDeviceID(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        return parts.count == 8 && parts.allSatisfy { part in
            part.utf8.count == 7 && part.utf8.allSatisfy {
                (65...90).contains($0) || (50...55).contains($0)
            }
        }
    }

    /// A lower-case letter, then lower-case letters, digits or hyphens; at most 32 characters.
    static func kindWord(_ value: String) -> Bool {
        guard let first = value.utf8.first, (97...122).contains(first), value.utf8.count <= 32 else { return false }
        return value.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
    }

    /// Text within a byte limit with no control characters, except that a body may have line
    /// feeds. The empty string is text.
    static func text(_ value: String, maximum: Int, lines: Bool) -> Bool {
        guard value.utf8.count <= maximum else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            if scalar.value == 0x0A { return lines }
            return scalar.value >= 0x20 && !(0x7F...0x9F).contains(scalar.value)
                && scalar.value != 0x2028 && scalar.value != 0x2029
        }
    }

    /// A calendar date written `YYYY-MM-DD`.
    static func day(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 10, bytes[4] == 45, bytes[7] == 45 else { return false }
        func number(_ range: Range<Int>) -> Int? {
            var total = 0
            for byte in bytes[range] {
                guard (48...57).contains(byte) else { return nil }
                total = total * 10 + Int(byte - 48)
            }
            return total
        }
        guard let year = number(0..<4), let month = number(5..<7), let dayOfMonth = number(8..<10),
              (1...12).contains(month), dayOfMonth >= 1 else { return false }
        let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
        let lengths = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return dayOfMonth <= lengths[month - 1]
    }
}
