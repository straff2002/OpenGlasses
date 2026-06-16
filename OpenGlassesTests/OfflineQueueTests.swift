import XCTest
@testable import OpenGlasses

/// Tests for the offline field queue + store-and-forward sync (Plan T): the SQLite-backed
/// `OfflineQueue`, the reachability-driven `SyncEngine`, `Reachability`, and `ConflictResolver`.
/// Headless — the queue uses a throwaway file, sync uses fake sinks.
@MainActor
final class OfflineQueueTests: XCTestCase {

    private var tempFiles: [URL] = []

    override func tearDown() {
        for url in tempFiles {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
            }
        }
        tempFiles.removeAll()
        super.tearDown()
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

    // MARK: - ConflictResolver

    func testConflictResolverDetectsServerAdvance() {
        let resolver = ConflictResolver()
        resolver.setKnownVersion(3, for: "s")
        XCTAssertEqual(resolver.resolve(op: op("s", at: 1), serverVersion: 3), .accept(newVersion: 3))
        guard case .conflict = resolver.resolve(op: op("s", at: 2), serverVersion: 5) else {
            return XCTFail("server advance should conflict")
        }
        XCTAssertEqual(resolver.knownVersion(for: "s"), 5)   // baseline adopted
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
