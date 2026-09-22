import Foundation

/// Consolidated, self-contained audit record for one Field Assist session.
///
/// Reconstructed from `session.json` + `log.jsonl` by `SessionExporter`, this is the artifact
/// exported for compliance use cases — EPA 608 refrigerant logs, warranty submissions, and customer
/// work orders. Unlike the raw append-only log, it's a single denormalized document.
struct SessionExport: Codable, Equatable {
    let sessionId: String
    let startedAt: Date
    let endedAt: Date?
    let vault: String
    let vaultName: String
    let assetId: String?
    /// The machine the session was working on, when it recognised one (Plan EL). Absent — and
    /// printed nowhere — for a session that never identified a unit.
    let equipment: Equipment?
    let mode: String
    let outcome: String
    /// Exact accumulated active time. Optional so older exports still decode.
    let billableSeconds: TimeInterval?
    let billableMinutes: Int
    let billingBasis: FieldAssistBillingBasis?
    let minutesPerBillingUnit: Int?
    let billableUnits: Int?
    let location: Location?
    let transcript: [TranscriptEntry]
    let photos: [PhotoRef]
    /// The job's clips (Plan FO P2b), with what the technician decided about each and how it
    /// travelled. **Optional** for the reason every other field added to this record is: an audit
    /// exported before clips existed has no such key, and the synthesized decoder throws on a
    /// missing key for a non-optional collection. A job with no clips still writes an empty list,
    /// so absence means "an older build wrote this" rather than "this job recorded nothing".
    let clips: [ClipRef]?
    let proceduresRun: [ProcedureRun]
    let captures: [CaptureRun]
    let citations: [Citation]
    let escalations: [EscalationEntry]
    /// What was recommended, what was decided, and what base is being asked for (Plan EM).
    /// Optional so an audit exported before the work record existed still decodes.
    let workRecord: WorkRecord?
    /// Which model wrote the assistant turns in this record, and under which version of the app's
    /// instructions (W08.3). A compliance record that a machine read half of should say so in a
    /// field, not only in prose. Optional so records exported before provenance existed still
    /// decode. Carries a digest of the prompt, never its body, and never a source document's body.
    let provenance: AIProvenance?

    struct Location: Codable, Equatable {
        let latitude: Double
        let longitude: Double
    }

    /// The equipment identity, flattened for the record. The nameplate's own text stays in the
    /// event log where it was written — the work order names the machine, not the plate.
    struct Equipment: Codable, Equatable {
        let model: String
        let heading: String
        /// `EquipmentIdentity.Source` raw value — "spoken", "nameplate", "asset", "manual".
        let source: String
        let recognisedAt: Date

        init(_ identity: EquipmentIdentity) {
            self.model = identity.modelToken
            self.heading = identity.heading
            self.source = identity.source.rawValue
            self.recognisedAt = identity.recognisedAt
        }

        /// "Equipment: SLP99UH090XV60CK — from the nameplate at 14:02".
        var sentence: String {
            let phrase = EquipmentIdentity.Source(rawValue: source)?.provenancePhrase ?? "recorded"
            return "Equipment: \(model) — \(phrase) at \(EquipmentIdentity.clock(recognisedAt))"
        }

        enum CodingKeys: String, CodingKey {
            case model, heading, source
            case recognisedAt = "recognised_at"
        }
    }

    struct TranscriptEntry: Codable, Equatable {
        let timestamp: Date
        let role: String   // "technician" | "assistant"
        let text: String
    }

    struct PhotoRef: Codable, Equatable {
        let timestamp: Date
        let path: String   // relative to the session's photos/ directory
        let caption: String?
        /// Whether the technician chose to send this one with the report (Plan FO P2a).
        ///
        /// **Optional on purpose.** Nil means the review step was never taken, which is a
        /// different fact from "the technician left it out": a job that skipped the review sends
        /// the text-only record, and reading that back as thirty deliberate exclusions would be a
        /// consumer drawing a conclusion nobody reached.
        let included: Bool?
        /// "fault" or "fix", when it was marked. Marking is optional and never prompted, so nil is
        /// the ordinary case rather than missing data.
        let role: String?

        init(timestamp: Date, path: String, caption: String?,
             included: Bool? = nil, role: String? = nil) {
            self.timestamp = timestamp
            self.path = path
            self.caption = caption
            self.included = included
            self.role = role
        }

