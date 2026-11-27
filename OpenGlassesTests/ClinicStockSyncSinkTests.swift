import XCTest
@testable import OpenGlasses

/// Plan NK §2 — the `clinicStockRows` op on the offline queue and its sink: durable across a
/// relaunch, once each by key, waiting without an attempt when out of reach or signed out, ending
/// (and taking its rows back off the ledger) when the workbook changed or refused; and the client
/// that makes the two tables and refuses a patient-like column. No network: the workbook is a fixture.
@MainActor
final class ClinicStockSyncSinkTests: XCTestCase {

    private var directory: URL!
    private var queue: OfflineQueue!
    private var fixture: ClinicWorkbookFixtureTransport!
    private var connection: ClinicStockSyncSink.Connection = .removed
    private var delivered: [ClinicStockQueuedBatch] = []
    private var abandoned: [[String]] = []

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        queue = OfflineQueue(path: directory.appendingPathComponent("queue.sqlite"))
        fixture = ClinicWorkbookFixtureTransport.withTables()
        connection = .connected(fixture.client())
        delivered = []
        abandoned = []
    }

    override func tearDown() async throws {
        queue = nil
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    private func sink(queue: OfflineQueue? = nil) -> ClinicStockSyncSink {
        ClinicStockSyncSink(queue: queue ?? self.queue, fallback: LocalSyncSink(), seams: .init(
            connection: { [weak self] in self?.connection ?? .removed },
            delivered: { [weak self] in self?.delivered.append($0) },
            abandoned: { [weak self] _, keys in self?.abandoned.append(keys) }))
    }

    private var rows: [KeyedShareRow] {
        ClinicWorkbookSamples.keyed([ClinicWorkbookSamples.row(.received, 20), ClinicWorkbookSamples.row(.given, 3),
                                     ClinicWorkbookSamples.row(.counted, 17)])
    }

    private func op() throws -> QueuedOp { try XCTUnwrap(queue.pending().first) }

    // MARK: - On the queue

    func testTheBatchIsAClinicStockRowsOpThatSurvivesARelaunch() throws {
        let sink = sink()
        XCTAssertNil(sink.enqueue([], workbook: fixture.workbook, batchID: "empty"), "nothing to send queues nothing")
        let batch = try XCTUnwrap(sink.enqueue(rows, workbook: fixture.workbook, batchID: "b1"))
        XCTAssertEqual(batch.rows, rows)
        let reopened = OfflineQueue(path: directory.appendingPathComponent("queue.sqlite"))
        let stored = try XCTUnwrap(reopened.pending().first)
        XCTAssertEqual(stored.kind, .clinicStockRows)
        XCTAssertEqual(OpKind(rawValue: "clinicStockRows"), .clinicStockRows)
        XCTAssertEqual(ClinicStockSyncSink.decode(stored.payload)?.rows, rows)
        XCTAssertEqual(self.sink(queue: reopened).rowsQueued, 3)
    }

    func testOtherKindsGoOnToTheFallback() async {
        let outcome = await sink().deliver(QueuedOp(kind: .logEntry, sessionId: "s"))
        XCTAssertEqual(outcome, .done)
    }

    // MARK: - Once each

    func testDeliveryAddsEachRowToItsTableOnce() async throws {
        let sink = sink()
        sink.enqueue(rows, workbook: fixture.workbook, batchID: "b1")
        let outcome = await sink.deliver(try op())
        XCTAssertEqual(outcome, .done)
        XCTAssertEqual(fixture.rows(of: .movements).count, 2)
        XCTAssertEqual(fixture.rows(of: .counts).count, 1)
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(sink.batches(op: try XCTUnwrap(queue.all().first)).status, ClinicStockSyncSink.sentLine)
        queue.mark(try op().id, state: .done)

        // The same batch again — a retry after a reply that never came — adds nothing.
        sink.enqueue(rows, workbook: fixture.workbook, batchID: "b2")
        let again = await sink.deliver(try op())
        XCTAssertEqual(again, .done)
        XCTAssertEqual(fixture.rows(of: .movements).count, 2)
        XCTAssertEqual(fixture.rows(of: .counts).count, 1)
        XCTAssertTrue(fixture.bearers.allSatisfy { $0 == "token-1" })
    }

    func testAnExpiredSignInIsAnsweredOnceWithAFreshToken() async throws {
        let sink = sink()
        sink.enqueue(rows, workbook: fixture.workbook, batchID: "b1")
        fixture.nextStatus = 401
        let outcome = await sink.deliver(try op())
        XCTAssertEqual(outcome, .done)
        XCTAssertEqual(Array(fixture.bearers.prefix(2)), ["token-1", "token-2"] as [String?])
    }

    // MARK: - Waiting and ending

    func testOutOfReachOrSignedOutWaitsWithoutAnAttempt() async throws {
        let sink = sink()
        sink.enqueue(rows, workbook: fixture.workbook, batchID: "b1")
        fixture.failNext = .unreachable
        let waiting = await sink.deliver(try op())
        guard case .waiting = waiting else { return XCTFail("\(waiting)") }
        connection = .connected(fixture.client(refreshed: nil))
        fixture.nextStatus = 401
        let signedOut = await sink.deliver(try op())
        guard case .waiting(let reason) = signedOut else { return XCTFail("\(signedOut)") }
        XCTAssertEqual(reason, ClinicWorkbookFailure.unauthorized.sentence)
        XCTAssertTrue(abandoned.isEmpty)
        XCTAssertTrue(fixture.rows(of: .movements).isEmpty)
    }

    func testARefusedFileEndsTheBatchAndTakesItsRowsBack() async throws {
        let sink = sink()
        sink.enqueue(rows, workbook: fixture.workbook, batchID: "b1")
        fixture.nextStatus = 403
        let outcome = await sink.deliver(try op())
        XCTAssertEqual(outcome, .permanent(reason: ClinicWorkbookFailure.forbidden.sentence))
        XCTAssertEqual(abandoned, [rows.map(\.key)])
    }

    func testAnotherWorkbookOrNoConnectionEndsTheBatch() async throws {
        let sink = sink()
        sink.enqueue(rows, workbook: fixture.workbook, batchID: "b1")
        connection = .connected(fixture.client(workbook: GraphWorkbook(driveID: "b!other", itemID: "02")!))
        let changed = await sink.deliver(try op())
        XCTAssertEqual(changed, .permanent(reason: ClinicStockSyncSink.endedLine))
        XCTAssertEqual(abandoned.count, 1)

        let second = self.sink(queue: queue)
        second.enqueue(rows, workbook: fixture.workbook, batchID: "b2")
        connection = .removed
        let removed = await second.deliver(try XCTUnwrap(queue.pending().first { $0.id.hasSuffix("b2") }))
        XCTAssertEqual(removed, .permanent(reason: ClinicStockSyncSink.endedLine))
        XCTAssertTrue(fixture.rows(of: .movements).isEmpty)
    }

    func testEndAllEndsWhatIsQueued() throws {
        let sink = sink()
        sink.enqueue(rows, workbook: fixture.workbook, batchID: "b1")
        sink.endAll()
        XCTAssertTrue(queue.pending().isEmpty)
        XCTAssertEqual(abandoned, [rows.map(\.key)])
        XCTAssertEqual(sink.rowsQueued, 0)
    }

    // MARK: - The client

    func testMissingTablesAreMadeWithTheirFixedHeadings() async throws {
        let empty = ClinicWorkbookFixtureTransport()
        let made = try await empty.client().ensureTables()
        XCTAssertEqual(made, [.movements, .counts])
        XCTAssertEqual(empty.tables.map(\.name), ["Movements", "Counts"])
        XCTAssertEqual(empty.tables.map(\.headers), ClinicalStockWorkbookTable.allCases.map(\.headers))
        let none = try await empty.client().ensureTables()
        XCTAssertTrue(none.isEmpty, "a workbook with both tables is left as it is")
    }

    func testAPatientColumnStaffAddedStopsReadingAndWriting() async throws {
        var tables = fixture.tables
        tables[0].headers.append("Patient name")
        fixture.setTables(tables)
        let read = try await fixture.client().read()
        XCTAssertEqual(read.failureValue, .patientColumns(["Patient name"]))
        do {
            _ = try await fixture.client().append(rows)
            XCTFail("rows were written beside a patient column")
        } catch {
            XCTAssertEqual(error as? ClinicWorkbookSetupError, .refused(.patientColumns(["Patient name"])))
        }
        XCTAssertTrue(fixture.rows(of: .movements).isEmpty)
    }

    func testRowsReadBackPageByPageAndFoldToTheSharedFigure() async throws {
        var tables = fixture.tables
        let one: [Any] = ["2026-11-25", "Day", "8161", "Flu vaccine", "ZZ1001", "", "received", 1, "", ""]
        tables[0].rows = Array(repeating: one, count: GraphRequestBuilder.pageSize + 3)
        fixture.setTables(tables)
        let read = try await fixture.client().read().get()
        XCTAssertEqual(read.entries.count, GraphRequestBuilder.pageSize + 3)
        let figures = ClinicalStockWorkbookFold.fold(read.entries)
        XCTAssertEqual(figures[ClinicalStockLineIdentity(number: "8161", name: "")]?.onHand,
                       StockQuantity(whole: GraphRequestBuilder.pageSize + 3))
        XCTAssertEqual(fixture.seen.filter { $0.path.hasSuffix("/Movements/rows") }.count, 2)
    }

    func testTheSignInReadsTheAccountAndTheCountryOnly() async throws {
        fixture.country = "US"
        let client = fixture.client()
        let account = try await client.account()
        let country = try await client.country()
        XCTAssertEqual(account, "staff@clinic.example")
        XCTAssertEqual(TenantCountryNotice(countryLetterCode: country), .notice(country: "US"))
        let item = try await client.resolve(link: "https://clinic.sharepoint.com/:x:/s/stock/EaBc")
        XCTAssertEqual(item.workbook, fixture.workbook)
        do {
            _ = try await client.resolve(link: "https://example.invalid/x")
            XCTFail("a link outside Microsoft 365 was resolved")
        } catch {
            XCTAssertEqual(error as? ClinicWorkbookSetupError, .notASharingLink)
        }
    }

    // MARK: - The service's ledger

    func testASendRecordsTheLedgerSoTheNextSendAddsOnlyWhatChanged() async throws {
        let keychain = ClinicWorkbookMemoryKeychain()
        let store = ClinicWorkbookConnectionStore(storage: keychain.storage)
        let credentials = EntraOAuth.Credentials(response: try XCTUnwrap(EntraOAuth.parseToken(Data(#"{"access_token":"t"}"#.utf8))),
                                                 now: Date())
        store.save(ClinicWorkbookConnectionRecord(clientID: "11111111-2222-3333-4444-555555555555", credentials: credentials,
                                                  account: nil, workbook: fixture.workbook, workbookName: "Fridge.xlsx",
                                                  country: "CA", lastSentAt: nil))
        var log = VanStockLog()
        _ = log.addItem(id: "flu", number: "8161", description: "Flu vaccine", batch: "b0")
        log.record(.loaded, itemID: "flu", quantity: StockQuantity(whole: 5), at: Date(), batch: "b1", source: .typed)
        var seams = ClinicWorkbookService.Seams()
        seams.transport = fixture
        seams.bundledClientID = { "11111111-2222-3333-4444-555555555555" }
        seams.clinicClientID = { nil }
        var planned: String?
        seams.lastPlanned = { planned }
        seams.setLastPlanned = { planned = $0 }
        seams.stock = { (log, true, true) }
        let service = ClinicWorkbookService(store: store, seams: seams)
        let sink = ClinicStockSyncSink(queue: queue, fallback: LocalSyncSink(), seams: .init(
            connection: { service.queueConnection() }, delivered: { service.delivered($0) },
            abandoned: { service.abandoned($1, workbook: $0) }))
        service.sink = sink
        let queue: OfflineQueue = self.queue
        service.flush = {
            for op in queue.pending() { _ = await sink.deliver(op); queue.mark(op.id, state: .done) }
        }

        let first = await service.send(.onDemand)
        XCTAssertEqual(first, 1)
        XCTAssertEqual(fixture.rows(of: .movements).count, 1)
        XCTAssertNotNil(planned)
        let again = await service.send(.dailyCheck)
        XCTAssertEqual(again, 0, "the same day sent twice adds nothing")
        log.record(.used, itemID: "flu", quantity: StockQuantity(whole: 2), at: Date(), batch: "b2", source: .spoken)
        let topUp = await service.send(.onDemand)
        XCTAssertEqual(topUp, 1)
        XCTAssertEqual(fixture.rows(of: .movements).count, 2)
        XCTAssertNotNil(store.record?.lastSentAt)
        XCTAssertFalse(ClinicStockSendPolicy.isDueOnLaunch(lastPlanned: planned.flatMap(StockDay.init(iso:)),
                                                           today: StockDay(Date(), calendar: .current)))
        XCTAssertTrue(ClinicStockSendPolicy.isDueOnLaunch(lastPlanned: nil, today: StockDay(Date(), calendar: .current)))
        XCTAssertTrue(service.reportLines.joined().contains("connected"))
        XCTAssertFalse(service.reportLines.joined().contains("t\""), "no token in the report")
        XCTAssertFalse(service.reportLines.joined().contains("sharepoint"), "no link in the report")
    }
}

private extension ClinicStockSyncSink {
    func batches(op: QueuedOp) -> ClinicStockQueuedBatch {
        Self.decode(op.payload)!
    }
}

private extension Result {
    var failureValue: Failure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}
