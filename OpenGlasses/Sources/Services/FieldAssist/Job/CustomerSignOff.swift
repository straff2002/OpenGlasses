import CryptoKit
import Foundation

/// What the customer put their name to at the end of the job (Plan FO P2c).
///
/// This is a **record of acceptance**, not an e-signature service. What makes it worth anything is
/// not the drawing — a finger on a phone proves very little on its own — but the fact that the
/// record says, and can prove, *exactly which words were on the screen* when the name was written.
/// That is what `summaryLines` and `summaryDigest` are for: the lines are kept verbatim and the
/// digest is taken over them, so a record whose summary was edited afterwards can be told apart
/// from one that was not.
///
/// The summary is **frozen at the moment of signing**. A debrief addendum (Plan FO §6/P3b) is a
/// second document; it never rewrites what a customer agreed to.
struct CustomerSignOff: Codable, Equatable {

    /// How the acceptance was given. Three answers, and the app never guesses between them.
    enum Method: String, Codable, CaseIterable {
        /// A signature was drawn on the phone.
        case drawn
        /// The customer could not sign and typed their name instead. A different fact, recorded
        /// as a different fact.
        case typed
        /// The customer declined to sign at all. Recorded with a reason when the organisation
        /// requires sign-off, because "they said no" is the answer the record has to carry.
        case declined

        /// What the record prints and the page reads out.
        var label: String {
            switch self {
            case .drawn: return "Signed on the technician's phone"
            case .typed: return "Name typed on the technician's phone"
            case .declined: return "The customer declined to sign"
            }
        }
    }

    /// The customer's name as they gave it. Never normalised, for the same reason a job number is
    /// not: it is what they wrote.
    let customerName: String
    /// One line the customer chose to add, or nil.
    let comment: String?
    let signedAt: Date
    let method: Method
    /// Why, when the customer declined and the organisation asked for a reason.
    let declinedReason: String?
    /// The summary that was on the screen, word for word. Kept rather than re-derived: the record
    /// has to be able to show what was agreed to even after the work record around it has moved on.
    let summaryLines: [String]
    /// `sha256:<hex>` over those lines. Cheap to check, and it makes "the summary was altered" a
    /// provable statement rather than an argument.
    let summaryDigest: String
    /// The drawing, as a file beside the job's photographs. Nil for a typed or declined sign-off.
    let signatureImageId: String?
    /// The `PKDrawing` data for the same strokes, filed beside the picture. Kept because a
    /// flattened PNG cannot be re-rendered at another size and a drawing can.
    let strokeDataId: String?

    enum CodingKeys: String, CodingKey {
        case customerName = "customer_name"
        case comment
        case signedAt = "signed_at"
        case method
        case declinedReason = "declined_reason"
        case summaryLines = "summary_lines"
        case summaryDigest = "summary_digest"
        case signatureImageId = "signature_image"
        case strokeDataId = "signature_strokes"
    }

    init(customerName: String, comment: String? = nil, signedAt: Date = Date(),
         method: Method, declinedReason: String? = nil, summaryLines: [String],
         signatureImageId: String? = nil, strokeDataId: String? = nil) {
        self.customerName = customerName
        self.comment = comment.flatMap { $0.isEmpty ? nil : $0 }
        self.signedAt = signedAt
        self.method = method
        self.declinedReason = declinedReason.flatMap { $0.isEmpty ? nil : $0 }
        self.summaryLines = summaryLines
        self.summaryDigest = Self.digest(of: summaryLines)
        self.signatureImageId = signatureImageId
        self.strokeDataId = strokeDataId
    }

    /// Hand-written so a record written before any of this existed still decodes — the same rule
    /// `WorkRecord` and `FieldSession` already follow, and for the same reason.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        customerName = try c.decodeIfPresent(String.self, forKey: .customerName) ?? ""
        comment = try c.decodeIfPresent(String.self, forKey: .comment)
        signedAt = try c.decode(Date.self, forKey: .signedAt)
        method = try c.decodeIfPresent(Method.self, forKey: .method) ?? .typed
        declinedReason = try c.decodeIfPresent(String.self, forKey: .declinedReason)
        summaryLines = try c.decodeIfPresent([String].self, forKey: .summaryLines) ?? []
        summaryDigest = try c.decodeIfPresent(String.self, forKey: .summaryDigest) ?? ""
        signatureImageId = try c.decodeIfPresent(String.self, forKey: .signatureImageId)
        strokeDataId = try c.decodeIfPresent(String.self, forKey: .strokeDataId)
    }

    /// The same acceptance, once its files are on disk. The digest is unchanged by construction:
    /// it is taken over the summary, and the summary has not moved.
    func filed(imageId: String?, strokeDataId: String?) -> CustomerSignOff {
        CustomerSignOff(customerName: customerName, comment: comment, signedAt: signedAt,
                        method: method, declinedReason: declinedReason, summaryLines: summaryLines,
                        signatureImageId: imageId, strokeDataId: strokeDataId)
    }

    // MARK: - The digest

    /// `sha256:<hex>` over the lines joined by newlines, in the order they were shown.
    static func digest(of lines: [String]) -> String {
        let hash = SHA256.hash(data: Data(lines.joined(separator: "\n").utf8))
        return "sha256:" + hash.map { String(format: "%02x", $0) }.joined()
    }

    /// Whether the digest still matches the lines the record carries.
    var digestMatchesSummary: Bool { summaryDigest == Self.digest(of: summaryLines) }

    /// Whether the customer accepted at all. A declined sign-off is a recorded answer, not an
    /// acceptance, and nothing in the report may read as though it were one.
    var isAccepted: Bool { method != .declined }

    // MARK: - How it reads

    /// The block heading the work order prints and the past job's page shows.
    static let blockTitle = "Customer acceptance"

    /// The sentence that says what this is and, deliberately, what it is not.
    static let disclaimer =
        "Recorded on the technician's phone at the end of the job. It is a record of what the "
        + "customer agreed to, not a legal e-signature."

    /// "Signed by Dana Okafor · 22 September 2026 at 15:04" — one line, for the page and the PDF.
    func attributionLine(formatter: DateFormatter = CustomerSignOff.defaultFormatter) -> String {
        let name = customerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let who = name.isEmpty ? "No name given" : name
        return "\(who) · \(formatter.string(from: signedAt))"
    }

    static let defaultFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        return formatter
    }()
}