        /// Hand-written so an audit exported before the evidence review existed still decodes.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            timestamp = try c.decode(Date.self, forKey: .timestamp)
            path = try c.decode(String.self, forKey: .path)
            caption = try c.decodeIfPresent(String.self, forKey: .caption)
            included = try c.decodeIfPresent(Bool.self, forKey: .included)
            role = try c.decodeIfPresent(String.self, forKey: .role)
        }
    }

    /// One clip, as the machine-readable record carries it.
    ///
    /// A clip cannot live inside the PDF, so this is where a receiving system finds out that it
    /// exists, how long it is, what it weighs, whether the technician chose it — and whether it
    /// actually rode along with the report or has to be asked for.
    struct ClipRef: Codable, Equatable {
        let timestamp: Date
        /// The file name inside the session's `photos/` directory.
        let path: String
        let caption: String?
        let durationSeconds: TimeInterval?
        let bytes: Int?
        /// Whether the technician chose to send it. Nil when the review was never taken — the same
        /// distinction `PhotoRef.included` draws, and for the same reason.
        let included: Bool?
        /// "fault" or "fix", when it was marked.
        let role: String?
        /// Whether it actually travelled with the report on the channel it was sent by. False with
        /// `included == true` means it was over that channel's size budget and was offered through
        /// the share sheet instead. Nil when no channel had been chosen — an export taken for the
        /// archive rather than for a send.
        let attached: Bool?
        /// Why it did not ride along, in plain words.
        let notAttachedReason: String?
        /// Whether the recording ended before the technician asked it to.
        let cutShort: Bool

        enum CodingKeys: String, CodingKey {
            case timestamp, path, caption, bytes, included, role, attached
            case durationSeconds = "duration_seconds"
            case notAttachedReason = "not_attached_reason"
            case cutShort = "cut_short"
        }

        init(timestamp: Date, path: String, caption: String?, durationSeconds: TimeInterval?,
             bytes: Int?, included: Bool?, role: String?, attached: Bool?,
             notAttachedReason: String?, cutShort: Bool) {
            self.timestamp = timestamp
            self.path = path
            self.caption = caption
            self.durationSeconds = durationSeconds
            self.bytes = bytes
            self.included = included
            self.role = role
            self.attached = attached
            self.notAttachedReason = notAttachedReason
            self.cutShort = cutShort
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            timestamp = try c.decode(Date.self, forKey: .timestamp)
            path = try c.decode(String.self, forKey: .path)
            caption = try c.decodeIfPresent(String.self, forKey: .caption)
            durationSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .durationSeconds)
            bytes = try c.decodeIfPresent(Int.self, forKey: .bytes)
            included = try c.decodeIfPresent(Bool.self, forKey: .included)
            role = try c.decodeIfPresent(String.self, forKey: .role)
            attached = try c.decodeIfPresent(Bool.self, forKey: .attached)
            notAttachedReason = try c.decodeIfPresent(String.self, forKey: .notAttachedReason)
            cutShort = try c.decodeIfPresent(Bool.self, forKey: .cutShort) ?? false
        }
    }

    struct ProcedureRun: Codable, Equatable {
        let procedureId: String
        let stepsCompleted: Int
        let outcome: String?   // nil if the procedure was left in progress
    }

    /// A finished capture-flow record (Plan U) reconstructed from its `capture_record` audit event.
    struct CaptureRun: Codable, Equatable {
        let timestamp: Date
        let flowId: String
        let assetId: String?
        let fields: [Field]

        struct Field: Codable, Equatable {
            let field: String
            let value: String    // human-readable rendering (`CaptureValue.display`)
            let method: String   // provenance — "voice" | "voice_number" | "enum" | "photo" | "barcode" | "ocr"
        }

        enum CodingKeys: String, CodingKey {
            case timestamp, fields
            case flowId = "flow_id"
            case assetId = "asset_id"
        }
    }

    /// One source an answer cited, and what the technician did about it (Plan EK P3).
    ///
    /// The double trust a manufacturer's SOP asks for is the answer *and* the page: an export that
    /// listed only what was cited could not tell a reviewer whether anybody looked.
    struct Citation: Codable, Equatable {
        let timestamp: Date
        let source: String
        let claim: String?
        /// Whether the technician opened this citation during the session.
        let opened: Bool
        /// How it was opened — "chip" (tapped under the answer) or "voice" (asked for).
        let origin: String?
        /// Which document the page was read in: "manufacturer_pdf", "extracted_text",
        /// "external_url", or several, in the order they were opened. Nil when none was.
        let verifiedAgainst: String?

        init(timestamp: Date, source: String, claim: String?,
             opened: Bool = false, origin: String? = nil, verifiedAgainst: String? = nil) {
            self.timestamp = timestamp
            self.source = source
            self.claim = claim
            self.opened = opened
            self.origin = origin
            self.verifiedAgainst = verifiedAgainst
        }

        enum CodingKeys: String, CodingKey {
            case timestamp, source, claim, opened, origin
            case verifiedAgainst = "verified_against"
        }

        /// Hand-written so an audit exported before P3 still decodes — an old record simply has
        /// nothing to say about whether its citations were opened.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            timestamp = try c.decode(Date.self, forKey: .timestamp)
            source = try c.decode(String.self, forKey: .source)
            claim = try c.decodeIfPresent(String.self, forKey: .claim)
            opened = try c.decodeIfPresent(Bool.self, forKey: .opened) ?? false
            origin = try c.decodeIfPresent(String.self, forKey: .origin)
            verifiedAgainst = try c.decodeIfPresent(String.self, forKey: .verifiedAgainst)
        }
    }

    struct EscalationEntry: Codable, Equatable {
        let timestamp: Date
        let reason: String
    }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case vault
        case vaultName = "vault_name"
        case assetId = "asset_id"
        case equipment
        case mode, outcome
        case billableSeconds = "billable_seconds"
        case billableMinutes = "billable_minutes"
        case billingBasis = "billing_basis"
        case minutesPerBillingUnit = "minutes_per_unit"
        case billableUnits = "billable_units"
        case location, transcript, photos, clips
        case proceduresRun = "procedures_run"
        case captures, citations, escalations
        case workRecord = "work_record"
        case provenance = "ai_provenance"
    }
}
