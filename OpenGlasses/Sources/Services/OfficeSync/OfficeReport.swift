import CryptoKit
import Foundation

/// The messages of the office report contract (Contracts/office-reports.md) as this phone writes
/// and reads them: the report it signs for one record, the attachment manifest that report names
/// by digest, and the office's signed receipts.
///
/// Messages only. Every key is the caller's — the phone and office application keys from a
/// binding verified just now — and never one a message carries. A receipt that verifies here says
/// how much of one report the office has committed; what the phone does about it is
/// `OfficeReportService`'s.
enum OfficeReport {
    static let reportDomain = Data("Avenkin.OfficeReport.v1\0".utf8)
    static let receiptDomain = Data("Avenkin.OfficeReportReceipt.v1\0".utf8)

    static let reportKind = "avenkin.office-report"
    static let manifestKind = "avenkin.office-report-manifest"
    static let receiptKind = "avenkin.office-report-receipt"

    static let maximumReportBytes = 8_192
    static let maximumReceiptBytes = 8_192
    static let maximumRecordBytes = 1_048_576
    static let maximumManifestBytes = 131_072
    static let maximumAttachments = 256
    static let maximumSafeInteger: Int64 = 9_007_199_254_740_991

    /// What a report carries.
    enum RecordKind: String, Codable, Sendable {
        case workRecord, partsRequest, addendum
    }

    /// Where the transcript is: an attachment for the office, kept on the phone by the
    /// organisation's policy, or not there to send.
    enum Transcript: String, Codable, Sendable {
        case attached, omitted, none
    }

    enum Role: String, Codable, Sendable, CaseIterable {
        case workOrder, auditExport, transcript, photo, clip, clipPoster, signature, addendum
    }

    enum Requirement: String, Codable, Sendable {
        case required, optional
    }

    /// Who may see an attachment: the organisation's own eyes only, or the customer too.
    enum Audience: String, Codable, Sendable {
        case office, customer
    }

    static let mediaTypes: Set<String> = [
        "application/pdf", "application/json", "image/jpeg", "image/png", "video/mp4", "video/quicktime"]

    /// How much of a report the office has committed. Later cases follow earlier ones.
    enum Outcome: String, Codable, Sendable, Comparable {
        case evidencePending, recordAccepted, fullyAccepted

        /// The word in the receipt's file name.
        var stage: String {
            switch self {
            case .evidencePending: return "pending"
            case .recordAccepted: return "record"
            case .fullyAccepted: return "full"
            }
        }

        private var rank: Int {
            switch self {
            case .evidencePending: return 0
            case .recordAccepted: return 1
            case .fullyAccepted: return 2
            }
        }

        static func < (lhs: Outcome, rhs: Outcome) -> Bool { lhs.rank < rhs.rank }
    }

    struct Envelope: Codable, Sendable {
        let payload: String
        let signature: String
    }

    /// The phone's statement that one record, at one revision, is exactly these bytes with
    /// exactly this evidence. Flat: the record and the manifest are separate files it names.
    struct Report: Codable, Equatable, Sendable {
        let version: Int
        let kind: String
        let reportID: String
        let operationID: String
        let recordKind: String
        let recordID: String
        let revision: Int64
        let organizationID: String
        let enrolmentID: String
        let officeID: String
        let phoneTransportID: String
        let jobReference: String
        let jobID: String
        let jobRevision: Int64
        let recordSHA256: String
        let recordBytes: Int64
        let manifestSHA256: String
        let manifestBytes: Int64
        let transcript: String
        let createdAt: Int64
    }

    struct Attachment: Codable, Equatable, Sendable {
        let sha256: String
        let bytes: Int64
        let role: String
        let mediaType: String
        let name: String
        let requirement: String
        let audience: String
    }

    struct Receipt: Codable, Equatable, Sendable {
        let version: Int
        let kind: String
        let reportID: String
        let reportSHA256: String
        let recordSHA256: String
        let manifestSHA256: String
        let organizationID: String
        let enrolmentID: String
        let officeID: String
        let phoneTransportID: String
        let outcome: String
        let attachmentsCommitted: Int64
        let attachmentsOutstanding: Int64
        let receivedAt: Int64
    }

