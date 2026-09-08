import Foundation

/// A queued job record or stock check, in the words the sync screen lists it (Plan EM P2).
///
/// The queue is durable and the queue view showed op kinds and session uuids. A technician looking
/// for the job they could not send needs the job reference, not `A3F1…`; and a record nobody can
/// find is, in every way that matters, a record that was lost.
struct QueuedRecordRow: Identifiable, Equatable {
    let id: String
    let kind: OpKind
    let state: OpState
    let sessionId: String
    let jobReference: String?
    /// "Job 4471 — work record" / "Job 4471 — 2 × 14T65".
    let title: String
    /// "3 tasks, 1 part requested · 12 minutes" / "High-altitude pressure switch — verified".
    let detail: String
    let attempts: Int
    /// The record itself, when this row is one — the "send it by email instead" action needs it.
    let record: WorkRecord?

    /// Whether this row can be handed to a composer. A parts request can be retried but not
    /// emailed on its own: the record is what a person reads.
    var canDeliver: Bool { record != nil }
}

/// Turning queued operations into rows. Pure — the decoding, the wording and the counting are all
/// provable without a database.
enum QueuedRecordRows {

    /// The op kinds this screen is about. Everything else stays in the general queue list.
    static let kinds: Set<OpKind> = [.workRecord, .partsRequest]

    /// States that mean "this has not reached anybody". `done` rows are tombstones and are not
    /// outstanding; `inFlight` is, because a flush that dies mid-delivery re-arms it as pending.
    static let outstandingStates: Set<OpState> = [.pending, .inFlight, .conflict, .failed]

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Every queued record and stock check that has not been delivered, newest first (the order
    /// `OfflineQueue.all()` returns).
    static func rows(from ops: [QueuedOp]) -> [QueuedRecordRow] {
        ops.filter { kinds.contains($0.kind) && outstandingStates.contains($0.state) }
            .compactMap(row(for:))
    }

    /// How many of this job's records are still outstanding — what the session card counts.
    static func outstandingCount(in ops: [QueuedOp], sessionId: String) -> Int {
        ops.filter { $0.sessionId == sessionId && kinds.contains($0.kind)
            && outstandingStates.contains($0.state) }.count
    }

    static func row(for op: QueuedOp) -> QueuedRecordRow? {
        switch op.kind {
        case .workRecord:
            guard let record = try? decoder().decode(WorkRecord.self, from: op.payload) else {
                return unreadable(op)
            }
            let job = record.jobReference.flatMap { $0.isEmpty ? nil : $0 }
            let done = record.tasks(status: .done).count
            var pieces = ["\(done) task\(done == 1 ? "" : "s") done"]
            if !record.partsRequests.isEmpty {
                pieces.append("\(record.partsRequests.count) part\(record.partsRequests.count == 1 ? "" : "s") requested")
            }
            pieces.append(WorkRecord.minutesPhrase(minutes: record.billableMinutes))
            return QueuedRecordRow(
                id: op.id, kind: op.kind, state: op.state, sessionId: op.sessionId,
                jobReference: job,
                title: job.map { "Job \($0) — work record" } ?? "Work record — \(record.vaultName)",
                detail: pieces.joined(separator: " · "),
                attempts: op.attempts, record: record)

        case .partsRequest:
            guard let request = try? decoder().decode(PartsRequest.self, from: op.payload) else {
                return unreadable(op)
            }
            return QueuedRecordRow(
                id: op.id, kind: op.kind, state: op.state, sessionId: op.sessionId,
                jobReference: nil,
                title: "Parts request — \(request.quantity) × \(request.part.number)",
                detail: request.summary,
                attempts: op.attempts, record: nil)

        default:
            return nil
        }
    }

    /// A row whose payload will not decode. It is still shown: an operation nobody can read is
    /// exactly the one a technician needs told about, and hiding it would be the silent loss the
    /// screen exists to prevent.
    private static func unreadable(_ op: QueuedOp) -> QueuedRecordRow {
        QueuedRecordRow(
            id: op.id, kind: op.kind, state: op.state, sessionId: op.sessionId, jobReference: nil,
            title: op.kind == .workRecord ? "Work record" : "Parts request",
            detail: "Queued \(op.createdAt.formatted(date: .abbreviated, time: .shortened)) — the stored copy could not be read.",
            attempts: op.attempts, record: nil)
    }
}
