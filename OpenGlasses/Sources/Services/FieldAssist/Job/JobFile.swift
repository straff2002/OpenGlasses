import Foundation
import CryptoKit

/// A job that arrives as a file — `.ogjob`, attached to an email by the office (Plan FO §8, P3c).
///
/// A small JSON document. It **proposes** an upcoming job and does nothing else: it cannot start a
/// job, change equipment, create a task or send anything, and nothing is saved until the technician
/// taps *Add to upcoming jobs* on the review sheet. The format is receive-only; the app never
/// writes one out.
///
/// ```json
/// {
///   "format": "openglasses.job",
///   "format_version": 1,
///   "job_reference": "1007",
///   "site": { "customer": "Smith & Co", "address": "14 Smith Street", "contact": "Jo, 021 555 0100" },
///   "fault_report": "No heat. Display shows E200.",
///   "equipment": [ { "model": "SLP99UH090XV60CK", "serial": "5919K01234" } ],
///   "scheduled_for": "2026-09-25T09:00:00Z",
///   "notes": "Side gate code 4411.",
///   "attachments": [ { "name": "Previous invoice", "reference": "INV-2231" } ],
///   "issued_by": "Smith Refrigeration Ltd",
///   "signature": { "algorithm": "ed25519", "value": "<base64>" }
/// }
/// ```
///
/// The signature covers the canonical encoding of everything except `signature` itself
/// (`Body.canonicalData()`: sorted keys, slashes unescaped) — a re-encoding rather than the file's
/// bytes, so an office system and this phone agree however the JSON was laid out on the way.
/// The key is the **organisation's**, from its CT profile, never the vendor's content key.
struct JobFile: Equatable {

    static let format = "openglasses.job"
    static let formatVersion = 1
    static let fileExtension = "ogjob"
    static let typeIdentifier = "com.openglasses.app.job"
    /// A job is a few hundred bytes. Anything near this is not a job.
    static let maximumBytes = 64 * 1024

    struct Site: Codable, Equatable {
        let customer: String?
        let address: String?
        let contact: String?
    }

    struct Equipment: Codable, Equatable {
        let model: String?
        let serial: String?
    }

    /// Named, never embedded. The app does not fetch it.
    struct Attachment: Codable, Equatable {
        let name: String
        let reference: String?
    }

    /// Everything the signature covers.
    struct Body: Codable, Equatable {
        let format: String
        let formatVersion: Int
        let jobReference: String?
        let site: Site?
        let faultReport: String?
        let equipment: [Equipment]?
        let scheduledFor: String?
        let notes: String?
        let attachments: [Attachment]?
        /// Who the file *says* issued it. Shown only as a claim; the signer on the record is the
        /// organisation whose key verified it, never this.
        let issuedBy: String?

        enum CodingKeys: String, CodingKey {
            case format
            case formatVersion = "format_version"
            case jobReference = "job_reference"
            case site
            case faultReport = "fault_report"
            case equipment
            case scheduledFor = "scheduled_for"
            case notes, attachments
            case issuedBy = "issued_by"
        }

        /// The bytes the signature covers.
        func canonicalData() throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return try encoder.encode(self)
        }
    }

    struct Signature: Codable, Equatable {
        let algorithm: String
        let value: String
    }

    let body: Body
    let signature: Signature?

    /// The scheduled time, when the file gave one it could parse (the validator refuses one it
    /// cannot).
    var scheduledDate: Date? { body.scheduledFor.flatMap(JobFileValidator.parseDate) }

    /// The job ahead this file proposes. Fields the office left out stay empty.
    func upcomingJob(provenance: JobFileProvenance, id: String = UUID().uuidString,
                     createdAt: Date = Date()) -> UpcomingJob {
        UpcomingJob(
            id: id,
            jobReference: body.jobReference,
            site: JobSite(customer: body.site?.customer, address: body.site?.address,
                          contact: body.site?.contact),
            faultReport: body.faultReport.map {
                FaultReport(text: $0, source: .jobFile, receivedAt: provenance.receivedAt)
            },
            equipment: (body.equipment ?? []).map { KnownEquipment(model: $0.model, serial: $0.serial) },
            scheduledFor: scheduledDate,
            notes: body.notes,
            attachments: (body.attachments ?? []).map { attachment in
                attachment.reference.map { "\(attachment.name) (\($0))" } ?? attachment.name
            },
            origin: .jobFile,
            provenance: provenance,
            createdAt: createdAt)
    }

    /// SHA-256 of the bytes that were opened, lowercase hex.
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Validation

