import XCTest
@testable import OpenGlasses

/// Tests for the offline field queue + store-and-forward sync (Plan T): the SQLite-backed
/// `OfflineQueue`, the reachability-driven `SyncEngine`, `Reachability`, and `ConflictResolver`.
/// Headless — the queue uses a throwaway file, sync uses fake sinks.
@MainActor
final class OfflineQueueTests: XCTestCase {

    private var tempFiles: [URL] = []
    private var tempAux: [URL] = []

    override func tearDown() {
        for url in tempFiles {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
            }
        }
        for url in tempAux { try? FileManager.default.removeItem(at: url) }
        tempFiles.removeAll()
        tempAux.removeAll()
        super.tearDown()
    }

    /// Create a throwaway file of `bytes` and return its path (tracked for cleanup).
    private func makePhotoFile(bytes: Int) -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("photo_\(UUID().uuidString).jpg")
        try? Data(repeating: 0xAB, count: bytes).write(to: url)
        tempAux.append(url)
        return url.path
    }

    private func tempPath() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("oq_\(UUID().uuidString).sqlite")
        tempFiles.append(url)
        return url
    }

    private func op(_ session: String, at seconds: TimeInterval, kind: OpKind = .logEntry) -> QueuedOp {
        QueuedOp(kind: kind, sessionId: session, createdAt: Date(timeIntervalSince1970: seconds))
    }

    // MARK: - OfflineQueue

    func testEnqueueAndPendingAreFIFOByCreatedAt() {
        let q = OfflineQueue(path: tempPath())
        let a = op("s", at: 300)
        let b = op("s", at: 100)
        let c = op("s", at: 200)
        q.enqueue(a); q.enqueue(b); q.enqueue(c)
        XCTAssertEqual(q.pending().map(\.id), [b.id, c.id, a.id])   // strict created_at order
        XCTAssertEqual(q.pendingCount, 3)
    }

    func testMarkRemovesFromPending() {
        let q = OfflineQueue(path: tempPath())
        let a = op("s", at: 100)
        q.enqueue(a)
        q.mark(a.id, state: .done)
        XCTAssertTrue(q.pending().isEmpty)
        XCTAssertEqual(q.pendingCount, 0)
    }

    func testPayloadRoundTrips() {
        let q = OfflineQueue(path: tempPath())
        let made = QueuedOp.make(kind: .photoUpload, sessionId: "s", json: ["path": "/tmp/x.jpg", "n": 3])
        q.enqueue(made)
        let back = q.pending().first
        XCTAssertEqual(back?.kind, .photoUpload)
        XCTAssertEqual(back?.payloadJSON["path"] as? String, "/tmp/x.jpg")
        XCTAssertEqual(back?.payloadJSON["n"] as? Int, 3)
    }

    func testSurvivesAppRestart() {
        let path = tempPath()
        let id: String
        do {
            let q = OfflineQueue(path: path)
            let a = op("s", at: 100)
            id = a.id
            q.enqueue(a)
        }   // released → db closed
        let reopened = OfflineQueue(path: path)
        XCTAssertEqual(reopened.pendingCount, 1)
        XCTAssertEqual(reopened.pending().first?.id, id)
    }

    func testCaptureRecordKindSurvivesRestart() throws {
        // BM P2: finished capture flows enqueue as the typed .captureRecord kind (not bare
        // .logEntry) and the kind round-trips through the SQLite store across a restart.
        let path = tempPath()
        var record = CaptureRecord(flowId: "asset_inspection_v1", sessionId: "s", assetId: "47B",
                                   startedAt: Date(timeIntervalSince1970: 1))
        record.set("gauge", value: .number(118, unit: "psig"),
                   provenance: Provenance(method: "voice_number", at: Date(timeIntervalSince1970: 2)))
        do {
            let q = OfflineQueue(path: path)
            q.enqueue(QueuedOp(kind: .captureRecord, sessionId: "s",
                               payload: try JSONEncoder().encode(record)))
        }   // released → db closed
        let reopened = OfflineQueue(path: path)
        let back = try XCTUnwrap(reopened.pending().first)
        XCTAssertEqual(back.kind, .captureRecord)
        let decoded = try JSONDecoder().decode(CaptureRecord.self, from: back.payload)
        XCTAssertEqual(decoded, record)
    }

    func testPurgeDoneTombstones() {
        let q = OfflineQueue(path: tempPath())
        let a = op("s", at: 100), b = op("s", at: 200)
        q.enqueue(a); q.enqueue(b)
        q.mark(a.id, state: .done)
        q.purgeDone()
        XCTAssertEqual(q.all().map(\.id), [b.id])   // done op gone, pending remains
    }

    // MARK: - Reachability

    func testReachabilityEdgeFiresOnChangeOnly() {
        let r = Reachability(startMonitoring: false, initiallyOnline: false)
        var events: [Bool] = []
        r.onChange = { events.append($0) }
        r.setOnline(true)
        r.setOnline(true)   // no change → no event
        r.setOnline(false)
        XCTAssertEqual(events, [true, false])
        XCTAssertFalse(r.isOnline)
    }

    // MARK: - SyncEngine

    func testFlushDeliversAllPending() async {
        let q = OfflineQueue(path: tempPath())
        q.enqueue(op("s", at: 100)); q.enqueue(op("s", at: 200))
        let engine = SyncEngine(queue: q, sink: LocalSyncSink())
        let delivered = await engine.flush()
        XCTAssertEqual(delivered, 2)
        XCTAssertEqual(q.pendingCount, 0)
        XCTAssertEqual(engine.lastSyncedCount, 2)
    }

    func testTransientErrorRetainsAndIncrementsAttempts() async {
        let q = OfflineQueue(path: tempPath())
        let a = op("s", at: 100)
        q.enqueue(a)
        let sink = FakeSink(); sink.defaultOutcome = .transient(reason: "no signal")
        let engine = SyncEngine(queue: q, sink: sink)

        _ = await engine.flush()
        let retained = q.pending().first
        XCTAssertEqual(retained?.id, a.id)            // still pending
        XCTAssertEqual(retained?.attempts, 1)         // attempt counted
    }

    func testTransientCapMarksFailed() async {
        let q = OfflineQueue(path: tempPath())
        q.enqueue(op("s", at: 100))
        let sink = FakeSink(); sink.defaultOutcome = .transient(reason: "x")
        let engine = SyncEngine(queue: q, sink: sink)
        engine.maxAttempts = 1
        _ = await engine.flush()
        XCTAssertEqual(q.pendingCount, 0)                          // not retried
        XCTAssertEqual(q.all().first?.state, .failed)
    }

    func testConflictIsSurfacedNotOverwritten() async {
        let q = OfflineQueue(path: tempPath())
        let a = op("s", at: 100)
        q.enqueue(a)
        let sink = FakeSink(); sink.defaultOutcome = .conflict(reason: "server moved on")
        let engine = SyncEngine(queue: q, sink: sink)
        var surfaced: String?
        engine.onConflict = { _, reason in surfaced = reason }
        _ = await engine.flush()
        XCTAssertEqual(q.all().first?.state, .conflict)
        XCTAssertEqual(surfaced, "server moved on")
        XCTAssertEqual(engine.lastConflictCount, 1)
    }

    func testSinkDeliveryIsIdempotent() async {
        let q = OfflineQueue(path: tempPath())
        let a = op("s", at: 100)
        q.enqueue(a)
        let sink = LocalSyncSink()
        let engine = SyncEngine(queue: q, sink: sink)
        _ = await engine.flush()
        q.enqueue(a)                  // same id re-enqueued (e.g. a flaky ack)
        _ = await engine.flush()
        XCTAssertEqual(sink.delivered.filter { $0 == a.id }.count, 1)   // delivered once
    }

    func testRisingEdgeTriggersFlush() async {
        let q = OfflineQueue(path: tempPath())
        q.enqueue(op("s", at: 100))
        let engine = SyncEngine(queue: q, sink: LocalSyncSink())
        let reachability = Reachability(startMonitoring: false, initiallyOnline: false)
        engine.bind(to: reachability)

        reachability.setOnline(true)                      // rising edge → flush
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(q.pendingCount, 0)
    }

    // MARK: - Plan BM P1: durability

    func testInFlightStrandRecoveredOnReopen() {
        let path = tempPath()
        let id: String
        do {
            let q = OfflineQueue(path: path)
            let a = op("s", at: 100)
            id = a.id
            q.enqueue(a)
            q.mark(a.id, state: .inFlight)          // killed mid-delivery
            XCTAssertTrue(q.pending().isEmpty)       // inFlight is invisible to pending()
        }
        let reopened = OfflineQueue(path: path)      // startup recovery re-arms it
        XCTAssertEqual(reopened.pendingCount, 1)
        XCTAssertEqual(reopened.pending().first?.id, id)
    }

    func testRecoverInFlightReturnsCount() {
        let q = OfflineQueue(path: tempPath())
        let a = op("s", at: 100), b = op("s", at: 200)
        q.enqueue(a); q.enqueue(b)
        q.mark(a.id, state: .inFlight)
        q.mark(b.id, state: .inFlight)
        XCTAssertEqual(q.recoverInFlight(), 2)
        XCTAssertEqual(q.pendingCount, 2)
        XCTAssertEqual(q.recoverInFlight(), 0)       // nothing left to recover
    }

    func testFlushDrainsBacklogBeyondBatchSize() async {
        let q = OfflineQueue(path: tempPath())
        for i in 0..<5 { q.enqueue(op("s", at: TimeInterval(i))) }
        let engine = SyncEngine(queue: q, sink: LocalSyncSink())
        engine.batchSize = 2                          // 5 ops, 2 per page → must loop
        let delivered = await engine.flush()
        XCTAssertEqual(delivered, 5)
        XCTAssertEqual(q.pendingCount, 0)
    }

    func testAllTransientBacklogTerminatesAndRetainsOncePerOp() async {
        let q = OfflineQueue(path: tempPath())
        for i in 0..<4 { q.enqueue(op("s", at: TimeInterval(i))) }
        let sink = FakeSink(); sink.defaultOutcome = .transient(reason: "no signal")
        let engine = SyncEngine(queue: q, sink: sink)
        engine.batchSize = 1                          // small page must not spin or skip ops
        _ = await engine.flush()
        XCTAssertEqual(q.pendingCount, 4)             // all retained, none lost
        XCTAssertEqual(Set(q.pending().map(\.attempts)), [1])  // each attempted exactly once
        XCTAssertEqual(sink.deliveredIds.count, 4)    // every op tried, no spin
    }

    func testFlushMaintenancePurgesDeliveredNonPhotoTombstones() async {
        let q = OfflineQueue(path: tempPath())
        q.enqueue(op("s", at: 100)); q.enqueue(op("s", at: 200))
        let engine = SyncEngine(queue: q, sink: LocalSyncSink())
        _ = await engine.flush()                      // delivers → done → maintenance purges
        XCTAssertTrue(q.all().isEmpty, "delivered log tombstones are reclaimed post-flush")
    }

    func testPurgeDoneKeepsPhotoTombstones() {
        let q = OfflineQueue(path: tempPath())
        let photo = QueuedOp.make(kind: .photoUpload, sessionId: "s", json: ["path": "/tmp/x.jpg"])
        let log = op("s", at: 100)
        q.enqueue(photo); q.enqueue(log)
        q.mark(photo.id, state: .done)
        q.mark(log.id, state: .done)
        q.purgeDone()
        // Photo tombstone survives (so prunePhotoEvidence can still manage its file); log is gone.
        XCTAssertEqual(q.all().map(\.id), [photo.id])
    }

    func testFlushPrunesDeliveredPhotoEvidencePastCap() async {
        let q = OfflineQueue(path: tempPath())
        let paths = (0..<3).map { _ in makePhotoFile(bytes: 100) }
        for p in paths {
            q.enqueue(QueuedOp.make(kind: .photoUpload, sessionId: "s", json: ["path": p]))
        }
        let engine = SyncEngine(queue: q, sink: LocalSyncSink())
        engine.photoEvidenceCapBytes = 150            // 300 bytes on disk, cap 150 → evict 2 oldest
        _ = await engine.flush()

        let onDisk = paths.filter { FileManager.default.fileExists(atPath: $0) }
        XCTAssertEqual(onDisk.count, 1, "only the newest delivered photo stays under the cap")
        XCTAssertEqual(q.all(limit: 500).filter { $0.kind == .photoUpload }.count, 1)
    }

    // MARK: - ConflictResolver

    func testConflictResolverDetectsServerAdvance() {
        let resolver = ConflictResolver()
        resolver.setKnownVersion(3, for: "s")
        XCTAssertEqual(resolver.resolve(op: op("s", at: 1), serverVersion: 3), .accept(newVersion: 3))
        guard case .conflict = resolver.resolve(op: op("s", at: 2), serverVersion: 5) else {
            return XCTFail("server advance should conflict")
        }
        XCTAssertEqual(resolver.knownVersion(for: "s"), 3, "a conflict must not move the baseline")
    }

    func testConflictDoesNotAdvanceBaselineForLaterOpsInTheSameFlush() {
        // The whole point of surfacing a conflict: every later op in that session is measured
        // against the version the device actually synced to, not the one that just conflicted.
        let resolver = ConflictResolver()
        resolver.setKnownVersion(3, for: "s")
        let first = resolver.resolve(op: op("s", at: 1), serverVersion: 5)
        let second = resolver.resolve(op: op("s", at: 2), serverVersion: 5)
        guard case .conflict(let firstReason) = first, case .conflict(let secondReason) = second else {
            return XCTFail("both ops in the flush should conflict")
        }
        XCTAssertEqual(firstReason, secondReason, "the delta is measured from the same baseline")
        XCTAssertEqual(resolver.knownVersion(for: "s"), 3)
    }

    func testAcknowledgeAdoptsServerVersionAndUnblocksTheNextOp() {
        let resolver = ConflictResolver()
        resolver.setKnownVersion(3, for: "s")
        guard case .conflict = resolver.resolve(op: op("s", at: 1), serverVersion: 5) else {
            return XCTFail("server advance should conflict")
        }
        resolver.acknowledge(serverVersion: 5, for: "s")
        XCTAssertEqual(resolver.knownVersion(for: "s"), 5)
        XCTAssertEqual(resolver.resolve(op: op("s", at: 2), serverVersion: 5), .accept(newVersion: 5))
    }

    func testAcceptAdvancesBaselineAndOtherSessionsAreIndependent() {
        let resolver = ConflictResolver()
        XCTAssertEqual(resolver.knownVersion(for: "s"), 0, "in-memory default starts fresh")
        XCTAssertEqual(resolver.resolve(op: op("s", at: 1), serverVersion: 0), .accept(newVersion: 0))
        resolver.setKnownVersion(2, for: "s")
        XCTAssertEqual(resolver.resolve(op: op("s", at: 2), serverVersion: 1), .accept(newVersion: 2),
                       "a server behind us keeps our higher baseline")
        XCTAssertEqual(resolver.knownVersion(for: "s"), 2)
        guard case .conflict = resolver.resolve(op: op("other", at: 3), serverVersion: 1) else {
            return XCTFail("a different session tracks its own baseline")
        }
        XCTAssertEqual(resolver.knownVersion(for: "s"), 2)
    }

    func testConflictBaselineSurvivesRestart() {
        // Backed by the queue file, a relaunch mid-outage must not reset the session to version 0
        // and manufacture a conflict on the first flush after restart.
        let path = tempPath()
        do {
            let queue = OfflineQueue(path: path)
            let resolver = ConflictResolver(store: queue)
            resolver.setKnownVersion(4, for: "s")
            XCTAssertEqual(resolver.resolve(op: op("s", at: 1), serverVersion: 7), .conflict(
                reason: "3 changes happened on the server while you were offline"))
            resolver.acknowledge(serverVersion: 7, for: "s")
        }   // released → db closed

        let reopened = OfflineQueue(path: path)
        let resolver = ConflictResolver(store: reopened)
        XCTAssertEqual(resolver.knownVersion(for: "s"), 7, "baseline persisted in the queue file")
        XCTAssertEqual(resolver.resolve(op: op("s", at: 2), serverVersion: 7), .accept(newVersion: 7),
                       "no spurious conflict on the first flush after relaunch")
        XCTAssertEqual(resolver.knownVersion(for: "unseen"), 0)
    }
}

/// Programmable `SyncSink` double.
@MainActor
private final class FakeSink: SyncSink {
    var defaultOutcome: SyncOutcome = .done
    var deliveredIds: [String] = []
    func deliver(_ op: QueuedOp) async -> SyncOutcome {
        deliveredIds.append(op.id)
        return defaultOutcome
    }
}
