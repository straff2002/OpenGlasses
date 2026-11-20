import XCTest
@testable import OpenGlasses

/// Plan MM P2 — when the phone pulls from the business's stock system: on foreground and on the
/// Stock screen at most every 10 minutes, on pull-to-refresh always, one pull at a time, a failure
/// keeping the last good snapshot, nothing under Medical Local Only, and the office route retiring
/// everything. Test connection's line and the preselected location.
@MainActor
final class StockSystemServiceTests: XCTestCase {

    private typealias C = StockSystemConnectionSamples
    private var memory: MemoryStockSystemStorage!
    private var directory: URL!
    private var clock = StockSystemSamples.pulledAt
    private var medicalBlocked = false
    private var place: String?
    private var connector: ScriptedStockSystemConnector!
    private var made = 0

    override func setUp() async throws {
        PolicyEnvelope.clear()
        memory = MemoryStockSystemStorage()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("StockSystemServiceTests-\(UUID().uuidString)")
        clock = StockSystemSamples.pulledAt
        medicalBlocked = false
        place = nil
        made = 0
        connector = ScriptedStockSystemConnector(snapshot: .success(C.snapshot()), probe: .success(C.probe()))
    }

    override func tearDown() async throws {
        PolicyEnvelope.clear()
        try? FileManager.default.removeItem(at: directory)
    }

    private func service(locations: [StockSystemLocation] = [C.main]) throws -> StockSystemService {
        let connection = StockSystemConnectionStore(storage: memory.storage, connectorIDs: ["square"], licensed: { true })
        try connection.pasteKey(C.key(), environment: .production, administrator: false, hasSandbox: true)
        if !locations.isEmpty { try connection.chooseLocations(locations) }
        return StockSystemService(
            connection: connection, store: StockSystemSnapshotStore(directory: directory, connectorIDs: ["square"]),
            registry: { StockSystemAdapterRegistry.registration(for: $0) },
            now: { [unowned self] in self.clock },
            medicalBlocks: { [unowned self] _ in self.medicalBlocked },
            placeName: { [unowned self] in self.place },
            makeConnector: { [unowned self] _, _, _ in
                self.made += 1
                return self.connector
            })
    }

    // MARK: - Triggers

    func testAutomaticPullsWaitTenMinutesAndPullToRefreshDoesNot() async throws {
        let service = try service()
        await service.appBecameActive()
        XCTAssertEqual(connector.pulls, 1)
        XCTAssertEqual(service.snapshot, C.snapshot())

        clock = clock.addingTimeInterval(5 * 60)
        await service.stockScreenOpened()
        await service.appBecameActive()
        XCTAssertEqual(connector.pulls, 1, "within ten minutes nothing is pulled again")

        await service.refresh()
        XCTAssertEqual(connector.pulls, 2, "pull-to-refresh always pulls")

        clock = clock.addingTimeInterval(9 * 60 + 59)
        await service.stockScreenOpened()
        XCTAssertEqual(connector.pulls, 2)
        clock = clock.addingTimeInterval(1)
        await service.stockScreenOpened()
        XCTAssertEqual(connector.pulls, 3, "ten minutes after the last pull, the Stock screen pulls")
        XCTAssertEqual(StockSystemService.automaticPullInterval, 600)
    }

    func testOnePullAtATime() async throws {
        let service = try service()
        connector.hold()
        let first = Task { await service.refresh() }
        while connector.heldCount == 0 { await Task.yield() }
        XCTAssertTrue(service.pulling)
        let second = Task { await service.refresh() }
        let third = Task { await service.stockScreenOpened() }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(connector.pulls, 1, "a second caller waits for the pull under way")
        connector.release()
        await first.value
        await second.value
        await third.value
        XCTAssertEqual(connector.pulls, 1)
        XCTAssertFalse(service.pulling)
        await service.refresh()
        XCTAssertEqual(connector.pulls, 2, "once it ends, the next one may start")
    }

    func testAFailedPullKeepsTheLastGoodSnapshotAndSaysWhy() async throws {
        let service = try service()
        await service.refresh()
        let good = try XCTUnwrap(service.snapshot)
        connector.snapshot = .failure(StockSystemFailure.unreachable)
        await service.refresh()
        XCTAssertEqual(service.snapshot, good)
        XCTAssertEqual(service.pullMessage, StockSystemFailure.unreachable.sentence(system: "Square"))
        connector.snapshot = .failure(StockSystemFailure.unauthorized(.expired))
        await service.refresh()
        XCTAssertEqual(service.snapshot, good)
        XCTAssertTrue(service.pullMessage?.contains("Settings › Field Assist › Stock system") == true)
        connector.snapshot = .success(C.snapshot(part: "ZX-9"))
        await service.refresh()
        XCTAssertNil(service.pullMessage)
        XCTAssertEqual(service.snapshot?.lines.first?.part, "ZX-9")
    }

    func testMedicalLocalOnlyPullsNothingAndKeepsTheSnapshotWithItsAge() async throws {
        let service = try service()
        await service.refresh()
        let good = try XCTUnwrap(service.snapshot)
        medicalBlocked = true
        clock = clock.addingTimeInterval(3600)
        await service.refresh()
        await service.testConnection()
        XCTAssertEqual(connector.pulls, 1)
        XCTAssertEqual(connector.probes, 0)
        XCTAssertEqual(service.snapshot, good)
        XCTAssertEqual(service.pullMessage, MedicalEgressRefusal.userMessage)
        XCTAssertEqual(service.statusLine, StockSystemService.statusLine(system: "Square", asOf: good.asOf, now: clock),
                       "the figures keep their own time")
        XCTAssertEqual(good.asOf, StockSystemSamples.pulledAt)
        XCTAssertTrue(service.isBlockedByMedical)
    }