    /// The pairing a report is sent under, from a binding verified just now.
    struct Identity: Equatable, Sendable {
        let organizationID: String
        let enrolmentID: String
        let officeID: String
        let phoneTransportID: String
    }

    enum Refusal: Error, Equatable {
        case malformed
        case badSignature
        case invalidFields
        /// For another pairing, report, record or manifest.
        case wrongReport
    }

    /// Lower-case hexadecimal SHA-256 of exact bytes.
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The identifier in a report's file name: the digest of its operation identifier.
    static func reportID(operationID: String) -> String { digest(Data(operationID.utf8)) }

    // MARK: - Report

    private static let reportFields: Set<String> = [
        "version", "kind", "reportID", "operationID", "recordKind", "recordID", "revision",
        "organizationID", "enrolmentID", "officeID", "phoneTransportID", "jobReference", "jobID",
        "jobRevision", "recordSHA256", "recordBytes", "manifestSHA256", "manifestBytes", "transcript",
        "createdAt"]

    /// A report for exact record and manifest bytes, or nil when a field is outside the
    /// contract's rules. `jobID` and `jobRevision` come together or not at all.
    static func report(operationID: String, recordKind: RecordKind, recordID: String, revision: Int64,
                       identity: Identity, jobReference: String, jobID: String, jobRevision: Int64,
                       record: Data, manifest: Data, transcript: Transcript, createdAt: Int64) -> Report? {
        let report = Report(
            version: 1, kind: reportKind, reportID: reportID(operationID: operationID),
            operationID: operationID, recordKind: recordKind.rawValue, recordID: recordID, revision: revision,
            organizationID: identity.organizationID, enrolmentID: identity.enrolmentID,
            officeID: identity.officeID, phoneTransportID: identity.phoneTransportID,
            jobReference: jobReference, jobID: jobID, jobRevision: jobRevision,
            recordSHA256: digest(record), recordBytes: Int64(record.count),
            manifestSHA256: digest(manifest), manifestBytes: Int64(manifest.count),
            transcript: transcript.rawValue, createdAt: createdAt)
        return valid(report) ? report : nil
    }

    /// The exact bytes the phone signs: the members in the contract's order, with no whitespace.
    /// Every string is drawn from an alphabet that needs no escape, so they have one spelling.
    static func payloadBytes(_ r: Report) -> Data? {
        guard valid(r) else { return nil }
        let members: [String] = [
            #""version":\#(r.version)"#, #""kind":"\#(r.kind)""#, #""reportID":"\#(r.reportID)""#,
            #""operationID":"\#(r.operationID)""#, #""recordKind":"\#(r.recordKind)""#,
            #""recordID":"\#(r.recordID)""#, #""revision":\#(r.revision)"#,
            #""organizationID":"\#(r.organizationID)""#, #""enrolmentID":"\#(r.enrolmentID)""#,
            #""officeID":"\#(r.officeID)""#, #""phoneTransportID":"\#(r.phoneTransportID)""#,
            #""jobReference":"\#(r.jobReference)""#, #""jobID":"\#(r.jobID)""#,
            #""jobRevision":\#(r.jobRevision)"#, #""recordSHA256":"\#(r.recordSHA256)""#,
            #""recordBytes":\#(r.recordBytes)"#, #""manifestSHA256":"\#(r.manifestSHA256)""#,
            #""manifestBytes":\#(r.manifestBytes)"#, #""transcript":"\#(r.transcript)""#,
            #""createdAt":\#(r.createdAt)"#,
        ]
        return Data(("{" + members.joined(separator: ",") + "}").utf8)
    }

    /// The report these exact bytes state, or nil unless they are a closed, flat report payload
    /// within the field rules. The phone signs nothing else under the report domain.
    static func reportPayload(_ raw: Data) -> Report? {
        guard !raw.isEmpty, raw.count <= maximumReportBytes,
              OfficeManualAssignment.flatObject(raw, keys: reportFields),
              let report = try? JSONDecoder().decode(Report.self, from: raw), valid(report) else { return nil }
        return report
    }

