import Foundation

/// What a queued operation does when it eventually reaches the network (Plan T).
enum OpKind: String, Codable {
    case logEntry       // a structured step/observation — durable locally, sync-only
    case photoUpload    // a captured photo on disk → upload when online
    case llmGrounding   // a question asked offline → answer when back online
    case auditExport    // generate / upload the session audit export
    case captureRecord  // a finished capture-flow record (Plan U) — typed so a networked sink can route it
    case workRecord     // the deterministic record of one visit (Plan EM) — what base is sent at the end
    case partsRequest   // a stock check (Plan EM) — leaves on its own, before the job is finished
}

/// Where an operation is in its lifecycle.
enum OpState: String, Codable {
    case pending    // waiting to be sent
    case inFlight   // currently being delivered
    case done       // delivered (a tombstone until purged)
    case conflict   // server state diverged while offline — needs attention
    case failed     // exhausted retries / permanent error
}

/// One durable unit of work in the offline queue. Everything a technician does on site lands
/// here **synchronously and locally first**; the network is always a background concern.
struct QueuedOp: Identifiable, Codable, Equatable {
    let id: String
    let kind: OpKind
    let sessionId: String
    var payload: Data        // JSON; for photos, a file path + sidecar metadata
    let createdAt: Date      // device clock — drives strict FIFO ordering + conflict detection
    var attempts: Int
    var state: OpState

    init(id: String = UUID().uuidString,
         kind: OpKind,
         sessionId: String,
         payload: Data = Data(),
         createdAt: Date = Date(),
         attempts: Int = 0,
         state: OpState = .pending) {
        self.id = id
        self.kind = kind
        self.sessionId = sessionId
        self.payload = payload
        self.createdAt = createdAt
        self.attempts = attempts
        self.state = state
    }

    /// Convenience: build an op whose payload is a JSON dictionary.
    static func make(kind: OpKind, sessionId: String, json: [String: Any]) -> QueuedOp {
        let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        return QueuedOp(kind: kind, sessionId: sessionId, payload: data)
    }

    /// The visit's deterministic record, encoded as the JSON a job system consumes. The same bytes
    /// `WorkRecord.json` produces, so what is queued and what is exported cannot disagree.
    static func make(workRecord: WorkRecord) -> QueuedOp {
        QueuedOp(kind: .workRecord, sessionId: workRecord.sessionId, payload: workRecord.json)
    }

    /// One stock check, encoded on its own so it can leave before the record does.
    static func make(partsRequest: PartsRequest, sessionId: String) -> QueuedOp {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return QueuedOp(kind: .partsRequest, sessionId: sessionId,
                        payload: (try? encoder.encode(partsRequest)) ?? Data())
    }

    /// Decode the payload back to a JSON dictionary (empty if it isn't one).
    var payloadJSON: [String: Any] {
        (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] ?? [:]
    }
}