/// Schema, size and content checks, before anything is shown. Pure.
///
/// Strict on purpose: a field this version does not know is refused rather than ignored, because a
/// file that carries something the app cannot show is a file whose review sheet would not be the
/// whole truth. A new field is a new `format_version`.
enum JobFileValidator {

    enum Refusal: Error, Equatable {
        case tooLarge(Int)
        case notAJobFile
        case unsupportedVersion(Int)
        case unexpectedField(String)
        case wrongType(String)
        case tooLong(String)
        case containsMarkup(String)
        case notPlainText(String)
        case tooMany(String)
        case embeddedAttachment
        case badDate
        case malformedSignature
        case empty

        /// What the review sheet says. Plain, and never the file's own words.
        var message: String {
            switch self {
            case .tooLarge:
                return "This file is too large to be a job. Job files are a few kilobytes."
            case .notAJobFile:
                return "This isn't an OpenGlasses job file."
            case .unsupportedVersion(let version):
                return "This job file uses format version \(version), which this version of the app can't read. Update the app, or ask the office for a version 1 file."
            case .unexpectedField(let name):
                return "This job file carries a field the app doesn't recognise (\u{201C}\(name)\u{201D}), so it wasn't opened."
            case .wrongType(let name), .notPlainText(let name):
                return "The job file's \u{201C}\(name)\u{201D} isn't plain text, so it wasn't opened."
            case .tooLong(let name):
                return "The job file's \u{201C}\(name)\u{201D} is too long for a job, so it wasn't opened."
            case .containsMarkup(let name):
                return "The job file's \u{201C}\(name)\u{201D} contains markup. Job files are plain text only, so it wasn't opened."
            case .tooMany(let name):
                return "The job file lists too many \(name) for one job, so it wasn't opened."
            case .embeddedAttachment:
                return "The job file tries to carry an attachment inside it. Attachments are named, never embedded, so it wasn't opened."
            case .badDate:
                return "The job file's booking time can't be read, so it wasn't opened."
            case .malformedSignature:
                return "The job file's signature is malformed, so it wasn't opened."
            case .empty:
                return "The job file has no job number, site or fault report — there's nothing to add."
            }
        }
    }

    /// Length caps, in characters.
    static let limits: [String: Int] = [
        "job_reference": 64,
        "customer": 120,
        "address": 240,
        "contact": 160,
        "fault_report": 1_000,
        "notes": 1_000,
        "model": 64,
        "serial": 64,
        "name": 120,
        "reference": 240,
        "issued_by": 120,
        "scheduled_for": 40,
    ]
    /// The two fields a sentence with a line break in it belongs in.
    static let multilineFields: Set<String> = ["fault_report", "notes"]
    static let maximumEquipment = 10
    static let maximumAttachments = 10

    private static let topLevelKeys: Set<String> = [
        "format", "format_version", "job_reference", "site", "fault_report", "equipment",
        "scheduled_for", "notes", "attachments", "issued_by", "signature",
    ]