    /// A published report read back: a closed envelope signed, over its exact payload bytes, by
    /// the phone application key the binding names, and naming this pairing.
    static func report(_ data: Data, phoneApplicationKey: Data, identity: Identity) throws -> Report {
        let raw = try open(data, domain: reportDomain, key: phoneApplicationKey, fields: reportFields,
                           limit: maximumReportBytes)
        guard let report = try? JSONDecoder().decode(Report.self, from: raw) else { throw Refusal.malformed }
        guard valid(report) else { throw Refusal.invalidFields }
        guard report.organizationID == identity.organizationID, report.enrolmentID == identity.enrolmentID,
              report.officeID == identity.officeID,
              report.phoneTransportID == identity.phoneTransportID else { throw Refusal.wrongReport }
        return report
    }

    private static func valid(_ r: Report) -> Bool {
        r.version == 1 && r.kind == reportKind && hex(r.reportID, count: 64)
            && OfficeManualAssignment.safeIdentifier(r.operationID)
            && r.reportID == reportID(operationID: r.operationID)
            && RecordKind(rawValue: r.recordKind) != nil
            && OfficeManualAssignment.safeIdentifier(r.recordID) && instant(r.revision)
            && [r.organizationID, r.enrolmentID, r.officeID].allSatisfy(OfficeManualAssignment.safeIdentifier)
            && canonicalDeviceID(r.phoneTransportID) && plain(r.jobReference, maximum: 120)
            && ((r.jobID.isEmpty && r.jobRevision == 0)
                || (OfficeManualAssignment.safeIdentifier(r.jobID) && instant(r.jobRevision)))
            && hex(r.recordSHA256, count: 64) && r.recordBytes > 0 && r.recordBytes <= Int64(maximumRecordBytes)
            && hex(r.manifestSHA256, count: 64) && r.manifestBytes > 0
            && r.manifestBytes <= Int64(maximumManifestBytes)
            && Transcript(rawValue: r.transcript) != nil && instant(r.createdAt)
    }

    // MARK: - Manifest

    /// A manifest's one spelling: members in the contract's order, attachments in ascending order
    /// of digest, no whitespace and no escape. Nil when an attachment is outside the rules or a
    /// digest appears twice.
    static func manifestBytes(_ attachments: [Attachment]) -> Data? {
        let sorted = attachments.sorted { $0.sha256 < $1.sha256 }
        guard sorted.count <= maximumAttachments, sorted.allSatisfy({ valid($0) }),
              zip(sorted, sorted.dropFirst()).allSatisfy({ $0.sha256 < $1.sha256 }) else { return nil }
        let entries = sorted.map { a in
            "{" + [
                #""sha256":"\#(a.sha256)""#, #""bytes":\#(a.bytes)"#, #""role":"\#(a.role)""#,
                #""mediaType":"\#(a.mediaType)""#, #""name":"\#(a.name)""#,
                #""requirement":"\#(a.requirement)""#, #""audience":"\#(a.audience)""#,
            ].joined(separator: ",") + "}"
        }
        let text = #"{"version":1,"kind":"\#(manifestKind)","attachments":["# + entries.joined(separator: ",") + "]}"
        let data = Data(text.utf8)
        return data.count <= maximumManifestBytes ? data : nil
    }

    /// The attachments a manifest lists, or nil unless the bytes are exactly the canonical bytes
    /// of a valid manifest.
    static func manifest(_ raw: Data) -> [Attachment]? {
        struct Manifest: Decodable {
            let version: Int
            let kind: String
            let attachments: [Attachment]
        }
        guard !raw.isEmpty, raw.count <= maximumManifestBytes,
              let manifest = try? JSONDecoder().decode(Manifest.self, from: raw),
              manifest.version == 1, manifest.kind == manifestKind,
              manifestBytes(manifest.attachments) == raw else { return nil }
        return manifest.attachments
    }

    /// Whether a report and a manifest agree about where the transcript is.
    static func transcriptAgrees(_ report: Report, attachments: [Attachment]) -> Bool {
        attachments.contains { $0.role == Role.transcript.rawValue } == (report.transcript == Transcript.attached.rawValue)
    }

    private static func valid(_ a: Attachment) -> Bool {
        hex(a.sha256, count: 64) && instant(a.bytes) && Role(rawValue: a.role) != nil
            && mediaTypes.contains(a.mediaType) && fileName(a.name)
            && Requirement(rawValue: a.requirement) != nil && Audience(rawValue: a.audience) != nil
            // A transcript is never the customer's.
            && (a.role != Role.transcript.rawValue || a.audience == Audience.office.rawValue)
    }

    // MARK: - Receipt