/// The customer's half of the record: what was done, what it took, and how long (Plan FO P2c).
///
/// **This did not exist before.** The work order prints `WorkRecord.summaryLines` whole, which
/// carries the technician's completion notes, why each task was recommended, escalations, the
/// manual pages verified and the evidence counts — all of it internal, and none of it something a
/// customer should be asked to put their name to. So the customer summary is a derivation of its
/// own, with an allow-list shape rather than a deny-list one: it names the three things the plan
/// says belong on the sheet and can only ever print those.
///
/// Pure, and deliberately so: the sheet, the digest, the PDF block and the JSON all read the same
/// lines, so they cannot disagree about what was agreed to.
enum CustomerSummary {

    /// The lines exactly as the sheet shows them and the digest is taken over.
    static func lines(for record: WorkRecord) -> [String] {
        var lines: [String] = []

        // 1. Work done. Completed tasks only, by title — the *why*, the completion note, the
        //    procedure and the evidence counts all stay behind.
        let done = record.tasks(status: .done)
        if done.isEmpty {
            lines.append("Work done: nothing was recorded as completed on this visit.")
        } else {
            lines.append("Work done:")
            lines.append(contentsOf: done.map { "  \($0.title)" })
        }

        // 2. Parts used — what came off the van, which is what a customer is billed for. The
        //    number and what it is, and nothing else: `TaskPart.summary` also carries whether the
        //    number was verified and which manual page it was found on, which is the technician's
        //    provenance and not a customer's business.
        let parts = record.partsUsed
        if parts.isEmpty {
            lines.append("Parts used: none.")
        } else {
            lines.append("Parts used:")
            lines.append(contentsOf: parts.map { part in
                let description = part.partDescription.flatMap { $0.isEmpty ? nil : $0 }
                return "  " + (description.map { "\(part.number) (\($0))" } ?? part.number)
            })
        }

        // 3. Time, or billing units where the organisation bills in them. The record's own
        //    fields, so the sheet and the invoice cannot disagree.
        if record.billingBasis == .units, let units = record.billableUnits {
            lines.append("Billable units: \(WorkRecord.unitPhrase(units)).")
        } else {
            lines.append("Time on the job: \(record.durationPhrase).")
        }
        return lines
    }

    /// The summary as one block, which is what the digest is taken over.
    static func text(for record: WorkRecord) -> String {
        lines(for: record).joined(separator: "\n")
    }
}

/// Whether a job may close without a customer's signature (Plan FO P2c).
///
/// One pure decision with one input beyond the sign-off itself, so the rule is provable without a
/// session, a screen or a preference: an organisation that requires sign-off gets a close that is
/// blocked until the customer has either signed or explicitly declined with a reason.
enum SignOffPolicy {

    enum Decision: Equatable {
        case allowed
        /// The close is held, with the sentence the technician is shown.
        case blocked(String)

        var isAllowed: Bool { self == .allowed }
    }

    /// The wording for the held case. Stated once so the step, the button's hint and the test all
    /// name the same rule.
    static let blockedReason =
        "Your organisation asks for the customer's sign-off on every job. Hand the phone over, or "
        + "record that the customer declined and why."

    static func decide(signOff: CustomerSignOff?, required: Bool) -> Decision {
        guard required else { return .allowed }
        guard let signOff else { return .blocked(blockedReason) }
        switch signOff.method {
        case .drawn, .typed:
            return .allowed
        case .declined:
            // A decline is an acceptable answer, but only a *stated* one: "the customer refused"
            // with no reason is indistinguishable from nobody having asked.
            let reason = signOff.declinedReason?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (reason?.isEmpty == false) ? .allowed : .blocked(blockedReason)
        }
    }
}