    func testNothingIsPulledBeforeAStockLocationIsChosen() async throws {
        let service = try service(locations: [])
        await service.refresh()
        XCTAssertEqual(connector.pulls, 0)
        XCTAssertEqual(StockAuthority.resolve(officeRoute: false, connection: service.connection.authorityConnection), .phone,
                       "with no location chosen the phone still answers")
    }

    func testTheOfficeRouteStopsPullsErasesAndRetires() async throws {
        let service = try service()
        await service.refresh()
        XCTAssertNotNil(service.snapshot)
        var result = ProfileApplier.Result()
        result.ceilings[.organizationFieldServiceRoute] = .string("office")
        PolicyEnvelope.install(result, organizationName: "Office firm")
        await service.refresh()
        XCTAssertEqual(connector.pulls, 1)
        XCTAssertNil(service.snapshot)
        XCTAssertTrue(memory.items.isEmpty)
        XCTAssertFalse(service.isRunning)
    }

    func testAReplyToAnOldKeyIsNotKept() async throws {
        let service = try service()
        connector.hold()
        let pull = Task { await service.refresh() }
        while connector.heldCount == 0 { await Task.yield() }
        try service.connection.pasteKey(C.key("z"), environment: .production, administrator: false, hasSandbox: true)
        connector.release()
        await pull.value
        XCTAssertNil(service.snapshot, "the reply was asked for with the key that was replaced")
    }

    func testChoosingOtherLocationsRetiresTheSnapshotAndPulls() async throws {
        let service = try service()
        await service.refresh()
        XCTAssertNotNil(service.snapshot)
        connector.snapshot = .success(C.snapshot(part: "ZX-VAN"))
        try await service.chooseLocations([C.main, C.van])
        XCTAssertEqual(connector.pulls, 2)
        XCTAssertEqual(service.snapshot?.lines.first?.part, "ZX-VAN")
        XCTAssertEqual(service.connection.record?.locationIDs, [C.main.id, C.van.id])
    }

    // MARK: - Test connection

    func testTestConnectionSaysWhatWorksAndPreselectsTheOneMatchingLocation() async throws {
        let service = try service(locations: [])
        place = "  main STREET "
        await service.testConnection()
        XCTAssertEqual(service.connectionLine, "Connected to Square. Stock ✓ Items ✓ — sending back is off.")
        XCTAssertEqual(service.availableLocations, [C.main, C.van])
        XCTAssertEqual(service.connection.record?.locationIDs, [C.main.id])
        XCTAssertEqual(connector.pulls, 1, "a good test pulls at once")
        XCTAssertNotNil(service.snapshot)

        try service.connection.setSendingBack(true)
        await service.testConnection()
        XCTAssertEqual(service.connectionLine, "Connected to Square. Stock ✓ Items ✓ — sending back is on.")
    }

    func testNoLocationIsGuessedUnlessExactlyOneMatches() {
        let twin = StockSystemLocation(id: "LOC-2", name: "Main Street")
        XCTAssertNil(StockSystemService.preselect([C.main, twin], placeName: "Main Street"))
        XCTAssertNil(StockSystemService.preselect([C.main, C.van], placeName: "Workshop"))
        XCTAssertNil(StockSystemService.preselect([C.main], placeName: nil))
        XCTAssertEqual(StockSystemService.preselect([C.main, C.van], placeName: "van 1"), C.van)
    }

    func testAMissingPermissionIsNamed() async throws {
        let service = try service()
        connector.probeResult = .success(C.probe(missing: "INVENTORY_READ"))
        await service.testConnection()
        XCTAssertEqual(service.connectionLine, StockSystemFailure.missingScope("INVENTORY_READ").sentence(system: "Square"))
        XCTAssertTrue(service.connectionLine?.contains("INVENTORY_READ") == true)
        XCTAssertEqual(connector.pulls, 0, "a failing test pulls nothing")

        connector.probeResult = .failure(StockSystemFailure.unauthorized(.revoked))
        await service.testConnection()
        XCTAssertEqual(service.connectionLine, StockSystemFailure.unauthorized(.revoked).sentence(system: "Square"))
    }

    // MARK: - Words

    func testTheStatusLineSaysWhereAndWhen() {
        let now = StockSystemSamples.date(2026, 11, 20, 12, 0)
        let today = StockSystemService.statusLine(system: "Square", asOf: StockSystemSamples.date(2026, 11, 20, 9, 10),
                                                   now: now, calendar: StockSystemSamples.calendar)
        XCTAssertEqual(today, "From Square at 09:10")
        let yesterday = StockSystemService.statusLine(system: "Square", asOf: StockSystemSamples.date(2026, 11, 19, 16, 10),
                                                       now: now, calendar: StockSystemSamples.calendar)
        XCTAssertEqual(yesterday, "From Square, yesterday at 16:10")
    }

    func testFailuresAreSaidInTheSystemsWords() {
        XCTAssertEqual(StockSystemService.sentence(StockSystemFailure.rateLimited(retryAfter: 3), system: "Square"),
                       StockSystemFailure.rateLimited(retryAfter: 3).sentence(system: "Square"))
        XCTAssertEqual(StockSystemService.sentence(MedicalEgressRefusal(route: .squareStockAPI), system: "Square"),
                       MedicalEgressRefusal.userMessage)
        XCTAssertTrue(StockSystemService.sentence(StockSystemTransportRefusal.redirected, system: "Square").contains("Nothing was sent"))
        XCTAssertEqual(StockSystemService.sentence(URLError(.timedOut), system: "Square"),
                       StockSystemFailure.unreachable.sentence(system: "Square"))
    }
}
