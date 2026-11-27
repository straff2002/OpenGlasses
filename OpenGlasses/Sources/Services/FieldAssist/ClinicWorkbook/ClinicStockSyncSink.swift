import Foundation
import Combine

/// One send of a clinical list's rows on the offline queue (Plan NK §2): the workbook they are
/// for, the keyed share rows, and how far they have got. **The rows are `ClinicalStockShareRow`s
/// and their keys, and nothing else** (`ClinicStockRouteGuardTests`). Never a token.
struct ClinicStockQueuedBatch: Codable, Equatable, Sendable, CustomStringConvertible {

    static let formatVersion = 1

    var version = Self.formatVersion
    let batchID: String
    let workbook: GraphWorkbook
    let rows: [KeyedShareRow]
    let queuedAt: Date
    /// Keys the workbook is known to hold.
    var applied: [String] = []
    /// Terminal: why the batch stopped for good.
    var failureCode: String?
    var status: String

    var description: String { "ClinicStockQueuedBatch(\(rows.count) rows, \(status))" }

    var remaining: [KeyedShareRow] {
        let done = Set(applied)
        return rows.filter { !done.contains($0.key) }
    }
}

/// The offline queue's sink for a clinical list's rows on their way to the clinic's workbook
/// (Plan NK §2), in front of the other sinks: a `clinicStockRows` op is delivered here, anything
/// else goes on to `fallback`.
///
/// - **Once each.** Before adding, the sink reads the tables and adds only the keys not there, so a
///   batch sent twice, or retried after a reply that never came, adds nothing the second time.
/// - **Expired sign-in** waits, without counting an attempt, until the person signs in again.
///   **Out of reach** waits; **`429`/`503`** back off; a refused file, a missing workbook or a
///   patient-like column ends the batch, and its rows are taken back off the ledger so a later send
///   makes them again.
/// - **Another workbook chosen, or signed out:** the batch ends unsent, and its rows are taken back.
@MainActor
final class ClinicStockSyncSink: SyncSink, ObservableObject {

    enum Connection {
        case connected(ClinicWorkbookClient)
        /// Not able to send just now (signed out of an expired session, Medical mode refusing).
        case paused(String)
        /// No connection, or no workbook chosen.
        case removed
    }

    struct Seams {
        var connection: @MainActor () -> Connection
        var now: @MainActor () -> Date = { Date() }
        var retry: @MainActor (Date) -> Void = { _ in }
        /// Rows reached the workbook.
        var delivered: @MainActor (ClinicStockQueuedBatch) -> Void = { _ in }
        /// Rows that will never go in this batch: take them off the ledger.
        var abandoned: @MainActor (GraphWorkbook, [String]) -> Void = { _, _ in }
    }

    nonisolated static let idPrefix = "clinic-stock:"

    nonisolated static var waitingLine: String {
        String(localized: "Waiting to reach the clinic's workbook", comment: "A clinic stock send waiting for a connection.")
    }
    nonisolated static var sentLine: String {
        String(localized: "Sent to the clinic's workbook", comment: "A clinic stock send that reached the workbook.")
    }
    nonisolated static var endedLine: String {
        String(localized: "Not sent: the clinic's workbook was changed or signed out. The rows go with the next send.",
               comment: "A clinic stock send ended because the connection changed.")
    }

    @Published private(set) var revision = 0

    private let queue: OfflineQueue
    private let fallback: SyncSink
    private let seams: Seams

    init(queue: OfflineQueue, fallback: SyncSink, seams: Seams) {
        self.queue = queue
        self.fallback = fallback
        self.seams = seams
    }

    // MARK: - Queueing

    /// Queue rows for `workbook`. Nil, and nothing queued, when there are none or they couldn't be
    /// saved.
    @discardableResult
    func enqueue(_ rows: [KeyedShareRow], workbook: GraphWorkbook, batchID: String) -> ClinicStockQueuedBatch? {
        guard !rows.isEmpty else { return nil }
        let batch = ClinicStockQueuedBatch(batchID: batchID, workbook: workbook, rows: rows, queuedAt: seams.now(),
                                           status: Self.waitingLine)
        guard let data = try? Self.encoder.encode(batch) else { return nil }
        let id = Self.idPrefix + batchID
        queue.enqueue(QueuedOp(id: id, kind: .clinicStockRows, sessionId: "clinic-stock", payload: data,
                               createdAt: batch.queuedAt))
        guard queue.all(limit: 100_000).contains(where: { $0.id == id }) else { return nil }
        revision += 1
        return batch
    }

    /// Batches not yet delivered, oldest first.
    func pending() -> [ClinicStockQueuedBatch] {
        queue.all(limit: 100_000).filter { $0.kind == .clinicStockRows && $0.state != .done && $0.state != .failed }
            .reversed().compactMap { Self.decode($0.payload) }
    }

    /// Rows still waiting to go.
    var rowsQueued: Int { pending().reduce(0) { $0 + $1.remaining.count } }