    static func validate(_ data: Data) -> Result<JobFile, Refusal> {
        guard data.count <= JobFile.maximumBytes else { return .failure(.tooLarge(data.count)) }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              root["format"] as? String == JobFile.format else {
            return .failure(.notAJobFile)
        }
        guard let version = root["format_version"] as? Int else { return .failure(.notAJobFile) }
        guard version == JobFile.formatVersion else { return .failure(.unsupportedVersion(version)) }
        if let unknown = root.keys.sorted().first(where: { !topLevelKeys.contains($0) }) {
            return .failure(.unexpectedField(unknown))
        }

        do {
            try checkText(root, "job_reference")
            try checkText(root, "fault_report")
            try checkText(root, "notes")
            try checkText(root, "issued_by")
            try checkText(root, "scheduled_for")
            if let site = root["site"] {
                guard let site = site as? [String: Any] else { throw Refusal.wrongType("site") }
                try checkKeys(site, allowed: ["customer", "address", "contact"])
                for key in ["customer", "address", "contact"] { try checkText(site, key) }
            }
            if let equipment = root["equipment"] {
                guard let list = equipment as? [Any] else { throw Refusal.wrongType("equipment") }
                guard list.count <= maximumEquipment else { throw Refusal.tooMany("machines") }
                for entry in list {
                    guard let unit = entry as? [String: Any] else { throw Refusal.wrongType("equipment") }
                    try checkKeys(unit, allowed: ["model", "serial"])
                    try checkText(unit, "model")
                    try checkText(unit, "serial")
                }
            }
            if let attachments = root["attachments"] {
                guard let list = attachments as? [Any] else { throw Refusal.wrongType("attachments") }
                guard list.count <= maximumAttachments else { throw Refusal.tooMany("attachments") }
                for entry in list {
                    guard let attachment = entry as? [String: Any],
                          attachment["name"] is String else { throw Refusal.wrongType("attachments") }
                    try checkKeys(attachment, allowed: ["name", "reference"])
                    try checkText(attachment, "name")
                    try checkText(attachment, "reference")
                    if let reference = attachment["reference"] as? String,
                       reference.lowercased().hasPrefix("data:") {
                        throw Refusal.embeddedAttachment
                    }
                }
            }
            if let scheduled = root["scheduled_for"] as? String, parseDate(scheduled) == nil {
                throw Refusal.badDate
            }
            if let signature = root["signature"] {
                guard let signature = signature as? [String: Any],
                      signature["algorithm"] as? String == "ed25519",
                      let value = signature["value"] as? String, value.count <= 200,
                      Set(signature.keys) == ["algorithm", "value"] else {
                    throw Refusal.malformedSignature
                }
            }
        } catch let refusal as Refusal {
            return .failure(refusal)
        } catch {
            return .failure(.notAJobFile)
        }

        let decoder = JSONDecoder()
        guard let body = try? decoder.decode(JobFile.Body.self, from: data) else {
            return .failure(.notAJobFile)
        }
        let signature = (root["signature"] as? [String: Any]).flatMap { raw -> JobFile.Signature? in
            guard let algorithm = raw["algorithm"] as? String, let value = raw["value"] as? String else { return nil }
            return JobFile.Signature(algorithm: algorithm, value: value)
        }
        let hasSite = [body.site?.customer, body.site?.address, body.site?.contact]
            .contains { JobSite.cleaned($0) != nil }
        guard JobIntakeState.cleaned(body.jobReference) != nil || hasSite
                || JobSite.cleaned(body.faultReport) != nil else {
            return .failure(.empty)
        }
        return .success(JobFile(body: body, signature: signature))
    }

