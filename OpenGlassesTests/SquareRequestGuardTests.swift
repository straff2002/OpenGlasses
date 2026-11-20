import XCTest
@testable import OpenGlasses

/// Plan MM P1 — the Square adapter can only ever emit its five requests, its one write is an
/// adjustment from in stock to waste, and no request carries or describes a key.
final class SquareRequestGuardTests: XCTestCase {

    private typealias F = SquareFixtures
    private let adapter = SquareFixtures.adapter

    private static let allowed: Set<String> = [
        "GET /v2/locations",
        "POST /v2/catalog/search",
        "POST /v2/inventory/counts/batch-retrieve",
        "POST /v2/inventory/changes/batch-retrieve",
        "POST /v2/inventory/changes/batch-create",
    ]

    func testTheAllowedListIsExactlyTheFiveEndpoints() {
        XCTAssertEqual(Set(adapter.allowedEndpoints.map(\.description)), Self.allowed)
        XCTAssertEqual(adapter.allowedEndpoints.count, 5)
        XCTAssertEqual(adapter.allowedEndpoints.filter(\.writes).map(\.description), ["POST /v2/inventory/changes/batch-create"])
        for endpoint in adapter.allowedEndpoints {
            XCTAssertFalse(endpoint.path.contains("{"), "Square's paths take no parameters")
            XCTAssertNotNil(endpoint.scope)
        }
    }

    /// Every request every operation builds, across every fixture: only the five, each with its
    /// exact path, and the only write the one write.
    func testEveryRequestTheAdapterBuildsIsOnTheList() async throws {
        var requests: [StockSystemRequest] = []

        let pullTransport = F.Transport()
        _ = try await F.pull(transport: pullTransport)
        _ = try await F.pull(pricesEnabled: true, transport: pullTransport)
        requests += pullTransport.sent

        let locationsTransport = F.Transport()
        _ = try await StockSystemPlanDriver.run(adapter.locationsPlan(), allowed: adapter.allowedEndpoints) {
            try locationsTransport.send($0)
        }
        requests += locationsTransport.sent

        let plan = try await F.plan()
        let readBackTransport = F.Transport()
        _ = try await StockSystemPlanDriver.run(adapter.readBackPlan(plan, queuedAt: F.pulledAt), allowed: adapter.allowedEndpoints) {
            try readBackTransport.send($0)
        }
        requests += readBackTransport.sent

        let writes = try adapter.writeRequests(for: plan.steps, occurredAt: F.pulledAt, now: F.pulledAt)
        requests += writes.map(\.request)
        XCTAssertFalse(writes.isEmpty)

        // A check's few lines (Plan MM P3): the stock endpoint again, reads only.
        let linesTransport = F.Transport()
        _ = try await StockSystemPlanDriver.run(try adapter.linesPlan(itemIDs: ["VAR-CAP-455", "VAR-FILTER"],
                                                                      locationIDs: [F.main, F.van]),
                                                allowed: adapter.allowedEndpoints) { try linesTransport.send($0) }
        XCTAssertFalse(linesTransport.sent.isEmpty)
        XCTAssertTrue(linesTransport.sent.allSatisfy { $0.endpoint == SquareStockAdapter.Endpoint.inventoryCounts })
        requests += linesTransport.sent

        XCTAssertGreaterThanOrEqual(requests.count, 16)
        for request in requests {
            XCTAssertTrue(Self.allowed.contains("\(request.method.rawValue) \(request.path)"), request.description)
            XCTAssertEqual(request.path, request.endpoint.path)
            XCTAssertTrue(adapter.allowedEndpoints.contains(request.endpoint))
            XCTAssertTrue(request.query.isEmpty)
            XCTAssertFalse(request.path.contains("catalog/object"), "no catalogue write")
            XCTAssertFalse(request.path.contains("batch-upsert"), "no catalogue write")
            XCTAssertNotNil(request.url(host: adapter.hosts.production))
            if request.endpoint.writes { assertOnlyWaste(request) }
            if request.method == .get { XCTAssertNil(request.body) }
        }
    }

    func testAWriteNeverHoldsACountATransferOrAnotherState() throws {
        // Every kind of step the plan can hold, at every size around the batch limit.
        for size in [1, 99, 100, 101, 230] {
            let steps = (0..<size).map { index in
                PartsUsedWritePlan.Step.adjustment(.init(
                    idempotencyKey: "key-\(index)", stagedLineID: "S\(index)", itemID: "VAR-\(index % 7)",
                    locationID: index.isMultiple(of: 2) ? F.main : F.van, quantity: index.isMultiple(of: 3) ? "0.25" : "3",
                    unit: index.isMultiple(of: 3) ? .l : .each, reason: .waste, note: nil))
            }
            for write in try adapter.writeRequests(for: steps, occurredAt: F.pulledAt, now: F.pulledAt) {
                XCTAssertLessThanOrEqual(write.steps.count, 100)
                assertOnlyWaste(write.request)
            }
        }
    }

