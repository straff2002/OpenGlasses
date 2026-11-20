import Foundation
import Combine

/// One confirmed batch on the offline queue (Plan MM P4): the write plan, when the person
/// confirmed it and when it was queued, the system it is for, and how far delivery has got. It
/// survives a relaunch as the queue's payload. **It never holds the key**: the connection is read
/// from the Keychain at delivery, and nothing here can show one.
struct StockSystemQueuedBatch: Codable, Equatable, Sendable, CustomStringConvertible {

    static let formatVersion = 1

    /// Why a batch stopped for good without being sent.
    enum Ending: String, Codable, Sendable {
        case officeRoute = "office_route"
        case disconnected
    }

    var version = Self.formatVersion
    let batchID: String
    let connectorID: String
    /// The system's name, for the sentences.
    let system: String
    /// `StagedStockUseEntry.Scope.key`: the job or the premises day the parts were noted on.
    let scope: String
    let plan: PartsUsedWritePlan
    /// When the person said yes: the writes' `occurred_at` (clamped by `StockSystemIdempotency`).
    let confirmedAt: Date
    /// When it joined the queue: a read-back looks at the system's history from here.
    let queuedAt: Date
    /// Keys the system shows as applied.
    var applied: [String] = []
    /// Keys the system shows on a write that is not theirs, with the difference: never resent.
    var mismatched: [String: String] = [:]
    /// A write was sent and its outcome is not known: the next attempt reads back first.
    var uncertain = false
    /// The key generation a `401`/`403` came back for: nothing is tried again until a new key.
    var blockedGeneration: String?
    var retryAfter: Date?
    /// Terminal: the failure's code and sentence, for every step not applied.
    var failureCode: String?
    var failureSentence: String?
    var ending: Ending?
    var status: String

    var description: String {
        "StockSystemQueuedBatch(\(connectorID), \(plan.steps.count) writes, \(status))"
    }

    /// The writes still to be made: not applied, and not waiting for a person.
    var remaining: [PartsUsedWritePlan.Step] {
        let done = Set(applied)
        return plan.steps.filter { !done.contains($0.idempotencyKey) && mismatched[$0.idempotencyKey] == nil }
    }

    /// Where each written line stands, by staged line id.
    func deliveries(at now: Date) -> [String: StockSystemLineDelivery] {
        let done = Set(applied)
        var result: [String: StockSystemLineDelivery] = [:]
        for step in plan.steps {
            let key = step.idempotencyKey
            let delivery: StockSystemLineDelivery
            if done.contains(key) {
                delivery = .init(state: .sent, batchID: batchID, changedAt: now)
            } else if let difference = mismatched[key] {
                delivery = .init(state: .needsAttention, reason: "mismatch_\(difference)",
                                 sentence: StockSystemSyncSink.mismatchSentence(system: system), batchID: batchID,
                                 changedAt: now)
            } else if let ending {
                let reason: StockSystemNotSentReason = ending == .officeRoute ? .officeRoute : .disconnected
                delivery = .init(state: .notSent, reason: reason.rawValue, sentence: reason.sentence(system: system),
                                 batchID: batchID, changedAt: now)
            } else if let failureCode {
                delivery = .init(state: .needsAttention, reason: failureCode, sentence: failureSentence,
                                 batchID: batchID, changedAt: now)
            } else {
                delivery = .init(state: .queued, batchID: batchID, changedAt: now)
            }
            result[step.stagedLineID] = delivery
        }
        return result
    }
}

/// The offline queue's sink for parts sent to a business's own stock system (Plan MM P4): one
/// sink for every system, which reads the batch's connector id and drives that system's adapter
/// through `StockSystemConnector`, mirroring `WorkizSyncSink`. Vendor-neutral.
///
/// - **Read back before retry.** A write is marked uncertain *before* it is sent; after a timeout,
///   a dropped connection, a `5xx` or a reply it cannot read, the next attempt reads the system's
///   history first and sends only `PartsUsedWritePlan.remaining(after:)`. A step the system shows
///   under its key on a different write waits for a person and is never resent.
/// - **`401`/`403`** stop with the failure's sentence (paste a new key; the missing permission
///   named) until a new key is saved. **`429`** waits for `Retry-After` when the system gives one,
///   else the back-off; a **`5xx`** backs off. No signal waits without counting an attempt.
/// - **The office route** ending, or the connection being removed, ends a queued batch with its
///   sentence; its lines stay on the job's record as not sent, for the office to post.
/// - `MedicalEgressGuard` runs in the transport before every request, retries included.
@MainActor
final class StockSystemSyncSink: SyncSink, ObservableObject {