    /// ISO 8601, with or without fractional seconds.
    static func parseDate(_ value: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: value) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value)
    }

    /// Whether a string reads as markup: a tag (`<b>`, `</p>`, `<!--`, `<?xml`) or an entity
    /// (`&amp;`, `&#60;`). A bare "<" — "pressure < 20 psi" — is left alone.
    static func containsMarkup(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        for (index, scalar) in scalars.enumerated() {
            if scalar == "<", index + 1 < scalars.count {
                let next = scalars[index + 1]
                if CharacterSet.letters.contains(next) || next == "/" || next == "!" || next == "?" {
                    return true
                }
            }
            if scalar == "&" {
                var cursor = index + 1
                var sawName = false
                while cursor < scalars.count, cursor - index <= 10 {
                    let c = scalars[cursor]
                    if c == ";" { if sawName { return true }; break }
                    guard CharacterSet.alphanumerics.contains(c) || c == "#" else { break }
                    sawName = true
                    cursor += 1
                }
            }
        }
        return false
    }

    private static func checkKeys(_ object: [String: Any], allowed: Set<String>) throws {
        if let unknown = object.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw Refusal.unexpectedField(unknown)
        }
    }

    private static func checkText(_ object: [String: Any], _ key: String) throws {
        guard let value = object[key] else { return }
        if value is NSNull { return }
        guard let text = value as? String else { throw Refusal.wrongType(key) }
        if let limit = limits[key], text.count > limit { throw Refusal.tooLong(key) }
        if containsMarkup(text) { throw Refusal.containsMarkup(key) }
        let allowsBreaks = multilineFields.contains(key)
        for scalar in text.unicodeScalars where CharacterSet.controlCharacters.contains(scalar) {
            if allowsBreaks, scalar == "\n" || scalar == "\t" { continue }
            throw Refusal.notPlainText(key)
        }
    }
}

// MARK: - Signature

/// Whether a job file is signed by the organisation this phone belongs to. Pure; the key is handed
/// in, so every outcome is a test with an ephemeral pair.
enum JobFileSignatureCheck {

    enum Outcome: Equatable {
        /// Verified against the organisation's key.
        case signed(organisation: String)
        /// No signature at all.
        case unsigned
        /// Signed, but this phone has no organisation key to check it with.
        case unverifiable
        /// Signed, and the signature does not match the contents. Never overridable.
        case invalid
    }

    static func check(_ file: JobFile, organisationKey: String, organisationName: String) -> Outcome {
        guard let signature = file.signature else { return .unsigned }
        let trimmedKey = organisationKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty,
              let keyData = Data(base64Encoded: trimmedKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
            return .unverifiable
        }
        guard let signatureData = Data(base64Encoded: signature.value),
              let message = try? file.body.canonicalData(),
              key.isValidSignature(signatureData, for: message) else {
            return .invalid
        }
        let name = organisationName.trimmingCharacters(in: .whitespacesAndNewlines)
        return .signed(organisation: name.isEmpty ? "your organisation" : name)
    }

    /// Office/test side only — the app holds no private key. Here so the tests and
    /// `Scripts/make-job-file.swift` build the same message `check` verifies.
    static func sign(_ body: JobFile.Body, privateKeyBase64: String) throws -> JobFile.Signature {
        guard let keyData = Data(base64Encoded: privateKeyBase64) else { throw SigningError.badKey }
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: keyData)
        let value = try key.signature(for: body.canonicalData()).base64EncodedString()
        return JobFile.Signature(algorithm: "ed25519", value: value)
    }

    enum SigningError: Error { case badKey }
}

// MARK: - Policy

/// Who may add an unsigned job file (Plan FO §8). The shape `VaultLinkInstallPolicy` uses, for the
/// same two reasons: medical mode refuses unsigned content outright, and an organisation profile
/// may require its signature everywhere.
struct JobFileImportPolicy: Equatable {

    enum UnsignedRule: Equatable {
        case allowed
        case forbiddenByMedicalMode
        case forbiddenByOrganisation
    }

    let unsigned: UnsignedRule

    static func resolve(medicalMode: Bool, organisationRequiresSigned: Bool) -> JobFileImportPolicy {
        if medicalMode { return JobFileImportPolicy(unsigned: .forbiddenByMedicalMode) }
        if organisationRequiresSigned { return JobFileImportPolicy(unsigned: .forbiddenByOrganisation) }
        return JobFileImportPolicy(unsigned: .allowed)
    }

    @MainActor
    static func current() -> JobFileImportPolicy {
        resolve(medicalMode: Config.hipaaMode,
                organisationRequiresSigned: Config.organizationRequiresSignedJobFiles)
    }

    enum Decision: Equatable {
        case offer(JobFileProvenance.Signature, signer: String?)
        case refuse(String)
    }