    /// End every batch still queued (signed out, another workbook chosen); their rows are taken off
    /// the ledger.
    func endAll() {
        for op in queue.all(limit: 100_000) where op.kind == .clinicStockRows && op.state != .done && op.state != .failed {
            guard var batch = Self.decode(op.payload) else { continue }
            end(&batch, code: "ended", status: Self.endedLine, op: op)
            queue.mark(op.id, state: .failed)
        }
    }

    // MARK: - SyncSink

    func deliveryExhausted(_ op: QueuedOp) {
        guard op.kind == .clinicStockRows else { return fallback.deliveryExhausted(op) }
        guard let latest = queue.all(limit: 100_000).first(where: { $0.id == op.id }),
              var batch = Self.decode(latest.payload) else { return }
        end(&batch, code: "attempts_exhausted", status: ClinicWorkbookFailure.unreachable.sentence, op: latest)
    }

    func deliver(_ op: QueuedOp) async -> SyncOutcome {
        guard op.kind == .clinicStockRows else { return await fallback.deliver(op) }
        guard var batch = Self.decode(op.payload) else {
            return .permanent(reason: "The clinic stock rows could not be read.")
        }
        if batch.failureCode != nil { return .permanent(reason: batch.status) }
        let client: ClinicWorkbookClient
        switch seams.connection() {
        case .removed:
            end(&batch, code: "ended", status: Self.endedLine, op: op)
            return .permanent(reason: batch.status)
        case .paused(let reason):
            batch.status = reason
            save(batch, op: op)
            return .waiting(reason: reason)
        case .connected(let connected):
            client = connected
        }
        guard client.workbook == batch.workbook else {
            end(&batch, code: "ended", status: Self.endedLine, op: op)
            return .permanent(reason: batch.status)
        }
        do {
            let present = try await client.append(batch.remaining)
            let applied = Set(batch.applied)
            batch.applied = batch.rows.map(\.key).filter { present.contains($0) || applied.contains($0) }
            guard batch.remaining.isEmpty else {
                batch.status = Self.waitingLine
                save(batch, op: op)
                return .transient(reason: batch.status)
            }
            batch.status = Self.sentLine
            save(batch, op: op)
            seams.delivered(batch)
            return .done
        } catch let failure as ClinicWorkbookFailure {
            switch failure {
            case .unauthorized:
                batch.status = failure.sentence
                save(batch, op: op)
                return .waiting(reason: batch.status)
            case .rateLimited(let after):
                let date = seams.now().addingTimeInterval(after ?? Self.backOff(attempts: op.attempts))
                seams.retry(date)
                batch.status = Self.waitingLine
                save(batch, op: op)
                return .transient(reason: failure.sentence)
            case .unreachable:
                batch.status = Self.waitingLine
                save(batch, op: op)
                return .waiting(reason: batch.status)
            case .server:
                seams.retry(seams.now().addingTimeInterval(Self.backOff(attempts: op.attempts)))
                batch.status = Self.waitingLine
                save(batch, op: op)
                return .transient(reason: failure.sentence)
            case .forbidden, .notFound, .malformedResponse, .tooLarge:
                end(&batch, code: failure.code, status: failure.sentence, op: op)
                return .permanent(reason: batch.status)
            }
        } catch let setup as ClinicWorkbookSetupError {
            end(&batch, code: "refused", status: setup.sentence, op: op)
            return .permanent(reason: batch.status)
        } catch is MedicalEgressRefusal {
            batch.status = MedicalEgressRefusal.userMessage
            save(batch, op: op)
            return .waiting(reason: batch.status)
        } catch is CancellationError {
            batch.status = Self.waitingLine
            save(batch, op: op)
            return .waiting(reason: batch.status)
        } catch {
            // A request the phone refused to send, or no token: nothing went.
            end(&batch, code: "refused_by_phone", status: ClinicWorkbookFailure.malformedResponse.sentence, op: op)
            return .permanent(reason: batch.status)
        }
    }

    // MARK: - Pieces

    /// 30 s, doubling with each attempt, at most an hour.
    nonisolated static func backOff(attempts: Int) -> TimeInterval {
        min(3600, 30 * pow(2, Double(min(max(attempts, 0), 7))))
    }

    private func end(_ batch: inout ClinicStockQueuedBatch, code: String, status: String, op: QueuedOp) {
        batch.failureCode = code
        batch.status = status
        save(batch, op: op)
        let unsent = batch.remaining.map(\.key)
        if !unsent.isEmpty { seams.abandoned(batch.workbook, unsent) }
    }

    @discardableResult
    private func save(_ batch: ClinicStockQueuedBatch, op: QueuedOp) -> Bool {
        guard let data = try? Self.encoder.encode(batch), queue.replacePayload(op.id, data: data) else { return false }
        revision += 1
        return true
    }

    nonisolated static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    nonisolated static func decode(_ data: Data) -> ClinicStockQueuedBatch? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let batch = try? decoder.decode(ClinicStockQueuedBatch.self, from: data),
              batch.version == ClinicStockQueuedBatch.formatVersion else { return nil }
        return batch
    }
}