    func testAStepSquareCannotTakeIsRefused() {
        let good = PartsUsedWritePlan.Adjustment(idempotencyKey: "key-1", stagedLineID: "S1", itemID: "VAR-1",
                                                 locationID: F.main, quantity: "1", unit: .each, reason: .waste, note: nil)
        func adjustment(itemID: String = "VAR-1", locationID: String = F.main, quantity: String = "1",
                        unit: VanStockUnit = .each, reason: StockAdjustmentReason = .waste,
                        key: String = "key-1") -> PartsUsedWritePlan.Step {
            .adjustment(.init(idempotencyKey: key, stagedLineID: "S1", itemID: itemID, locationID: locationID,
                              quantity: quantity, unit: unit, reason: reason, note: nil))
        }
        let refused: [[PartsUsedWritePlan.Step]] = [
            [.jobPartLine(.init(idempotencyKey: "key-1", stagedLineID: "S1", externalJobID: "WO-1", itemID: "VAR-1",
                                quantity: "1", unit: .each))],
            [adjustment(reason: .internalUse)],
            [adjustment(reason: .damage)],
            [adjustment(quantity: "0")],
            [adjustment(quantity: "-1")],
            [adjustment(quantity: "1.0")],
            [adjustment(quantity: "0.5", unit: .each)],
            [adjustment(quantity: "1e2")],
            [adjustment(itemID: "")],
            [adjustment(itemID: "VAR 1")],
            [adjustment(locationID: String(repeating: "L", count: 101))],
            [adjustment(key: "")],
            [adjustment(key: String(repeating: "k", count: 256))],
            [.adjustment(good), .adjustment(good)],
        ]
        for steps in refused {
            XCTAssertThrowsError(try adapter.writeRequests(for: steps, occurredAt: F.pulledAt, now: F.pulledAt), "\(steps)") {
                XCTAssertEqual($0 as? StockSystemRequestRefusal, .notAllowed)
            }
        }
        XCTAssertEqual(try adapter.writeRequests(for: [], occurredAt: F.pulledAt, now: F.pulledAt), [])
        XCTAssertEqual(try adapter.writeRequests(for: [.adjustment(good)], occurredAt: F.pulledAt, now: F.pulledAt).count, 1)
    }

    func testARequestOffTheListOrCarryingACredentialCannotBeMade() {
        let upsert = StockSystemEndpoint(.post, "/v2/catalog/batch-upsert", purpose: .write, scope: "ITEMS_WRITE")
        XCTAssertThrowsError(try StockSystemRequest(upsert, allowed: adapter.allowedEndpoints)) {
            XCTAssertEqual($0 as? StockSystemRequestRefusal, .offList)
        }
        // The same path under another method or purpose is another endpoint.
        let getWrite = StockSystemEndpoint(.get, "/v2/inventory/changes/batch-create", purpose: .write, scope: "INVENTORY_WRITE")
        XCTAssertThrowsError(try StockSystemRequest(getWrite, allowed: adapter.allowedEndpoints))
        for name in ["Authorization", "authorization", "Cookie", "Host", "Proxy-Authorization"] {
            XCTAssertThrowsError(try StockSystemRequest(SquareStockAdapter.Endpoint.locations, allowed: adapter.allowedEndpoints,
                                                        headers: [name: "Bearer x"])) {
                XCTAssertEqual($0 as? StockSystemRequestRefusal, .forbiddenHeader)
            }
        }
    }

    func testNoRequestDescriptionCarriesAKeyOrTheBody() async throws {
        let plan = try await F.plan()
        let write = try XCTUnwrap(try adapter.writeRequests(for: plan.steps, occurredAt: F.pulledAt, now: F.pulledAt).first)
        var requests = [write.request]
        let transport = F.Transport()
        _ = try await F.pull(transport: transport)
        requests += transport.sent
        for request in requests {
            XCTAssertNil(request.headers.keys.first { $0.lowercased() == "authorization" })
            var dumped = ""
            dump(request, to: &dumped)
            for text in [String(describing: request), String(reflecting: request), "\(request)", dumped] {
                XCTAssertFalse(text.lowercased().contains("authorization"), text)
                XCTAssertFalse(text.lowercased().contains("bearer"), text)
                XCTAssertFalse(text.contains(write.batchKey), "no body in a description: \(text)")
                XCTAssertFalse(text.contains(SquareStockAdapter.squareVersion), "no header value in a description: \(text)")
            }
        }
        XCTAssertEqual(write.request.description, "POST /v2/inventory/changes/batch-create (\(write.request.body?.count ?? 0)-byte body)")
    }

    // MARK: -

