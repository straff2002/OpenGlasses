import CryptoKit
import Foundation

/// The messages of the bulk-content contract (Contracts/office-bulk.md) as this phone reads and
/// writes them: the administrator-signed grant of an organisation's own publishing key, and the
/// phone's receipts for a manual assignment.
///
/// Messages only. The administrator key is the one the vendor-verified profile names, supplied
/// by the caller; a grant carries the publishing key and nothing that says the grant is to be
/// believed. A grant that verifies is not yet a publisher the phone trusts: it is used only to
/// check an archive that a verified assignment from this organisation's office names.
enum OfficeBulk {
    static let grantDomain = Data("Avenkin.OrganisationPublisher.v1\0".utf8)
    static let receiptDomain = Data("Avenkin.ManualAssignmentReceipt.v1\0".utf8)
    static let grantKind = "avenkin.organisation-publisher"
    static let receiptKind = "avenkin.manual-assignment-receipt"
    static let maximumMessageBytes = 4_096
    static let maximumGrantLifetime: Int64 = 400 * 86_400
    static let maximumSafeInteger: Int64 = 9_007_199_254_740_991
    /// Begins every organisation publisher's identifier, followed by the organisation's own.
    static let publisherPrefix = "org."

    enum Status: String, Codable, Sendable {
        case active, revoked
    }

    enum Outcome: String, Codable, Sendable {
        /// The assignment verified and is committed; its archive is not installed.
        case received
        /// The archive it names is verified and installed.
        case installed
    }

    struct Envelope: Codable, Sendable {
        let payload: String
        let signature: String
    }

    struct Grant: Codable, Equatable, Sendable {
        let version: Int
        let kind: String
        let grantID: String
        let organizationID: String
        let profileID: String
        let publisherID: String
        let publisherName: String
        let publisherKey: String
        let sequence: Int64
        let status: String
        let issuedAt: Int64
        let expiresAt: Int64

        /// Whether an active grant may be relied on at `now`, and no later than the profile's
        /// own term.
        func isLive(now: Int64, policyExpiry: Date?) -> Bool {
            status == Status.active.rawValue && now >= issuedAt && now < expiresAt
                && (policyExpiry.map { Date(timeIntervalSince1970: TimeInterval(now)) < $0 } ?? true)
        }
    }

    struct VerifiedGrant: Equatable, Sendable {
        let payload: Grant
        /// SHA-256 of the decoded payload bytes: what is kept with the sequence high-water mark.
        let payloadSHA256: String
    }

    struct Receipt: Codable, Equatable, Sendable {
        let version: Int
        let kind: String
        let assignmentID: String
        let assignmentSHA256: String
        let organizationID: String
        let enrolmentID: String
        let officeID: String
        let generation: Int64
        let phoneTransportID: String
        let setID: String
        let sequence: Int64
        let archiveSHA256: String
        let outcome: String
        let at: Int64
    }

    /// How a grant that has arrived stands to the one held for the same publisher.
    enum Standing: Equatable, Sendable {
        case newer, same, older, conflict
    }

    enum Refusal: Error, Equatable {
        case malformed
        case badSignature
        case invalidFields
        /// For another organisation or profile.
        case wrongOrganisation
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether `publisherID` is one this organisation may grant: `org.` and its own identifier,
    /// alone or followed by a dot and a name of its own.
    static func isOrganisationPublisher(_ publisherID: String, organizationID: String) -> Bool {
        let own = publisherPrefix + organizationID
        return OfficeManualAssignment.safeIdentifier(publisherID)
            && (publisherID == own || publisherID.hasPrefix(own + "."))
    }

    // MARK: - The publisher grant

    private static let grantFields: Set<String> = [
        "version", "kind", "grantID", "organizationID", "profileID", "publisherID", "publisherName",
        "publisherKey", "sequence", "status", "issuedAt", "expiresAt"]

    /// The phone's check of a grant (contract §3): signed by the administrator key from its own
    /// vendor-verified profile, and naming its own organisation and profile. It does not look at
    /// the clock: a revocation is read whenever it arrives.
    static func grant(_ data: Data, administratorKey: Data, organizationID: String,
                      profileID: String) throws -> VerifiedGrant {
        let raw = try open(data, domain: grantDomain, key: administratorKey, fields: grantFields)
        guard let g = try? JSONDecoder().decode(Grant.self, from: raw) else { throw Refusal.malformed }
        guard g.version == 1, g.kind == grantKind, hex(g.grantID, count: 32),
              OfficeManualAssignment.safeIdentifier(g.organizationID),
              OfficeManualAssignment.safeIdentifier(g.profileID),
              isOrganisationPublisher(g.publisherID, organizationID: g.organizationID),
              !g.publisherName.isEmpty, OfficeReport.plain(g.publisherName, maximum: 120),
              let key = Data(base64Encoded: g.publisherKey), key.count == 32,
              key.base64EncodedString() == g.publisherKey,
              instant(g.sequence), Status(rawValue: g.status) != nil,
              instant(g.issuedAt), instant(g.expiresAt), g.expiresAt > g.issuedAt,
              g.expiresAt - g.issuedAt <= maximumGrantLifetime else { throw Refusal.invalidFields }
        guard g.organizationID == organizationID, g.profileID == profileID else { throw Refusal.wrongOrganisation }
        return VerifiedGrant(payload: g, payloadSHA256: digest(raw))
    }

    /// A higher sequence replaces the grant held; the same sequence is the same grant only with
    /// the same bytes; a lower one never replaces a higher.
    static func standing(heldSequence: Int64, heldSHA256: String, arriving: VerifiedGrant) -> Standing {
        if arriving.payload.sequence > heldSequence { return .newer }
        if arriving.payload.sequence < heldSequence { return .older }
        return arriving.payloadSHA256 == heldSHA256 ? .same : .conflict
    }

    // MARK: - The assignment receipt

    private static let receiptFields: Set<String> = [
        "version", "kind", "assignmentID", "assignmentSHA256", "organizationID", "enrolmentID", "officeID",
        "generation", "phoneTransportID", "setID", "sequence", "archiveSHA256", "outcome", "at"]

    /// The receipt these exact bytes state, or nil unless they are a closed, flat assignment
    /// receipt within the field rules. The phone signs nothing else under the receipt domain.
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
        r.version == 1 && r.kind == receiptKind && hex(r.assignmentID, count: 32)
            && hex(r.assignmentSHA256, count: 64)
            && [r.organizationID, r.enrolmentID, r.officeID, r.setID].allSatisfy(OfficeManualAssignment.safeIdentifier)
            && instant(r.generation) && canonicalDeviceID(r.phoneTransportID) && instant(r.sequence)
            && hex(r.archiveSHA256, count: 64) && Outcome(rawValue: r.outcome) != nil && instant(r.at)
    }

    // MARK: - Signed bytes

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
}
