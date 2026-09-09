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
    let billableMinutes: Int
    let location: Location?
    let transcript: [TranscriptEntry]
    let photos: [PhotoRef]
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
        case billableMinutes = "billable_minutes"
        case location, transcript, photos
        case proceduresRun = "procedures_run"
        case captures, citations, escalations
        case workRecord = "work_record"
        case provenance = "ai_provenance"
    }
}