    private func assertOnlyWaste(_ request: StockSystemRequest, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(request.endpoint, SquareStockAdapter.Endpoint.inventoryWrite, file: file, line: line)
        let text = String(decoding: request.body ?? Data(), as: UTF8.self)
        for forbidden in ["PHYSICAL_COUNT", "TRANSFER", "physical_count", "SOLD", "\"location_id\"", "price", "cost"] {
            XCTAssertFalse(text.contains(forbidden), "\(forbidden) in a write", file: file, line: line)
        }
        guard let body = request.jsonBody, let changes = body["changes"] as? [[String: Any]] else {
            return XCTFail("a write is changes", file: file, line: line)
        }
        XCTAssertEqual(Set(body.keys), ["idempotency_key", "changes"], file: file, line: line)
        XCTAssertLessThanOrEqual(changes.count, 100, file: file, line: line)
        for change in changes {
            XCTAssertEqual(change["type"] as? String, "ADJUSTMENT", file: file, line: line)
            let adjustment = change["adjustment"] as? [String: Any] ?? [:]
            XCTAssertEqual(adjustment["from_state"] as? String, "IN_STOCK", file: file, line: line)
            XCTAssertEqual(adjustment["to_state"] as? String, "WASTE", file: file, line: line)
            XCTAssertEqual(adjustment["from_location_id"] as? String, adjustment["to_location_id"] as? String, file: file, line: line)
            XCTAssertEqual(Set(adjustment.keys), ["reference_id", "catalog_object_id", "from_state", "to_state",
                                                  "from_location_id", "to_location_id", "quantity", "occurred_at"],
                           file: file, line: line)
        }
    }

    // MARK: - A check's few lines (Plan MM P3)

    func testTheLinesPlanAsksOnlyForTheAskedItemsAndKeepsOnlyTheirFigures() async throws {
        let transport = F.Transport()
        let fresh = try await StockSystemPlanDriver.run(
            try adapter.linesPlan(itemIDs: ["VAR-CAP-455", " VAR-CAP-455", "VAR-FILTER"], locationIDs: [F.main, F.van]),
            allowed: adapter.allowedEndpoints) { try transport.send($0) }
        // Both pages of the fixture's counts, followed by their cursor.
        XCTAssertEqual(transport.sent.count, 2)
        let first = try XCTUnwrap(transport.sent.first?.jsonBody)
        XCTAssertEqual(first["catalog_object_ids"] as? [String], ["VAR-CAP-455", "VAR-FILTER"])
        XCTAssertEqual(first["location_ids"] as? [String], [F.main, F.van])
        XCTAssertEqual(first["states"] as? [String], ["IN_STOCK"])
        XCTAssertEqual(transport.sent.last?.jsonBody?["cursor"] as? String, "CUR-COUNTS-PAGE-2")
        // The fixture answers with every item; only the asked ones, at the asked places, in stock.
        XCTAssertEqual(fresh.itemIDs, ["VAR-CAP-455", "VAR-FILTER"])
        XCTAssertEqual(fresh.counts, ["VAR-CAP-455": [F.main: "3", F.van: "1"], "VAR-FILTER": [F.main: "6", F.van: "2"]],
                       "the north location is not asked, and the first figure for an item and place stands")
    }

    func testTheLinesPlanRefusesWhatItCouldNotHaveBeenAskedFor() throws {
        let tooMany = (0...SquareStockAdapter.itemsPerLinesRead).map { "VAR-\($0)" }
        for (items, locations) in [(tooMany, [F.main]), (["VAR 1"], [F.main]), (["VAR-1"], ["LOC MAIN"])] {
            XCTAssertThrowsError(try adapter.linesPlan(itemIDs: items, locationIDs: locations)) {
                XCTAssertEqual($0 as? StockSystemRequestRefusal, .notAllowed)
            }
        }
        XCTAssertThrowsError(try adapter.linesPlan(itemIDs: ["VAR-1"], locationIDs: [])) {
            XCTAssertEqual($0 as? StockSystemFailure, .notFound)
        }
        var empty = try adapter.linesPlan(itemIDs: [], locationIDs: [F.main])
        XCTAssertNil(try empty.next(), "nothing asked, nothing sent")
        XCTAssertEqual(empty.result?.counts, [:])
    }

    func testTheLinesPlanStopsOnAFailureOrALoop() async throws {
        let transport = F.Transport()
        transport.overrides["/v2/inventory/counts/batch-retrieve"] = try F.response("error-401-expired.json", status: 401)
        do {
            _ = try await StockSystemPlanDriver.run(try adapter.linesPlan(itemIDs: ["VAR-CAP-455"], locationIDs: [F.main]),
                                                    allowed: adapter.allowedEndpoints) { try transport.send($0) }
            XCTFail("an expired key is a failure")
        } catch {
            XCTAssertEqual(error as? StockSystemFailure, .unauthorized(.expired))
        }
        let looping = F.Transport()
        looping.overrides["/v2/inventory/counts/batch-retrieve"] = StockSystemResponse(
            status: 200, body: try F.json(["counts": [], "cursor": "SAME"]))
        do {
            _ = try await StockSystemPlanDriver.run(try adapter.linesPlan(itemIDs: ["VAR-CAP-455"], locationIDs: [F.main]),
                                                    allowed: adapter.allowedEndpoints) { try looping.send($0) }
            XCTFail("a repeated cursor is refused")
        } catch {
            XCTAssertEqual(error as? StockSystemFailure, .malformedResponse)
        }
    }
}
