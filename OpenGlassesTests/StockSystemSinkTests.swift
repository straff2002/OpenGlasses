import XCTest
@testable import OpenGlasses

/// A connector whose writes and read-backs a test scripts, one result per call, and which keeps
/// every step it was asked to send.
final class SinkScriptedConnector: StockSystemConnector, @unchecked Sendable {

    let capabilities = SquareStockAdapter().capabilities(chosenReason: .waste)
    private let lock = NSLock()
    private var applyResults: [Result<StockSystemReadBack, Error>] = []
    private var readBackResults: [Result<StockSystemReadBack, Error>] = []
    private var _applied: [[String]] = []
    private var _readBacks = 0
    private var _confirmedAt: [Date] = []

    func scriptApply(_ results: Result<StockSystemReadBack, Error>...) { lock.withLock { applyResults += results } }
    func scriptReadBack(_ results: Result<StockSystemReadBack, Error>...) { lock.withLock { readBackResults += results } }

    /// The step keys sent, per write call.
    var applied: [[String]] { lock.withLock { _applied } }
    var readBacks: Int { lock.withLock { _readBacks } }
    var confirmedAt: [Date] { lock.withLock { _confirmedAt } }

    func locations() async throws -> [StockSystemLocation] { [] }
    func pullSnapshot(locationIDs: [String], pulledAt: Date) async throws -> StockSystemSnapshot {
        StockSystemConnectionSamples.snapshot()
    }
    func probe() async throws -> StockSystemProbe { StockSystemConnectionSamples.probe() }

    func apply(_ steps: [PartsUsedWritePlan.Step], confirmedAt: Date) async throws -> StockSystemReadBack {
        let result: Result<StockSystemReadBack, Error> = lock.withLock {
            _applied.append(steps.map(\.idempotencyKey))
            _confirmedAt.append(confirmedAt)
            return applyResults.isEmpty ? .success(StockSystemReadBack(applied: Set(steps.map(\.idempotencyKey))))
                                        : applyResults.removeFirst()
        }
        return try result.get()
    }

    func readBack(_ plan: PartsUsedWritePlan, queuedAt: Date) async throws -> StockSystemReadBack {
        let result: Result<StockSystemReadBack, Error> = lock.withLock {
            _readBacks += 1
            return readBackResults.isEmpty ? .success(StockSystemReadBack(applied: [])) : readBackResults.removeFirst()
        }
        return try result.get()
    }
}

/// Plan MM P4 — the offline queue's sink for parts sent to a business's own stock system: the
/// queue item survives a relaunch and never holds the key; read back before any retry and send
/// only what is missing; `401`/`403` stop with the sentence; `429` and `5xx` back off; the office
/// route and a removed connection end a queued batch and leave its lines on the record.
@MainActor
final class StockSystemSinkTests: XCTestCase {

    private var directory: URL!
    private var queue: OfflineQueue!
    private var connector: SinkScriptedConnector!
    private var connection: StockSystemSyncSink.Connection!
    private var officeRoute = false
    private var medicalBlocked = false
    private var clock = StockSystemSamples.pulledAt
    private var lines: [String: StockSystemLineDelivery] = [:]
    private var retries: [Date] = []
    private var sentFor: [String] = []
    private var fallbackDelivered: [String] = []

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("stock-sink-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        queue = OfflineQueue(path: directory.appendingPathComponent("queue.sqlite"))
        connector = SinkScriptedConnector()
        connection = .connected(connector: connector, generation: "G1", route: .squareStockAPI)
    }

