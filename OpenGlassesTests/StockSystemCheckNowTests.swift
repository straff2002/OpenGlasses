import XCTest
@testable import OpenGlasses

/// The fixture transport with a delay before each reply: a slow system, for the check-now budget.
final class SlowStockSystemTransport: StockSystemTransport, @unchecked Sendable {
    let inner: FixtureStockSystemTransport
    let delay: TimeInterval

    init(_ inner: FixtureStockSystemTransport, delay: TimeInterval) {
        self.inner = inner
        self.delay = delay
    }

    func send(_ request: StockSystemRequest, to destination: StockSystemDestination,
              credential: StockSystemCredential) async throws -> StockSystemResponse {
        if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
        return try await inner.send(request, to: destination, credential: credential)
    }
}

/// Plan MM P3, Decision 10 — a `check` with a connection, signal and an old snapshot asks the
/// system for just the asked-about lines within 3 seconds; a late reply only refreshes the store.
@MainActor
final class StockSystemCheckNowTests: XCTestCase {

    private typealias F = SquareFixtures
    private typealias C = StockSystemConnectionSamples
    private var h: StockSystemVanStockHarness!
    private var fixtures: F.Transport!
    private var transport: FixtureStockSystemTransport!

    override func setUp() async throws {
        PolicyEnvelope.clear()
        h = StockSystemVanStockHarness()
        h.online = true
        fixtures = F.Transport()
        // The capacitor is now 7 at the main location.
        fixtures.overrides["/v2/inventory/counts/batch-retrieve"] = StockSystemResponse(status: 200, body: try F.json([
            "counts": [
                ["catalog_object_id": "VAR-CAP-455", "catalog_object_type": "ITEM_VARIATION", "state": "IN_STOCK",
                 "location_id": F.main, "quantity": "7"],
                ["catalog_object_id": "VAR-FILTER", "catalog_object_type": "ITEM_VARIATION", "state": "IN_STOCK",
                 "location_id": F.main, "quantity": "99"],
            ],
        ]))
        transport = FixtureStockSystemTransport.square(fixtures)
    }

    override func tearDown() async throws {
        h.cleanUp()
        PolicyEnvelope.clear()
    }

    /// The fixtures' own snapshot, pulled at 10:00, as the store's last good one; a connector over
    /// `delay`.
    private func connect(delay: TimeInterval = 0, budget: TimeInterval = StockSystemPolicy.checkNowBudget) async throws
        -> StockSystemService {
        let snapshot = try await F.pull().snapshot
        h.checkBudget = budget
        let slow = SlowStockSystemTransport(transport, delay: delay)
        h.makeConnector = { record, registration, reason in
            StockSystemService.httpConnector(transport: slow)(record, registration, reason)
        }
        h.clock = F.pulledAt
        return try h.connect(locations: [C.main], snapshot: snapshot)
    }

    private func figure(_ service: StockSystemService, _ itemID: String, at location: String = F.main) -> StockQuantity? {
        service.snapshot?.lines.first { $0.itemID == itemID }?.level(at: location)?.quantity
    }

    func testAFreshReplyWithinTheBudgetIsTheAnswer() async throws {
        let service = try await connect()
        h.clock = F.pulledAt.addingTimeInterval(20 * 60)
        let outcome = await service.checkNow(itemIDs: ["VAR-CAP-455"])
        XCTAssertEqual(outcome, .fresh)
        XCTAssertEqual(figure(service, "VAR-CAP-455"), .whole(7))
        XCTAssertEqual(figure(service, "VAR-CAP-455", at: F.van), .whole(1), "a location not asked keeps its figure")
        XCTAssertEqual(figure(service, "VAR-FILTER"), .whole(6), "only the asked lines change")
        XCTAssertEqual(service.snapshot?.asOf, F.pulledAt, "the snapshot's as-of stays the pull's")
        XCTAssertEqual(service.snapshot?.lines.first { $0.itemID == "VAR-CAP-455" }?.lineAsOf, h.clock)

        // One read, on the stock endpoint, for just that item.
        XCTAssertEqual(transport.sent.count, 1)
        let sent = try XCTUnwrap(transport.sent.first?.request)
        XCTAssertEqual(sent.endpoint, SquareStockAdapter.Endpoint.inventoryCounts)
        XCTAssertEqual(sent.jsonBody?["catalog_object_ids"] as? [String], ["VAR-CAP-455"])
        XCTAssertEqual(sent.jsonBody?["location_ids"] as? [String], [F.main])

        // The figures are now ten minutes young: no second read.
        let outcome1 = await service.checkNow(itemIDs: ["VAR-CAP-455"])
        XCTAssertEqual(outcome1, .skipped(.recent))
        XCTAssertEqual(transport.sent.count, 1)
    }