    func decide(_ outcome: JobFileSignatureCheck.Outcome) -> Decision {
        switch outcome {
        case .signed(let organisation):
            return .offer(.signed, signer: organisation)
        case .invalid:
            return .refuse("This job file's signature doesn't match what's in it — it may have been changed after it was signed. Ask the office to send it again.")
        case .unsigned, .unverifiable:
            let signature: JobFileProvenance.Signature = outcome == .unsigned ? .unsigned : .unverifiable
            switch unsigned {
            case .allowed:
                return .offer(signature, signer: nil)
            case .forbiddenByMedicalMode:
                return .refuse("Medical mode only accepts job files signed by your organisation. This one isn't, so it can't be added.")
            case .forbiddenByOrganisation:
                return .refuse("Your organisation only accepts job files it has signed. This one isn't, so it can't be added.")
            }
        }
    }
}

// MARK: - Review

/// What the review sheet shows, decided without SwiftUI. Nothing is created until its one button
/// is tapped, and a job number already on this phone is a question, never a silent overwrite.
struct JobFileReview: Equatable, Identifiable {

    struct Line: Equatable, Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }

    /// The job ahead the file would add, fully formed so accepting it writes exactly this.
    let proposed: UpcomingJob
    let lines: [Line]
    let signatureLine: String
    let isSigned: Bool
    /// A job ahead with the same number, when there is one.
    let duplicate: UpcomingJob?
    /// Who the file says issued it, when that is not the verified signer. Shown as a claim.
    let claimedIssuer: String?

    var id: String { proposed.id }

    var duplicateQuestion: String? {
        guard let duplicate else { return nil }
        return "\(duplicate.title) is already on this phone. Update it with this file, or keep both?"
    }

    static func make(file: JobFile, provenance: JobFileProvenance,
                     existing: [UpcomingJob], now: Date = Date()) -> JobFileReview {
        let job = file.upcomingJob(provenance: provenance, createdAt: now)
        var lines: [Line] = [Line(label: "Job number", value: job.jobReference ?? JobTabModel.noJobNumber)]
        if let customer = job.site.customer { lines.append(Line(label: "Customer", value: customer)) }
        if let address = job.site.address { lines.append(Line(label: "Address", value: address)) }
        if let contact = job.site.contact { lines.append(Line(label: "Contact", value: contact)) }
        if let fault = job.faultReport { lines.append(Line(label: "Fault report", value: fault.text)) }
        if !job.equipment.isEmpty {
            lines.append(Line(label: "Equipment", value: job.equipment.map(\.summary).joined(separator: "\n")))
        }
        if let scheduled = job.scheduledFor {
            lines.append(Line(label: "Booked for", value: scheduled.formatted(date: .abbreviated, time: .shortened)))
        }
        if let notes = job.notes { lines.append(Line(label: "Notes", value: notes)) }
        if !job.attachments.isEmpty {
            lines.append(Line(label: "Attachments (not included)", value: job.attachments.joined(separator: "\n")))
        }

        let signatureLine: String
        switch provenance.signature {
        case .signed:
            signatureLine = "Signed by \(provenance.signer ?? "your organisation")."
        case .unsigned:
            signatureLine = "Not signed — check it came from your office before adding it."
        case .unverifiable:
            signatureLine = "Signed, but this phone has no organisation key to check it with — treat it as not signed and check it came from your office."
        }
        let claimed = JobSite.cleaned(file.body.issuedBy)
        let duplicate = job.jobReference.flatMap { reference in
            existing.first { $0.jobReference == reference }
        }
        return JobFileReview(proposed: job, lines: lines, signatureLine: signatureLine,
                             isSigned: provenance.signature == .signed, duplicate: duplicate,
                             claimedIssuer: claimed == provenance.signer ? nil : claimed)
    }
}

/// What the technician chose on the review sheet.
enum JobFileDecision: Equatable {
    /// No duplicate: add it.
    case add
    /// Replace the job ahead with this number, keeping its place in the list.
    case update
    /// Add it beside the one already there.
    case keepBoth
}