    override func tearDown() {
        queue = nil
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private final class Fallback: SyncSink {
        var delivered: [String] = []
        func deliver(_ op: QueuedOp) async -> SyncOutcome {
            delivered.append(op.id)
            return .done
        }
    }

    private let fallback = Fallback()

    private func makeSink(queue: OfflineQueue? = nil) -> StockSystemSyncSink {
        StockSystemSyncSink(queue: queue ?? self.queue, fallback: fallback, seams: .init(
            connection: { [unowned self] _ in self.connection },
            officeRoute: { [unowned self] in self.officeRoute },
            medicalBlocks: { [unowned self] _ in self.medicalBlocked },
            now: { [unowned self] in self.clock },
            retry: { [unowned self] in self.retries.append($0) },
            linesChanged: { [unowned self] in self.lines.merge($0) { _, new in new } },
            sent: { [unowned self] in self.sentFor.append($0) }))
    }

    /// Three adjustments and one line the system does not carry.
    private func plan() -> PartsUsedWritePlan {
        let snapshot = StockSystemSamples.snapshot([
            StockSystemSamples.row("I1", [("L1", "5")]),
            StockSystemSamples.row("I2", [("L1", "5")]),
            StockSystemSamples.row("I3", [("L1", "5")]),
        ])
        func use(_ id: String, _ item: String?) -> StagedStockUse {
            StagedStockUse(id: id, itemID: item, part: "ZX-\(id)", description: "Capacitor", quantity: .whole(1),
                           unit: .each, source: .spoken)
        }
        let batch = ConfirmedStockUseBatch(jobID: "JOB-1", jobNumber: "1027", locationID: "L1",
                                           lines: [use("A", "I1"), use("B", "I2"), use("C", "I3"), use("D", nil)],
                                           confirmation: .person(.screen))
        let capabilities = StockSystemCapabilities(connectorID: "square", displayName: "Square", hasJobs: false,
                                                   wholeNumbersOnly: false, adjustmentReasons: [.waste],
                                                   chosenReason: .waste)
        return PartsUsedWritePlan(batch: batch, reference: nil, capabilities: capabilities, snapshot: snapshot)
    }

    private var keys: [String] { plan().steps.map(\.idempotencyKey) }

    @discardableResult
    private func enqueue(_ sink: StockSystemSyncSink) throws -> QueuedOp {
        let batch = try XCTUnwrap(sink.enqueue(plan(), system: "Square", scope: .job("S1"), sessionID: "S1",
                                               confirmedAt: StockSystemSamples.pulledAt, batchID: "B1"))
        XCTAssertEqual(batch.plan.steps.count, 3)
        return try XCTUnwrap(queue.all(limit: 100).first { $0.id == StockSystemSyncSink.idPrefix + "B1" })
    }

    private func current() throws -> QueuedOp {
        try XCTUnwrap(queue.all(limit: 100).first { $0.id == StockSystemSyncSink.idPrefix + "B1" })
    }

    private func batch() throws -> StockSystemQueuedBatch {
        try XCTUnwrap(StockSystemSyncSink.decode(try current().payload))
    }

    // MARK: - Delivered once

    func testAConfirmedBatchIsSentAndEveryWrittenLineIsSent() async throws {
        let sink = makeSink()
        let op = try enqueue(sink)
        XCTAssertEqual(lines.isEmpty, true, "queueing is the confirmation's to record")
        let outcome = await sink.deliver(op)
        XCTAssertEqual(outcome, .done)
        XCTAssertEqual(connector.applied, [keys], "every write once")
        XCTAssertEqual(connector.readBacks, 0, "nothing uncertain, so nothing read back")
        XCTAssertEqual(connector.confirmedAt, [StockSystemSamples.pulledAt], "occurred_at is the confirmation's time")
        XCTAssertEqual(Set(lines.keys), ["A", "B", "C"])
        XCTAssertTrue(lines.values.allSatisfy { $0.state == .sent })
        XCTAssertEqual(try batch().status, "Sent to Square")
        XCTAssertEqual(sentFor, ["square"], "a good send asks for the figures again")
    }

    func testAnUncertainWriteIsReadBackFirstAndOnlyTheRemainingStepsAreSent() async throws {
        let sink = makeSink()
        let op = try enqueue(sink)
        connector.scriptApply(.failure(StockSystemFailure.server(status: 503)))
        let first = await sink.deliver(op)
        guard case .transient = first else { return XCTFail("a 5xx backs off: \(first)") }
        XCTAssertTrue(try batch().uncertain, "the write may have landed")
        XCTAssertEqual(retries.count, 1, "the back-off asks for a flush")
        XCTAssertTrue(lines.values.allSatisfy { $0.state == .queued })

        clock = clock.addingTimeInterval(3600)
        connector.scriptReadBack(.success(StockSystemReadBack(applied: [keys[0]])))
        let second = await sink.deliver(try current())
        XCTAssertEqual(second, .done)
        XCTAssertEqual(connector.readBacks, 1, "read back before anything is sent again")
        XCTAssertEqual(connector.applied.last, [keys[1], keys[2]], "only what the system did not show")
        XCTAssertEqual(connector.applied.count, 2)
        XCTAssertTrue(lines.values.allSatisfy { $0.state == .sent })
    }

    func testAKillMidSendReadsBackBeforeResending() async throws {
        // The write was marked uncertain and never answered: the app was killed.
        let sink = makeSink()
        _ = try enqueue(sink)
        var stored = try batch()
        stored.uncertain = true
        XCTAssertTrue(queue.replacePayload(try current().id, data: try StockSystemSyncSink.encoder.encode(stored)))
        connector.scriptReadBack(.success(StockSystemReadBack(applied: Set(keys))))
        let relaunched = makeSink(queue: OfflineQueue(path: directory.appendingPathComponent("queue.sqlite")))
        let outcome = await relaunched.deliver(try current())
        XCTAssertEqual(outcome, .done)
        XCTAssertEqual(connector.readBacks, 1)
        XCTAssertTrue(connector.applied.isEmpty, "everything had landed, so nothing is sent twice")
    }

    func testAMismatchedKeyNeedsAttentionAndIsNeverResent() async throws {
        let sink = makeSink()
        let op = try enqueue(sink)
        connector.scriptApply(.failure(StockSystemFailure.unreachable))
        _ = await sink.deliver(op)
        connector.scriptReadBack(.success(StockSystemReadBack(applied: [keys[0]],
                                                              mismatched: [.init(idempotencyKey: keys[1], difference: .quantity)])))
        let outcome = await sink.deliver(try current())
        guard case .permanent(let reason) = outcome else { return XCTFail("a mismatch waits for a person: \(outcome)") }
        XCTAssertTrue(reason.hasPrefix("Needs attention — Square shows a different change"), reason)
        XCTAssertEqual(connector.applied.last, [keys[2]], "the mismatched step is not sent again")
        XCTAssertEqual(lines["A"]?.state, .sent)
        XCTAssertEqual(lines["B"]?.state, .needsAttention)
        XCTAssertEqual(lines["B"]?.reason, "mismatch_quantity")
        XCTAssertEqual(lines["C"]?.state, .sent)
        XCTAssertEqual(try batch().mismatched, [keys[1]: "quantity"])
    }

    // MARK: - Failures

    func testUnauthorizedAndMissingPermissionStopWithTheSentenceUntilANewKey() async throws {
        for failure in [StockSystemFailure.unauthorized(.expired), .missingScope("INVENTORY_WRITE")] {
            try? FileManager.default.removeItem(at: directory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            queue = OfflineQueue(path: directory.appendingPathComponent("queue.sqlite"))
            connector = SinkScriptedConnector()
            connection = .connected(connector: connector, generation: "G1", route: .squareStockAPI)
            lines = [:]
            let sink = makeSink()
            let op = try enqueue(sink)
            connector.scriptApply(.failure(failure))
            let outcome = await sink.deliver(op)
            XCTAssertEqual(outcome, .waiting(reason: "Needs attention — " + failure.sentence(system: "Square")))
            XCTAssertTrue(lines.values.allSatisfy { $0.state == .needsAttention && $0.sentence == failure.sentence(system: "Square") })
            if case .missingScope = failure {
                XCTAssertTrue(failure.sentence(system: "Square").contains("INVENTORY_WRITE"), "the permission is named")
            } else {
                XCTAssertTrue(failure.sentence(system: "Square").contains("Paste a new one"))
            }
            // Nothing more is tried with the same key.
            let again = await sink.deliver(try current())
            guard case .waiting = again else { return XCTFail("still stopped: \(again)") }
            XCTAssertEqual(connector.applied.count, 1)
            XCTAssertEqual(connector.readBacks, 0)
            // A new key: read back first (the refused write left it uncertain), then send.
            connection = .connected(connector: connector, generation: "G2", route: .squareStockAPI)
            let resumed = await sink.deliver(try current())
            XCTAssertEqual(resumed, .done)
            XCTAssertEqual(connector.readBacks, 1)
            XCTAssertTrue(lines.values.allSatisfy { $0.state == .sent })
        }
    }

    func testRateLimitedHonoursRetryAfterOrBacksOff() async throws {
        let sink = makeSink()
        let op = try enqueue(sink)
        connector.scriptApply(.failure(StockSystemFailure.rateLimited(retryAfter: 120)))
        let first = await sink.deliver(op)
        guard case .transient = first else { return XCTFail("\(first)") }
        XCTAssertEqual(try batch().retryAfter, clock.addingTimeInterval(120), "Retry-After is honoured")
        XCTAssertEqual(retries, [clock.addingTimeInterval(120)])
        // Before then, nothing is sent.
        let early = await sink.deliver(try current())
        guard case .waiting = early else { return XCTFail("\(early)") }
        XCTAssertEqual(connector.applied.count, 1)

        clock = clock.addingTimeInterval(121)
        connector.scriptReadBack(.success(StockSystemReadBack(applied: [])))
        connector.scriptApply(.failure(StockSystemFailure.rateLimited(retryAfter: nil)))
        var op2 = try current()
        op2.attempts = 2
        _ = await sink.deliver(op2)
        XCTAssertEqual(try batch().retryAfter, clock.addingTimeInterval(StockSystemSyncSink.backOff(attempts: 2)),
                       "without Retry-After, the sink's back-off")
        XCTAssertEqual(StockSystemSyncSink.backOff(attempts: 0), 30)
        XCTAssertEqual(StockSystemSyncSink.backOff(attempts: 2), 120)
        XCTAssertEqual(StockSystemSyncSink.backOff(attempts: 20), 3600)
    }

    func testAServerErrorBacksOffAndNoSignalWaitsWithoutCountingAnAttempt() async throws {
        let sink = makeSink()
        let op = try enqueue(sink)
        connector.scriptApply(.failure(StockSystemFailure.server(status: 500)))
        let server = await sink.deliver(op)
        guard case .transient = server else { return XCTFail("\(server)") }
        XCTAssertNotNil(try batch().retryAfter)

        clock = clock.addingTimeInterval(7200)
        connector.scriptReadBack(.failure(StockSystemFailure.unreachable))
        let offline = await sink.deliver(try current())
        XCTAssertEqual(offline, .waiting(reason: StockSystemSyncSink.waitingLine),
                       "offline until the next morning is waiting, not a failure")
        XCTAssertTrue(try batch().uncertain, "still read back first when the signal comes back")
    }

    func testARejectedWriteNeedsAttentionForGood() async throws {
        let sink = makeSink()
        let op = try enqueue(sink)
        connector.scriptApply(.failure(StockSystemFailure.rejected(code: "INVALID_VALUE", field: "quantity")))
        let outcome = await sink.deliver(op)
        guard case .permanent(let reason) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(reason.contains("INVALID_VALUE"), reason)
        XCTAssertTrue(lines.values.allSatisfy { $0.state == .needsAttention && $0.reason == "rejected" })
        let again = await sink.deliver(try current())
        guard case .permanent = again else { return XCTFail("\(again)") }
        XCTAssertEqual(connector.applied.count, 1, "never resent")
    }

    func testMedicalLocalOnlyWaitsAndSendsNothing() async throws {
        medicalBlocked = true
        let sink = makeSink()
        let outcome = await sink.deliver(try enqueue(sink))
        XCTAssertEqual(outcome, .waiting(reason: MedicalEgressRefusal.userMessage))
        XCTAssertTrue(connector.applied.isEmpty)
    }

    func testRunningOutOfAttemptsNeedsAttentionAndCanBeTriedAgain() async throws {
        let sink = makeSink()
        let op = try enqueue(sink)
        queue.mark(op.id, state: .failed, attempts: 6)
        sink.deliveryExhausted(op)
        XCTAssertEqual(try batch().failureCode, "attempts_exhausted")
        XCTAssertTrue(lines.values.allSatisfy { $0.state == .needsAttention })
        sink.tryAgain(batchID: "B1")
        XCTAssertEqual(try current().state, .pending)
        XCTAssertNil(try batch().failureCode)
        let outcome = await sink.deliver(try current())
        XCTAssertEqual(outcome, .done)
    }

    // MARK: - Ending

    func testTheOfficeRouteEndsAQueuedBatchAndLeavesItOnTheRecord() async throws {
        let sink = makeSink()
        let op = try enqueue(sink)
        officeRoute = true
        let outcome = await sink.deliver(op)
        guard case .permanent(let reason) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(reason.contains("Your office posts stock to Square now"), reason)
        XCTAssertTrue(connector.applied.isEmpty, "nothing goes once the office posts stock")
        XCTAssertTrue(lines.values.allSatisfy { $0.state == .notSent && $0.reason == "office_route" })
        XCTAssertTrue(lines.values.allSatisfy { $0.sentence?.contains("for the office to post") == true })
    }

    func testEndAllForTheOfficeOrARemovedConnection() async throws {
        let sink = makeSink()
        _ = try enqueue(sink)
        sink.endAll(.disconnected, connectorID: "other-system")
        XCTAssertEqual(try current().state, .pending, "another system's removal leaves it")
        sink.endAll(.disconnected, connectorID: "square")
        XCTAssertEqual(try current().state, .failed)
        XCTAssertEqual(try batch().ending, .disconnected)
        XCTAssertTrue(lines.values.allSatisfy { $0.state == .notSent && $0.reason == "disconnected" })
        let outcome = await sink.deliver(try current())
        guard case .permanent = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(connector.applied.isEmpty)
    }

    func testARemovedConnectionAtDeliveryEndsTheBatch() async throws {
        let sink = makeSink()
        let op = try enqueue(sink)
        connection = .removed
        let outcome = await sink.deliver(op)
        guard case .permanent(let reason) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(reason.contains("Square was disconnected on this phone"), reason)
        XCTAssertTrue(lines.values.allSatisfy { $0.state == .notSent })
        connection = .paused(StockSystemSyncSink.waitingLine)
    }

    func testAPausedConnectionWaits() async throws {
        let sink = makeSink()
        let op = try enqueue(sink)
        connection = .paused(StockSystemSyncSink.waitingLine)
        let outcome = await sink.deliver(op)
        XCTAssertEqual(outcome, .waiting(reason: StockSystemSyncSink.waitingLine))
        XCTAssertTrue(connector.applied.isEmpty)
    }

    // MARK: - The queue item

    func testTheQueueItemSurvivesARelaunchAndHoldsNoKey() async throws {
        let key = StockSystemConnectionSamples.key("k")
        let sink = makeSink()
        let op = try enqueue(sink)
        let reopened = OfflineQueue(path: directory.appendingPathComponent("queue.sqlite"))
        let stored = try XCTUnwrap(reopened.all(limit: 100).first { $0.id == op.id })
        XCTAssertEqual(stored.kind, .stockSystemParts)
        let decoded = try XCTUnwrap(StockSystemSyncSink.decode(stored.payload))
        XCTAssertEqual(decoded.plan, plan())
        XCTAssertEqual(decoded.confirmedAt, StockSystemSamples.pulledAt)
        XCTAssertEqual(decoded.queuedAt, clock)
        XCTAssertEqual(decoded.connectorID, "square")
        let text = String(decoding: stored.payload, as: UTF8.self)
        XCTAssertFalse(text.contains(key))
        XCTAssertFalse(text.lowercased().contains("bearer"))
        XCTAssertFalse(text.contains("TESTKEY"), "no key-shaped value in the payload")
        XCTAssertFalse(decoded.description.contains("TESTKEY"))
        XCTAssertFalse(String(describing: decoded).contains("TESTKEY"))
        // It is delivered from the reopened queue as from the first.
        let relaunched = makeSink(queue: reopened)
        let outcome = await relaunched.deliver(stored)
        XCTAssertEqual(outcome, .done)
    }

    func testOtherKindsGoToTheFallback() async {
        let sink = makeSink()
        let op = QueuedOp(id: "w1", kind: .workRecord, sessionId: "S1")
        let outcome = await sink.deliver(op)
        XCTAssertEqual(outcome, .done)
        XCTAssertEqual(fallback.delivered, ["w1"])
    }

    func testAPlanWithNoWritesIsNotQueued() {
        let sink = makeSink()
        let snapshot = StockSystemSamples.snapshot([])
        let batch = ConfirmedStockUseBatch(jobID: "J", jobNumber: nil, locationID: "L1", lines: [
            StagedStockUse(id: "X", itemID: nil, part: "P", description: "D", quantity: .whole(1), unit: .each,
                           source: .spoken)], confirmation: .person(.voice))
        let capabilities = StockSystemCapabilities(connectorID: "square", displayName: "Square", hasJobs: false,
                                                   wholeNumbersOnly: false, adjustmentReasons: [.waste],
                                                   chosenReason: .waste)
        let plan = PartsUsedWritePlan(batch: batch, reference: nil, capabilities: capabilities, snapshot: snapshot)
        XCTAssertNil(sink.enqueue(plan, system: "Square", scope: .job("S"), sessionID: "S", confirmedAt: clock, batchID: "Z"))
        XCTAssertTrue(queue.all(limit: 10).isEmpty)
    }

    // MARK: - End to end, through the fixture transport

    /// Square's batch-create and changes fixtures through the common HTTP connector: a first send
    /// that fails with a 500 is uncertain; the next attempt reads back (the coolant line applied,
    /// the capacitor's key on another amount), sends only the filter, and the system shows it once.
    func testEndToEndThroughTheFixtureTransport() async throws {
        let fixtures = SquareFixtures.Transport()
        fixtures.overrides["/v2/inventory/changes/batch-create"] = try SquareFixtures.response("error-500.json", status: 500)
        let transport = FixtureStockSystemTransport { try fixtures.send($0) }
        let adapter = SquareStockAdapter()
        let destination = try XCTUnwrap(StockSystemDestination(adapter: adapter, route: .squareStockAPI,
                                                               environment: .production))
        let credential = try XCTUnwrap(StockSystemCredential(StockSystemConnectionSamples.key()))
        let http = StockSystemHTTPConnector(adapter: adapter, destination: destination, transport: transport,
                                            credential: credential, chosenReason: .waste,
                                            now: { StockSystemSamples.date(2026, 11, 20, 10, 5) })
        connection = .connected(connector: http, generation: "G1", route: .squareStockAPI)
        clock = SquareFixtures.pulledAt
        let plan = try await SquareFixtures.plan()
        let sink = makeSink()
        let queued = try XCTUnwrap(sink.enqueue(plan, system: "Square", scope: .job("JOB-SQ-FIX-1"),
                                                sessionID: "JOB-SQ-FIX-1", confirmedAt: SquareFixtures.pulledAt,
                                                batchID: "B1"))
        let first = await sink.deliver(try current())
        guard case .transient = first else { return XCTFail("\(first)") }
        XCTAssertTrue(try batch().uncertain)

        fixtures.overrides = [:]
        clock = clock.addingTimeInterval(3600)
        let second = await sink.deliver(try current())
        guard case .permanent(let reason) = second else { return XCTFail("the capacitor needs a person: \(second)") }
        XCTAssertTrue(reason.hasPrefix("Needs attention"), reason)
        let ids = Dictionary(uniqueKeysWithValues: queued.plan.steps.map { ($0.stagedLineID, $0.idempotencyKey) })
        XCTAssertEqual(lines["S1"]?.state, .sent, "found applied by the read-back")
        XCTAssertEqual(lines["S2"]?.state, .needsAttention, "another amount under its key")
        XCTAssertEqual(lines["S7"]?.state, .sent, "the one step sent again")
        let writes = fixtures.sent.filter { $0.endpoint == SquareStockAdapter.Endpoint.inventoryWrite }
        XCTAssertEqual(writes.count, 2)
        let resent = String(decoding: writes[1].body ?? Data(), as: UTF8.self)
        XCTAssertTrue(resent.contains(try XCTUnwrap(ids["S7"])))
        XCTAssertFalse(resent.contains(try XCTUnwrap(ids["S1"])), "never the applied line again")
        XCTAssertFalse(resent.contains(try XCTUnwrap(ids["S2"])), "never the mismatched line")
        XCTAssertTrue(fixtures.sent.contains { $0.endpoint == SquareStockAdapter.Endpoint.inventoryChanges },
                      "read back before the retry")
        let sentKeys = transport.sent.map(\.credential.ending)
        XCTAssertEqual(Set(sentKeys).count, 1)
        XCTAssertFalse(String(decoding: try current().payload, as: UTF8.self).contains(credential.key))
    }
}