    /// The connection a batch is delivered over, as the sink sees it.
    enum Connection {
        case connected(connector: any StockSystemConnector, generation: String, route: NetworkRoute)
        /// Not running for now (switched off, not licensed): wait.
        case paused(String)
        /// No connection to this system on the phone: the batch ends.
        case removed
    }

    struct Seams {
        var connection: @MainActor (String) -> Connection
        var officeRoute: @MainActor () -> Bool
        var medicalBlocks: @MainActor (NetworkRoute) -> Bool = { MedicalEgressGuard.blocks($0) }
        var now: @MainActor () -> Date = { Date() }
        /// Asks for a flush at this time (the back-off, `Retry-After`).
        var retry: @MainActor (Date) -> Void = { _ in }
        /// Where the batch's lines stand now, by staged line id.
        var linesChanged: @MainActor ([String: StockSystemLineDelivery]) -> Void = { _ in }
        /// Writes reached the system: the figures should be read again.
        var sent: @MainActor (String) -> Void = { _ in }
    }

    nonisolated static let waitingLine = "Waiting for a connection"
    nonisolated static let idPrefix = "stock-system:"

    nonisolated static func sentLine(system: String) -> String { "Sent to \(system)" }

    nonisolated static func mismatchSentence(system: String) -> String {
        "\(system) shows a different change under this part's reference, so nothing more is sent for it. Check it in "
            + "\(system)."
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

    /// Queue a confirmed plan. Nil, and nothing queued, when it has no writes or could not be
    /// saved.
    @discardableResult
    func enqueue(_ plan: PartsUsedWritePlan, system: String, scope: StagedStockUseEntry.Scope, sessionID: String,
                 confirmedAt: Date, batchID: String) -> StockSystemQueuedBatch? {
        guard !plan.steps.isEmpty else { return nil }
        let batch = StockSystemQueuedBatch(batchID: batchID, connectorID: plan.connectorID, system: system,
                                           scope: scope.key, plan: plan, confirmedAt: confirmedAt,
                                           queuedAt: seams.now(), status: Self.waitingLine)
        guard let data = try? Self.encoder.encode(batch) else { return nil }
        let id = Self.idPrefix + batchID
        queue.enqueue(QueuedOp(id: id, kind: .stockSystemParts, sessionId: sessionID, payload: data,
                               createdAt: batch.queuedAt))
        guard queue.all(limit: 100_000).contains(where: { $0.id == id }) else { return nil }
        revision += 1
        return batch
    }

    /// Every batch on the queue, oldest first.
    func batches() -> [StockSystemQueuedBatch] {
        queue.all(limit: 100_000).filter { $0.kind == .stockSystemParts }.compactMap { Self.decode($0.payload) }
    }

    /// Try a batch that ran out of attempts again (Sync status, the job's Send again).
    func tryAgain(batchID: String) {
        let id = Self.idPrefix + batchID
        guard let op = queue.all(limit: 100_000).first(where: { $0.id == id }), op.state == .failed,
              var batch = Self.decode(op.payload), batch.ending == nil, batch.failureCode == "attempts_exhausted"
        else { return }
        batch.failureCode = nil
        batch.failureSentence = nil
        batch.retryAfter = nil
        batch.status = Self.waitingLine
        if save(batch, op: op) { queue.mark(id, state: .pending, attempts: 0) }
    }

    /// End every batch still queued for `connectorID` (every system when nil): the office posts
    /// stock now, or the connection was removed. Their lines stay on the record as not sent.
    func endAll(_ ending: StockSystemQueuedBatch.Ending, connectorID: String? = nil) {
        for op in queue.all(limit: 100_000) where op.kind == .stockSystemParts && op.state != .done {
            guard var batch = Self.decode(op.payload), batch.ending == nil,
                  connectorID.map({ $0 == batch.connectorID }) ?? true else { continue }
            end(&batch, ending, op: op)
            queue.mark(op.id, state: .failed)
        }
    }

    // MARK: - SyncSink

    func deliveryExhausted(_ op: QueuedOp) {
        guard op.kind == .stockSystemParts else { return fallback.deliveryExhausted(op) }
        guard let latest = queue.all(limit: 100_000).first(where: { $0.id == op.id }),
              var batch = Self.decode(latest.payload) else { return }
        batch.failureCode = "attempts_exhausted"
        batch.failureSentence = "\(batch.system) is still unavailable, so these parts haven't gone yet. Try again from "
            + "the job."
        batch.status = "Needs attention — " + (batch.failureSentence ?? "")
        save(batch, op: latest)
    }

    func deliver(_ op: QueuedOp) async -> SyncOutcome {
        guard op.kind == .stockSystemParts else { return await fallback.deliver(op) }
        guard var batch = Self.decode(op.payload) else {
            return .permanent(reason: "The parts for the stock system could not be read.")
        }
        if batch.ending != nil || batch.failureCode != nil { return .permanent(reason: batch.status) }
        if seams.officeRoute() {
            end(&batch, .officeRoute, op: op)
            return .permanent(reason: batch.status)
        }
        let connector: any StockSystemConnector
        let generation: String
        let route: NetworkRoute
        switch seams.connection(batch.connectorID) {
        case .removed:
            end(&batch, .disconnected, op: op)
            return .permanent(reason: batch.status)
        case .paused(let reason):
            batch.status = reason
            save(batch, op: op)
            return .waiting(reason: reason)
        case .connected(let connected, let current, let connectedRoute):
            connector = connected
            generation = current
            route = connectedRoute
        }
        if seams.medicalBlocks(route) {
            batch.status = MedicalEgressRefusal.userMessage
            save(batch, op: op)
            return .waiting(reason: batch.status)
        }
        if batch.blockedGeneration == generation { return .waiting(reason: batch.status) }
        if let date = batch.retryAfter, date > seams.now() {
            seams.retry(date)
            return .waiting(reason: batch.status)
        }
        do {
            if batch.uncertain {
                // The last write may or may not have landed: ask the system what it has before
                // anything is sent again.
                absorb(try await connector.readBack(batch.plan, queuedAt: batch.queuedAt), into: &batch)
                batch.uncertain = false
                save(batch, op: op)
            }
            let remaining = batch.remaining
            if !remaining.isEmpty {
                // Write-ahead: a crash or a kill after this point reads back before resending.
                batch.uncertain = true
                guard save(batch, op: op) else {
                    return .transient(reason: "The parts couldn't be saved on this phone before sending.")
                }
                absorb(try await connector.apply(remaining, confirmedAt: batch.confirmedAt), into: &batch)
                if !batch.remaining.isEmpty {
                    // Accepted without every write listed back: uncertain, so read back next time.
                    return backOff(&batch, op: op, sentence: StockSystemFailure.malformedResponse.sentence(system: batch.system))
                }
                batch.uncertain = false
            }
            batch.retryAfter = nil
            batch.blockedGeneration = nil
            let anySent = !batch.applied.isEmpty
            if batch.mismatched.isEmpty {
                batch.status = Self.sentLine(system: batch.system)
                save(batch, op: op)
                if anySent { seams.sent(batch.connectorID) }
                return .done
            }
            batch.status = "Needs attention — " + Self.mismatchSentence(system: batch.system)
            save(batch, op: op)
            if anySent { seams.sent(batch.connectorID) }
            return .permanent(reason: batch.status)
        } catch {
            if seams.officeRoute() {
                end(&batch, .officeRoute, op: op)
                return .permanent(reason: batch.status)
            }
            return failed(error, batch: &batch, op: op, generation: generation)
        }
    }

    // MARK: - Pieces

    private func failed(_ error: Error, batch: inout StockSystemQueuedBatch, op: QueuedOp,
                        generation: String) -> SyncOutcome {
        let system = batch.system
        if error is CancellationError {
            batch.status = Self.waitingLine
            save(batch, op: op)
            return .waiting(reason: batch.status)
        }
        if error is MedicalEgressRefusal {
            batch.status = MedicalEgressRefusal.userMessage
            save(batch, op: op)
            return .waiting(reason: batch.status)
        }
        guard let failure = error as? StockSystemFailure else {
            // A request the phone refused to send: nothing went, and nothing will until it is fixed.
            let sentence = StockSystemService.sentence(error, system: system)
            batch.failureCode = "refused_by_phone"
            batch.failureSentence = sentence
            batch.status = "Needs attention — " + sentence
            save(batch, op: op)
            return .permanent(reason: batch.status)
        }
        let sentence = failure.sentence(system: system)
        switch failure {
        case .unauthorized, .missingScope:
            // Stops until a new key: the person is told what to fix, and nothing more is tried
            // with this one. The lines show the sentence; a new key clears it.
            batch.blockedGeneration = generation
            batch.status = "Needs attention — " + sentence
            saveBlocked(batch, op: op, code: failure.code, sentence: sentence)
            return .waiting(reason: batch.status)
        case .rateLimited(let after):
            let wait = after ?? Self.backOff(attempts: op.attempts)
            batch.retryAfter = seams.now().addingTimeInterval(wait)
            batch.status = sentence
            save(batch, op: op)
            if let date = batch.retryAfter { seams.retry(date) }
            return .transient(reason: batch.status)
        case .server, .malformedResponse:
            return backOff(&batch, op: op, sentence: sentence)
        case .unreachable:
            batch.status = Self.waitingLine
            save(batch, op: op)
            return .waiting(reason: batch.status)
        case .rejected, .notFound, .tooLarge:
            batch.failureCode = failure.code
            batch.failureSentence = sentence
            batch.status = "Needs attention — " + sentence
            save(batch, op: op)
            return .permanent(reason: batch.status)
        }
    }

    private func backOff(_ batch: inout StockSystemQueuedBatch, op: QueuedOp, sentence: String) -> SyncOutcome {
        batch.retryAfter = seams.now().addingTimeInterval(Self.backOff(attempts: op.attempts))
        batch.status = Self.waitingLine
        save(batch, op: op)
        if let date = batch.retryAfter { seams.retry(date) }
        return .transient(reason: sentence)
    }

    /// 30 s, doubling with each attempt, at most an hour.
    nonisolated static func backOff(attempts: Int) -> TimeInterval {
        min(3600, 30 * pow(2, Double(min(max(attempts, 0), 7))))
    }

    private func absorb(_ readBack: StockSystemReadBack, into batch: inout StockSystemQueuedBatch) {
        let keys = Set(batch.plan.steps.map(\.idempotencyKey))
        var applied = Set(batch.applied)
        for key in readBack.applied where keys.contains(key) && batch.mismatched[key] == nil { applied.insert(key) }
        for mismatch in readBack.mismatched where keys.contains(mismatch.idempotencyKey)
            && !applied.contains(mismatch.idempotencyKey) {
            batch.mismatched[mismatch.idempotencyKey] = mismatch.difference.rawValue
        }
        batch.applied = batch.plan.steps.map(\.idempotencyKey).filter { applied.contains($0) }
    }

    private func end(_ batch: inout StockSystemQueuedBatch, _ ending: StockSystemQueuedBatch.Ending, op: QueuedOp) {
        batch.ending = ending
        batch.status = "Not sent — " + (ending == .officeRoute ? StockSystemNotSentReason.officeRoute
                                                               : StockSystemNotSentReason.disconnected).sentence(system: batch.system)
        save(batch, op: op)
    }

    /// A blocked batch's lines show the failure while the batch itself stays on the queue for a
    /// new key, so the failure is not stored as terminal.
    private func saveBlocked(_ batch: StockSystemQueuedBatch, op: QueuedOp, code: String, sentence: String) {
        guard let data = try? Self.encoder.encode(batch), queue.replacePayload(op.id, data: data) else { return }
        var lines = batch.deliveries(at: seams.now())
        for (id, delivery) in lines where delivery.state == .queued {
            lines[id] = .init(state: .needsAttention, reason: code, sentence: sentence, batchID: batch.batchID,
                              changedAt: delivery.changedAt)
        }
        seams.linesChanged(lines)
        revision += 1
    }

    @discardableResult
    private func save(_ batch: StockSystemQueuedBatch, op: QueuedOp) -> Bool {
        guard let data = try? Self.encoder.encode(batch), queue.replacePayload(op.id, data: data) else { return false }
        seams.linesChanged(batch.deliveries(at: seams.now()))
        revision += 1
        return true
    }

    nonisolated static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    nonisolated static func decode(_ data: Data) -> StockSystemQueuedBatch? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let batch = try? decoder.decode(StockSystemQueuedBatch.self, from: data),
              batch.version == StockSystemQueuedBatch.formatVersion else { return nil }
        return batch
    }
}
