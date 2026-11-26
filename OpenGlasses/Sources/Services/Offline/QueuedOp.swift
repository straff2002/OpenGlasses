import Foundation

/// What a queued operation does when it eventually reaches the network (Plan T).
enum OpKind: String, Codable {
    case logEntry       // a structured step/observation — durable locally, sync-only
    case photoUpload    // a captured photo on disk → upload when online
    /// A job clip on disk (Plan FO P2b). Deliberately **not** `photoUpload`: that kind's delivered
    /// tombstones are what `prunePhotoEvidence` evicts files for, and a clip belongs to a session
    /// log the store already refuses to delete. A clip is queued, never pruned.
    case clipUpload
    case llmGrounding   // a question asked offline → answer when back online
    case auditExport    // generate / upload the session audit export
    case captureRecord  // a finished capture-flow record (Plan U) — typed so a networked sink can route it
    case workizReport
    /// Parts used, confirmed by a person and on their way to a business's own stock system (Plan
    /// MM P4): the write plan and how far its delivery has got (`StockSystemQueuedBatch`), never
    /// the key.
    case stockSystemParts
    case workRecord     // the deterministic record of one visit (Plan EM) — what base is sent at the end
    case partsRequest   // a stock check (Plan EM) — leaves on its own, before the job is finished
    /// A subject the wearer erased locally, queued so a peer that holds a copy is told to erase it
    /// too. The payload carries the subject's identity and nothing about them — the point of the
    /// op is that the copy must go, not what the copy said.
    case subjectErasure
    /// A team-learning bundle (Plan FP P3): candidates on their way to the reviewer, or decisions on
    /// their way back — the direction is in the payload, which is the bundle's own bytes. Posted to
    /// an organisation's endpoint when one is configured; the office route is the signed contract
    /// and does not carry this.
    case teamLearning
    /// One team-learning candidate on its way to the company's administrator in the portal, over the
    /// seat channel (Plan NG). The payload is the candidate's id and revision, never its words: the
    /// send reads the candidate as it then stands (`LearningPortalOutbox`).
    case teamLearningPortal
    /// Exact canonical captured-manual manifest; files remain immutable and Office-only.
    case capturedManual
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

    /// A team-learning bundle, queued as the exact bytes it travels as by any other route, so what
    /// an endpoint receives and what a reviewer would open from an email are the same file.
    static func make(learningBundle bundle: LearningBundle) -> QueuedOp {
        QueuedOp(kind: .teamLearning, sessionId: LearningBundle.queueSessionID, payload: bundle.encoded())
    }

    /// A candidate for the portal (Plan NG): its id and revision only.
    static func make(portalCandidate candidate: LearningCandidate) -> QueuedOp {
        make(kind: .teamLearningPortal, sessionId: LearningBundle.queueSessionID,
             json: ["candidateID": candidate.id, "revision": candidate.revision])
    }

    static func make(capturedManual: CapturedManualContract.Manifest) -> QueuedOp {
        QueuedOp(kind:.capturedManual,sessionId:capturedManual.sessionID,
                 payload:(try? CapturedManualContract.canonicalBytes(capturedManual)) ?? Data())
    }

    /// Decode the payload back to a JSON dictionary (empty if it isn't one).
    var payloadJSON: [String: Any] {
        (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] ?? [:]
    }
}
