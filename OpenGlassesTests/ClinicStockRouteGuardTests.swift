import XCTest
@testable import OpenGlasses

/// Plan NK §4 — the workbook route: its payload is `ClinicalStockShareRow` and its key and nothing
/// else; its medical policy is `.notApplicable` because the destination is the clinic's own record
/// system, as the FHIR export's is; and a van's list never uses it.
@MainActor
final class ClinicStockRouteGuardTests: XCTestCase {

    private let workbook = GraphWorkbook(driveID: "b!drive-1", itemID: "01ITEM")!

    // MARK: - The payload

    func testTheRoutesPayloadIsShareRowsAndTheirKeysAndNothingElse() throws {
        let batch = ClinicStockQueuedBatch(batchID: "b1", workbook: workbook,
                                           rows: ClinicWorkbookSamples.keyed([ClinicWorkbookSamples.row(.given, 3)]),
                                           queuedAt: Date(), status: "")
        let fields = Set(Mirror(reflecting: batch).children.compactMap(\.label))
        XCTAssertEqual(fields, ["version", "batchID", "workbook", "rows", "queuedAt", "applied", "failureCode", "status"],
                       "a new field on the queued batch is a decision: say what it is and update this list")
        let keyed = try XCTUnwrap(batch.rows.first)
        let children = Mirror(reflecting: keyed).children
        XCTAssertEqual(children.compactMap(\.label), ["row", "key"])
        XCTAssertTrue(children.first?.value is ClinicalStockShareRow, "the route carries ClinicalStockShareRow and nothing else")
        XCTAssertTrue(type(of: batch.rows) == [KeyedShareRow].self)
        // The builder adds only keyed share rows: its signature takes nothing else.
        let add: ([KeyedShareRow], ClinicalStockWorkbookTable, [String]?, GraphWorkbook) -> GraphRequest? = GraphRequestBuilder.addRows
        XCTAssertNotNil(add(batch.rows, .movements, nil, workbook))
    }

    func testTheQueuedPayloadCarriesNoTokenTimeOrPerson() throws {
        let row = ClinicWorkbookSamples.row(.wasted, 1)
        let batch = ClinicStockQueuedBatch(batchID: "b1", workbook: workbook, rows: ClinicWorkbookSamples.keyed([row]),
                                           queuedAt: Date(), status: "Waiting")
        let text = String(data: try ClinicStockSyncSink.encoder.encode(batch), encoding: .utf8) ?? ""
        for word in ["token", "access", "refresh", "Bearer", "staff", "patient", "jobReference", "\"at\""] {
            XCTAssertFalse(text.contains(word), "the queued rows say \(word)")
        }
    }

    // MARK: - The route

    func testTheRouteIsTheClinicsOwnRecordSystemAndNotApplicableToLocalOnly() throws {
        let route = NetworkRoute.clinicStockRecord
        guard case .notApplicable(let why) = route.medicalPolicy else { return XCTFail("\(route.medicalPolicy)") }
        XCTAssertTrue(why.contains("the clinic's own record system"), why)
        XCTAssertEqual(route.dataClasses, [.inventoryRows, .credential])
        XCTAssertEqual(route.endpointClass, .userConfiguredCloud)
        XCTAssertEqual(route.owningTypes, ["URLSessionClinicWorkbookTransport"])
        XCTAssertEqual(NetworkRouteRegistry.route(owningType: "URLSessionClinicWorkbookTransport"), .clinicStockRecord)
        XCTAssertTrue(MedicalEgressGuard.decide(route, mode: .localOnly).isAllowed)
        XCTAssertNil(NetworkDataClass.inventoryRows.privacyManifestType, "the clinic's vials, in the clinic's own tenant")
        XCTAssertTrue(route.purpose.contains("never a person"))
    }

    func testTheRefusalSentenceStillExceptsTheOwnRecordSystem() {
        XCTAssertTrue(MedicalEgressRefusal(route: .webSearch).description.contains("except to your own record system"))
    }

    // MARK: - A van's list

    func testAVansListIsRefusedTheRoute() {
        let client = EntraOAuth.Client.bundled("11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(ClinicStockRouteGate(clinical: false, client: client, signedIn: true, workbook: workbook), .notClinical)
        XCTAssertFalse(ClinicStockRouteGate(clinical: false, client: client, signedIn: true, workbook: workbook).allows)
        XCTAssertEqual(ClinicStockRouteGate(clinical: true, client: .notSetUp, signedIn: false, workbook: nil), .notSetUp)
        XCTAssertEqual(ClinicStockRouteGate(clinical: true, client: client, signedIn: false, workbook: nil), .signedOut)
        XCTAssertEqual(ClinicStockRouteGate(clinical: true, client: client, signedIn: true, workbook: nil), .noWorkbook)
        XCTAssertEqual(ClinicStockRouteGate(clinical: true, client: client, signedIn: true, workbook: workbook), .allowed)
    }

    /// End to end on the service: a connected phone whose list is a van's plans nothing, queues
    /// nothing and hands the queue no connection.
    func testAVansListSendsNothingEvenWhenConnected() async throws {
        let keychain = ClinicWorkbookMemoryKeychain()
        let store = ClinicWorkbookConnectionStore(storage: keychain.storage)
        let credentials = EntraOAuth.Credentials(response: try XCTUnwrap(EntraOAuth.parseToken(Data(#"{"access_token":"t"}"#.utf8))),
                                                 now: Date())
        store.save(ClinicWorkbookConnectionRecord(clientID: "11111111-2222-3333-4444-555555555555", credentials: credentials,
                                                  account: nil, workbook: workbook, workbookName: "Fridge.xlsx",
                                                  country: "CA", lastSentAt: nil))
        var log = VanStockLog()
        _ = log.addItem(id: "flu", number: "8161", description: "Flu vaccine", batch: "b0")
        log.record(.loaded, itemID: "flu", quantity: StockQuantity(whole: 5), at: Date(), batch: "b1", source: .typed)
        let fixture = ClinicWorkbookFixtureTransport.withTables()
        var clinical = false
        var seams = ClinicWorkbookService.Seams()
        seams.transport = fixture
        seams.bundledClientID = { "11111111-2222-3333-4444-555555555555" }
        seams.clinicClientID = { nil }
        seams.lastPlanned = { nil }
        seams.setLastPlanned = { _ in }
        seams.stock = { (log, clinical, true) }
        let service = ClinicWorkbookService(store: store, seams: seams)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = OfflineQueue(path: directory.appendingPathComponent("queue.sqlite"))
        service.sink = ClinicStockSyncSink(queue: queue, fallback: LocalSyncSink(),
                                           seams: .init(connection: { service.queueConnection() }))

        XCTAssertEqual(service.gate, .notClinical)
        let none = await service.send(.onDemand)
        XCTAssertEqual(none, 0)
        XCTAssertTrue(queue.all().isEmpty)
        if case .connected = service.queueConnection() { XCTFail("a van's list was handed the route") }
        XCTAssertTrue(fixture.seen.isEmpty, "nothing reached Microsoft")

        clinical = true
        XCTAssertEqual(service.gate, .allowed)
        let some = await service.send(.onDemand)
        XCTAssertEqual(some, 1)
        XCTAssertEqual(queue.all().map(\.kind), [.clinicStockRows])
    }
}