    func testTheToolAnswersWithTheFreshFigure() async throws {
        UserDefaults.standard.set(true, forKey: "fieldAssistEnabled")
        let entitlement = EntitlementTestScope.grant()
        defer {
            UserDefaults.standard.removeObject(forKey: "fieldAssistEnabled")
            EntitlementTestScope.restore(entitlement)
        }
        _ = try await connect()
        h.clock = F.pulledAt.addingTimeInterval(20 * 60)
        let answer = try await h.run(["action": "check", "part": "ZX-455"])
        XCTAssertTrue(answer.hasPrefix("7 × Run capacitor 45/5 (ZX-455) on the van in Square, as of 10:20."), answer)
    }

    func testALateReplyLeavesTheAnswerToTheSnapshotAndThenRefreshesTheStore() async throws {
        let service = try await connect(delay: 0.6, budget: 0.05)
        h.clock = F.pulledAt.addingTimeInterval(30 * 60)
        let answer = await h.vanStock.checkNow(.init(part: "ZX-455"))
        XCTAssertTrue(answer.hasPrefix("3 × Run capacitor 45/5 (ZX-455) on the van in Square, as of 10:00."),
                      "the snapshot's figure with its own time: \(answer)")
        XCTAssertEqual(figure(service, "VAR-CAP-455"), .whole(3), "nothing merged before the budget ran out")

        // The read was not cancelled: when it lands it refreshes the store.
        let deadline = Date().addingTimeInterval(5)
        while figure(service, "VAR-CAP-455") != .whole(7), Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(figure(service, "VAR-CAP-455"), .whole(7))
        XCTAssertEqual(h.vanStock.check(.init(part: "ZX-455")),
                       "7 × Run capacitor 45/5 (ZX-455) on the van in Square, as of 10:30.")
    }

