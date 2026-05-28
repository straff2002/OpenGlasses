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
    let mode: String
    let outcome: String
    let billableMinutes: Int
    let location: Location?
    let transcript: [TranscriptEntry]
    let photos: [PhotoRef]
    let proceduresRun: [ProcedureRun]
    let citations: [Citation]
    let escalations: [EscalationEntry]

    struct Location: Codable, Equatable {
        let latitude: Double
        let longitude: Double
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

    struct Citation: Codable, Equatable {
        let timestamp: Date
        let source: String
        let claim: String?
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
        case mode, outcome
        case billableMinutes = "billable_minutes"
        case location, transcript, photos
        case proceduresRun = "procedures_run"
        case citations, escalations
    }
}