    private static let receiptFields: Set<String> = [
        "version", "kind", "reportID", "reportSHA256", "recordSHA256", "manifestSHA256", "organizationID",
        "enrolmentID", "officeID", "phoneTransportID", "outcome", "attachmentsCommitted",
        "attachmentsOutstanding", "receivedAt"]

    /// The phone's check of a receipt (contract §8): signed by the office application key its
    /// verified binding names; for exactly the report it published — the identifier, the message
    /// digest of the envelope, the record and the manifest; naming its own identities; and with
    /// counts that are possible for that manifest.
    static func receipt(_ data: Data, officeApplicationKey: Data, reportEnvelope: Data, report: Report,
                        attachments: [Attachment]) throws -> (receipt: Receipt, outcome: Outcome) {
        let raw = try open(data, domain: receiptDomain, key: officeApplicationKey, fields: receiptFields,
                           limit: maximumReceiptBytes)
        guard let r = try? JSONDecoder().decode(Receipt.self, from: raw) else { throw Refusal.malformed }
        guard r.version == 1, r.kind == receiptKind, hex(r.reportID, count: 64), hex(r.reportSHA256, count: 64),
              hex(r.recordSHA256, count: 64), hex(r.manifestSHA256, count: 64),
              [r.organizationID, r.enrolmentID, r.officeID].allSatisfy(OfficeManualAssignment.safeIdentifier),
              canonicalDeviceID(r.phoneTransportID), let outcome = Outcome(rawValue: r.outcome),
              r.attachmentsCommitted >= 0, r.attachmentsOutstanding >= 0,
              r.attachmentsCommitted + r.attachmentsOutstanding <= Int64(maximumAttachments),
              (outcome == .fullyAccepted) == (r.attachmentsOutstanding == 0),
              instant(r.receivedAt) else { throw Refusal.invalidFields }
        guard r.reportID == report.reportID, r.reportSHA256 == digest(reportEnvelope),
              r.recordSHA256 == report.recordSHA256, r.manifestSHA256 == report.manifestSHA256,
              r.organizationID == report.organizationID, r.enrolmentID == report.enrolmentID,
              r.officeID == report.officeID,
              r.phoneTransportID == report.phoneTransportID else { throw Refusal.wrongReport }
        let total = Int64(attachments.count)
        let optional = Int64(attachments.filter { $0.requirement == Requirement.optional.rawValue }.count)
        guard r.attachmentsCommitted + r.attachmentsOutstanding == total,
              // Record accepted: every required attachment is in, so only optional ones are out.
              outcome != .recordAccepted || r.attachmentsOutstanding <= optional,
              // Evidence pending: a required attachment is out, so there must be one.
              outcome != .evidencePending || optional < total else { throw Refusal.invalidFields }
        return (r, outcome)
    }

    // MARK: - Signed bytes

    private static func open(_ data: Data, domain: Data, key: Data, fields: Set<String>,
                             limit: Int) throws -> Data {
        guard !data.isEmpty, data.count <= limit,
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

    /// Printable ASCII that needs no JSON escape, so it has one spelling.
    static func plain(_ value: String, maximum: Int) -> Bool {
        value.utf8.count <= maximum && value.utf8.allSatisfy {
            $0 >= 0x20 && $0 < 0x7F && ![0x22, 0x5C, 0x3C, 0x3E, 0x26].contains($0)
        }
    }

    /// A display name: an identifier of up to 120 characters that does not begin with a dot.
    static func fileName(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 120, value.utf8.first != 0x2E else { return false }
        return value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0)
            || (97...122).contains($0) || $0 == 45 || $0 == 95 || $0 == 46 }
    }

    private static func canonicalDeviceID(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        return parts.count == 8 && parts.allSatisfy { part in
            part.utf8.count == 7 && part.utf8.allSatisfy {
                (65...90).contains($0) || (50...55).contains($0)
            }
        }
    }
}

extension OfficeReport {
    /// The envelope the transport writes for a payload and its signature: the two members in
    /// that order, with no whitespace. Base64 needs no escape, so it has one spelling.
    static func envelopeBytes(payload: Data, signature: Data) -> Data {
        Data(#"{"payload":"\#(payload.base64EncodedString())","signature":"\#(signature.base64EncodedString())"}"#.utf8)
    }
}