    func testTheBudgetAloneSaysLate() async throws {
        let service = try await connect(delay: 0.6, budget: 0.05)
        h.clock = F.pulledAt.addingTimeInterval(30 * 60)
        let started = Date()
        let outcome2 = await service.checkNow(itemIDs: ["VAR-CAP-455"])
        XCTAssertEqual(outcome2, .late)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5, "the answer does not wait for the reply")
        XCTAssertEqual(StockSystemPolicy.checkNowBudget, 3)
        XCTAssertEqual(StockSystemPolicy.checkNowAfter, 600)
    }

    func testNoSignalLocalOnlyAndYoungFiguresSkipTheRead() async throws {
        let service = try await connect()
        h.clock = F.pulledAt.addingTimeInterval(5 * 60)
        let outcome3 = await service.checkNow(itemIDs: ["VAR-CAP-455"])
        XCTAssertEqual(outcome3, .skipped(.recent))

        h.clock = F.pulledAt.addingTimeInterval(20 * 60)
        h.online = false
        let outcome4 = await service.checkNow(itemIDs: ["VAR-CAP-455"])
        XCTAssertEqual(outcome4, .skipped(.offline))
        h.online = true
        h.medicalBlocked = true
        let outcome5 = await service.checkNow(itemIDs: ["VAR-CAP-455"])
        XCTAssertEqual(outcome5, .skipped(.localOnly))
        h.medicalBlocked = false
        let outcome6 = await service.checkNow(itemIDs: ["NOT-HELD"])
        XCTAssertEqual(outcome6, .skipped(.nothingAsked))
        XCTAssertTrue(transport.sent.isEmpty, "nothing was asked")
        XCTAssertEqual(figure(service, "VAR-CAP-455"), .whole(3))
    }

    func testAFailedReadAnswersFromTheSnapshot() async throws {
        fixtures.overrides["/v2/inventory/counts/batch-retrieve"] = try F.response("error-500.json", status: 500)
        let service = try await connect()
        h.clock = F.pulledAt.addingTimeInterval(20 * 60)
        let outcome7 = await service.checkNow(itemIDs: ["VAR-CAP-455"])
        XCTAssertEqual(outcome7, .failed)
        XCTAssertEqual(figure(service, "VAR-CAP-455"), .whole(3))
    }

    // MARK: - The merge

    func testTheMergeKeepsReasonsAndNeverPutsOlderFiguresOverNewer() async throws {
        let snapshot = try await F.pull().snapshot
        let readAt = F.pulledAt.addingTimeInterval(60)
        let fresh = StockSystemFreshLines(itemIDs: ["VAR-WELD", "VAR-COOL-5L", "VAR-GREASE"], locationIDs: [F.main, F.van],
                                          counts: ["VAR-COOL-5L": [F.main: "11", F.van: "0.0001"]])
        let merged = try XCTUnwrap(snapshot.merging(fresh, readAt: readAt))
        let weld = try XCTUnwrap(merged.lines.first { $0.itemID == "VAR-WELD" })
        XCTAssertEqual(weld.level(at: F.main), .unknown(.tooManyDecimals), "no figure keeps the reason it had")
        let coolant = try XCTUnwrap(merged.lines.first { $0.itemID == "VAR-COOL-5L" })
        XCTAssertEqual(coolant.level(at: F.main), .known(.whole(11)))
        XCTAssertEqual(coolant.level(at: F.van), .unknown(.tooManyDecimals), "a figure finer than the phone keeps is refused")
        let grease = try XCTUnwrap(merged.lines.first { $0.itemID == "VAR-GREASE" })
        XCTAssertEqual(grease, snapshot.lines.first { $0.itemID == "VAR-GREASE" }, "an unmapped unit keeps its figures")
        XCTAssertEqual(merged.asOf, snapshot.asOf)

        XCTAssertNil(merged.merging(fresh, readAt: readAt), "the same reading again changes nothing")
        XCTAssertNil(merged.merging(fresh, readAt: F.pulledAt.addingTimeInterval(30)), "an older reading never wins")
        XCTAssertNil(snapshot.merging(StockSystemFreshLines(itemIDs: [], locationIDs: [F.main], counts: [:]), readAt: readAt))
    }

    func testTheStoreWritesTheMergeLikeAPull() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("check-now-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = StockSystemSnapshotStore(directory: directory, connectorIDs: ["square"])
        XCTAssertFalse(store.merge(.init(itemIDs: ["VAR-CAP-455"], locationIDs: [F.main], counts: [:]), into: "square",
                                   readAt: F.pulledAt), "nothing to merge into")
        let pulled = try await F.pull().snapshot
        XCTAssertTrue(store.replace(pulled))
        XCTAssertTrue(store.merge(.init(itemIDs: ["VAR-CAP-455"], locationIDs: [F.main], counts: ["VAR-CAP-455": [F.main: "8"]]),
                                  into: "square", readAt: F.pulledAt.addingTimeInterval(60)))
        let reread = StockSystemSnapshotStore(directory: directory, connectorIDs: ["square"])
        XCTAssertEqual(reread.snapshot(for: "square")?.lines.first { $0.itemID == "VAR-CAP-455" }?.level(at: F.main),
                       .known(.whole(8)))
    }
}
