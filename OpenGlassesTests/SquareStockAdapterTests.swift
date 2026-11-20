import XCTest
@testable import OpenGlasses

/// Plan MM P1 — the Square adapter over its synthetic fixtures: the pull, the write plan, the
/// write and its response, the read-back, and the error bodies.
final class SquareStockAdapterTests: XCTestCase {

    private typealias F = SquareFixtures
    private let adapter = SquareFixtures.adapter

    // MARK: - The pull

    func testTheFixturePullBuildsTheExpectedSnapshot() async throws {
        let transport = F.Transport()
        let pull = try await F.pull(transport: transport)
        let encoded = try StockSystemSamples.encodeSorted(pull.snapshot)
        XCTAssertEqual(try StockSystemSamples.object(encoded), try StockSystemSamples.object(F.data("expected-snapshot.json")),
                       String(decoding: encoded, as: UTF8.self))
        XCTAssertEqual(pull.skipped, .init(deleted: 1, untracked: 1, notHere: 1, unreadable: 4))
        XCTAssertEqual(pull.build.malformedRows, 0)
        XCTAssertEqual(pull.build.leftOut, 0)
        XCTAssertEqual(pull.snapshot.asOf, F.pulledAt, "Square's calculated_at says when a count changed, not how old it is")

        XCTAssertEqual(transport.sent.map(\.endpoint), [
            SquareStockAdapter.Endpoint.locations,
            SquareStockAdapter.Endpoint.catalogSearch, SquareStockAdapter.Endpoint.catalogSearch,
            SquareStockAdapter.Endpoint.inventoryCounts, SquareStockAdapter.Endpoint.inventoryCounts,
        ])
        let catalogue = try XCTUnwrap(transport.sent[1].jsonBody)
        XCTAssertEqual(catalogue["object_types"] as? [String], ["ITEM_VARIATION", "MEASUREMENT_UNIT"])
        XCTAssertEqual(catalogue["include_related_objects"] as? Bool, true)
        XCTAssertEqual(catalogue["limit"] as? Int, 1000)
        XCTAssertNil(catalogue["cursor"])
        XCTAssertEqual(transport.sent[2].jsonBody?["cursor"] as? String, "CUR-CATALOG-PAGE-2")
        let counts = try XCTUnwrap(transport.sent[3].jsonBody)
        XCTAssertEqual(counts["location_ids"] as? [String], [F.main, F.van])
        XCTAssertEqual(counts["states"] as? [String], ["IN_STOCK"])
        XCTAssertEqual(transport.sent[4].jsonBody?["cursor"] as? String, "CUR-COUNTS-PAGE-2")
        for request in transport.sent {
            XCTAssertEqual(request.headers["Square-Version"], SquareStockAdapter.squareVersion)
        }
    }

    func testTheSnapshotsDecimalPlacesAndUnitsFollowSquaresUnits() async throws {
        let lines = Dictionary(uniqueKeysWithValues: try await F.pull().snapshot.lines.map { ($0.itemID, $0) })
        XCTAssertEqual(lines["VAR-CAP-455"]?.decimalPlaces, 0, "no measurement unit is whole items")
        XCTAssertEqual(lines["VAR-CAP-455"]?.unit, .each)
        XCTAssertEqual(lines["VAR-COOL-5L"]?.decimalPlaces, 2)
        XCTAssertEqual(lines["VAR-COOL-5L"]?.level(at: F.main), .known(StockQuantity(scaled: 12_500)))
        XCTAssertEqual(lines["VAR-COOL-5L"]?.level(at: F.van), .unknown(.noCount), "no count is unknown, never zero")
        XCTAssertEqual(lines["VAR-WELD"]?.decimalPlaces, 5)
        XCTAssertEqual(lines["VAR-WELD"]?.level(at: F.main), .unknown(.tooManyDecimals), "five places are refused, never rounded")
        XCTAssertEqual(lines["VAR-GREASE"]?.level(at: F.main), .unknown(.unmappedUnit("Tin")))
        XCTAssertEqual(lines["VAR-FILTER"]?.unit, .pack)
        XCTAssertEqual(lines["VAR-HOSE"]?.levels.map(\.locationID), [F.main], "tracked only at the main location")
        XCTAssertNil(lines["VAR-HOSE"]?.part, "an empty SKU is no part number")
        XCTAssertEqual(lines["VAR-CAP-455"]?.reorderPoint, .whole(2))
        XCTAssertEqual(lines["VAR-BRAKE"]?.unit, nil, "millilitres are never converted to litres")
        for skipped in ["VAR-POSTER", "VAR-GONE", "VAR-NORTH", "VAR-BAD", "VAR-NOT-IN-CATALOG"] {
            XCTAssertNil(lines[skipped], skipped)
        }
        XCTAssertNil(lines["VAR-CAP-455"]?.price, "prices are off unless enabled")
    }

    func testTheStoredSnapshotReadsBackAsTheSameStock() async throws {
        let decoded = try JSONDecoder().decode(StockSystemSnapshot.self, from: F.data("expected-snapshot.json"))
        let pulled = try await F.pull().snapshot
        XCTAssertEqual(decoded, pulled)
    }

    func testPricesAreKeptOnlyWhenEnabledAndOnlyInAKnownCurrency() async throws {
        let line = try await F.pull(pricesEnabled: true).snapshot.lines.first { $0.itemID == "VAR-CAP-455" }
        XCTAssertEqual(line?.price, StockSystemPrice(amount: "18.50", currency: "AUD"))

        func data(_ amount: Int64?, _ currency: String?, pricing: String = "FIXED_PRICING") throws -> SquareWire.VariationData {
            var money: [String: Any] = [:]
            if let amount { money["amount"] = amount }
            if let currency { money["currency"] = currency }
            return try SquareStockAdapter.decoder.decode(SquareWire.VariationData.self,
                                                         from: F.json(["pricing_type": pricing, "price_money": money]))
        }
        XCTAssertEqual(SquareSnapshotPlan.price(try data(5, "USD")), "0.05")
        XCTAssertEqual(SquareSnapshotPlan.price(try data(1850, "JPY")), "1850")
        XCTAssertNil(SquareSnapshotPlan.price(try data(1850, "XTS")), "an unknown currency is dropped, not guessed")
        XCTAssertNil(SquareSnapshotPlan.price(try data(1850, "USD", pricing: "VARIABLE_PRICING")))
        XCTAssertNil(SquareSnapshotPlan.price(try data(-1, "USD")))
    }

    func testTheLocationsPlanListsActiveLocationsOnly() async throws {
        let locations = try await StockSystemPlanDriver.run(adapter.locationsPlan(), allowed: adapter.allowedEndpoints) {
            try F.Transport().send($0)
        }
        XCTAssertEqual(locations.map(\.id), [F.main, F.van, "LOC-FIX-NORTH"])
        XCTAssertEqual(locations.map(\.locationClass), [.base, .van, .base])
        XCTAssertEqual(locations.first?.name, "Harbour Street Workshop")
    }

    func testAPullWithNoChosenLocationLeftIsNotFound() async throws {
        for chosen in [["LOC-GONE"], [], ["has spaces"]] {
            do {
                _ = try await StockSystemPlanDriver.run(F.snapshotPlan(chosen), allowed: adapter.allowedEndpoints) {
                    try F.Transport().send($0)
                }
                XCTFail("\(chosen) should not pull")
            } catch {
                XCTAssertEqual(error as? StockSystemFailure, .notFound)
            }
        }
        // One chosen location gone, one still there: the pull goes ahead for the one left.
        let pull = try await StockSystemPlanDriver.run(F.snapshotPlan(["LOC-GONE", F.van]), allowed: adapter.allowedEndpoints) {
            try F.Transport().send($0)
        }
        XCTAssertEqual(pull.snapshot.locations.map(\.id), [F.van])
    }

    func testARepeatedCursorAnUnreadablePageAndAnOversizeBodyAreRefused() async throws {
        let transport = F.Transport()
        transport.overrides["/v2/catalog/search"] = StockSystemResponse(
            status: 200, body: try F.json(["objects": [], "cursor": "SAME"]))
        do {
            _ = try await F.pull(transport: transport)
            XCTFail("a cursor that repeats is a loop")
        } catch {
            XCTAssertEqual(error as? StockSystemFailure, .malformedResponse)
        }

        transport.overrides["/v2/catalog/search"] = StockSystemResponse(status: 200, body: Data(#"{"objects": 7}"#.utf8))
        do {
            _ = try await F.pull(transport: transport)
            XCTFail("an unreadable page")
        } catch {
            XCTAssertEqual(error as? StockSystemFailure, .malformedResponse)
        }

        transport.overrides["/v2/catalog/search"] = StockSystemResponse(
            status: 200, body: Data(repeating: 32, count: SquareStockAdapter.maximumResponseBytes + 1))
        do {
            _ = try await F.pull(transport: transport)
            XCTFail("an oversize page")
        } catch {
            XCTAssertEqual(error as? StockSystemFailure, .tooLarge)
        }
    }

    func testAPullPastThePageBudgetIsTooLarge() async throws {
        final class Endless {
            var page = 0
            func send(_ request: StockSystemRequest) throws -> StockSystemResponse {
                if request.endpoint == SquareStockAdapter.Endpoint.locations { return try F.response("locations.json") }
                page += 1
                return StockSystemResponse(status: 200, body: try F.json(["objects": [], "cursor": "PAGE-\(page)"]))
            }
        }
        let endless = Endless()
        do {
            _ = try await StockSystemPlanDriver.run(F.snapshotPlan(), allowed: adapter.allowedEndpoints) { try endless.send($0) }
            XCTFail("an endless catalogue")
        } catch {
            XCTAssertEqual(error as? StockSystemFailure, .tooLarge)
        }
        XCTAssertEqual(endless.page, SquareStockAdapter.pageBudget)
    }

    // MARK: - The write

    func testTheBatchBecomesTheExpectedWritePlan() async throws {
        let plan = try await F.plan()
        let encoded = try StockSystemSamples.encodeSorted(plan)
        XCTAssertEqual(try StockSystemSamples.object(encoded), try StockSystemSamples.object(F.data("expected-write-plan.json")),
                       String(decoding: encoded, as: UTF8.self))
        XCTAssertEqual(try JSONDecoder().decode(PartsUsedWritePlan.self, from: F.data("expected-write-plan.json")), plan)
    }

    func testTheWriteIsOneAdjustmentPerStepFromInStockToWaste() async throws {
        let plan = try await F.plan()
        let confirmed = StockSystemSamples.date(2026, 11, 20, 9, 55)
        let writes = try adapter.writeRequests(for: plan.steps, occurredAt: confirmed, now: F.pulledAt)
        XCTAssertEqual(writes.count, 1)
        let write = try XCTUnwrap(writes.first)
        XCTAssertEqual(write.request.endpoint, SquareStockAdapter.Endpoint.inventoryWrite)
        XCTAssertEqual(write.request.headers["Square-Version"], "2026-07-15")
        XCTAssertEqual(write.request.headers["Content-Type"], "application/json")
        let body = try XCTUnwrap(write.request.jsonBody)
        XCTAssertEqual(Set(body.keys), ["idempotency_key", "changes"])
        XCTAssertEqual(body["idempotency_key"] as? String, write.batchKey)
        XCTAssertEqual(write.batchKey, StockSystemIdempotency.batchKey(stepKeys: plan.steps.map(\.idempotencyKey)))
        XCTAssertEqual(write.batchKey.count, 64)

        let changes = try XCTUnwrap(body["changes"] as? [[String: Any]])
        XCTAssertEqual(changes.count, 3)
        for (change, step) in zip(changes, plan.steps) {
            guard case .adjustment(let expected) = step else { return XCTFail() }
            XCTAssertEqual(Set(change.keys), ["type", "adjustment"])
            XCTAssertEqual(change["type"] as? String, "ADJUSTMENT")
            let adjustment = try XCTUnwrap(change["adjustment"] as? [String: String])
            XCTAssertEqual(adjustment, [
                "reference_id": expected.idempotencyKey,
                "catalog_object_id": expected.itemID,
                "from_state": "IN_STOCK",
                "to_state": "WASTE",
                "from_location_id": F.main,
                "to_location_id": F.main,
                "quantity": expected.quantity,
                "occurred_at": "2026-11-20T09:55:00Z",
            ])
        }
        XCTAssertEqual(changes.compactMap { ($0["adjustment"] as? [String: String])?["quantity"] }, ["0.5", "1", "2"])
    }

    func testOccurredAtIsTheConfirmationUntilItIsNearlyADayOld() {
        let now = F.pulledAt
        func occurred(_ confirmed: Date) -> String? {
            let step = PartsUsedWritePlan.Step.adjustment(.init(
                idempotencyKey: "k1", stagedLineID: "S1", itemID: "VAR-1", locationID: F.main, quantity: "1", unit: .each,
                reason: .waste, note: nil))
            let body = (try? adapter.writeRequests(for: [step], occurredAt: confirmed, now: now))?.first?.request.jsonBody
            return ((body?["changes"] as? [[String: Any]])?.first?["adjustment"] as? [String: String])?["occurred_at"]
        }
        XCTAssertEqual(occurred(now.addingTimeInterval(-22 * 3600)), "2026-11-19T12:00:00Z")
        XCTAssertEqual(occurred(now.addingTimeInterval(-23 * 3600 - 1)), "2026-11-20T10:00:00Z")
        XCTAssertEqual(occurred(now.addingTimeInterval(-3 * 86_400)), "2026-11-20T10:00:00Z")
        XCTAssertEqual(occurred(now.addingTimeInterval(600)), "2026-11-20T10:00:00Z", "a confirmation in the future is now")
    }

    func testAWriteIsAtMostAHundredChangesAndItsKeyIsStable() throws {
        let steps = (0..<250).map { index in
            PartsUsedWritePlan.Step.adjustment(.init(
                idempotencyKey: PartsUsedWritePlan.idempotencyKey(jobID: "JOB-1", stagedLineID: "S\(index)", kind: .adjustment),
                stagedLineID: "S\(index)", itemID: "VAR-\(index)", locationID: F.main, quantity: "1", unit: .each,
                reason: .waste, note: nil))
        }
        let writes = try adapter.writeRequests(for: steps, occurredAt: F.pulledAt, now: F.pulledAt)
        XCTAssertEqual(writes.map(\.steps.count), [100, 100, 50])
        XCTAssertEqual(Set(writes.map(\.batchKey)).count, 3)
        XCTAssertEqual(try adapter.writeRequests(for: steps, occurredAt: F.pulledAt, now: F.pulledAt).map(\.batchKey),
                       writes.map(\.batchKey), "a rebuild of the same set gives the same keys")
        // The last 50 resent alone are the same request as before.
        let rest = try adapter.writeRequests(for: Array(steps[200...]), occurredAt: F.pulledAt, now: F.pulledAt)
        XCTAssertEqual(rest.map(\.batchKey), [writes[2].batchKey])
    }

    func testTheWriteResponseListsWhatWasApplied() async throws {
        let plan = try await F.plan()
        let write = try XCTUnwrap(try adapter.writeRequests(for: plan.steps, occurredAt: F.pulledAt, now: F.pulledAt).first)
        let accepted = try adapter.acceptedWrite(try F.response("batch-create-success.json"), for: write)
        XCTAssertEqual(accepted.applied, Set(plan.steps.map(\.idempotencyKey)))
        XCTAssertEqual(accepted.mismatched, [])

        // Anything less than certain throws, so the sink reads back first.
        var success = try XCTUnwrap(JSONSerialization.jsonObject(with: F.data("batch-create-success.json")) as? [String: Any])
        success["changes"] = nil
        var uncertain = [StockSystemResponse(status: 200, body: try F.json(success)),
                         StockSystemResponse(status: 200, body: Data("not json".utf8))]
        var changes = try XCTUnwrap((try JSONSerialization.jsonObject(with: F.data("batch-create-success.json")) as? [String: Any])?["changes"] as? [[String: Any]])
        changes.removeLast()
        uncertain.append(StockSystemResponse(status: 200, body: try F.json(["changes": changes])))
        var altered = try XCTUnwrap((try JSONSerialization.jsonObject(with: F.data("batch-create-success.json")) as? [String: Any])?["changes"] as? [[String: Any]])
        var adjustment = try XCTUnwrap(altered[0]["adjustment"] as? [String: Any])
        adjustment["quantity"] = "5"
        altered[0]["adjustment"] = adjustment
        uncertain.append(StockSystemResponse(status: 200, body: try F.json(["changes": altered])))
        for response in uncertain {
            XCTAssertThrowsError(try adapter.acceptedWrite(response, for: write)) {
                XCTAssertEqual($0 as? StockSystemFailure, .malformedResponse)
            }
        }
        XCTAssertThrowsError(try adapter.acceptedWrite(try F.response("error-500.json", status: 500), for: write)) {
            XCTAssertEqual($0 as? StockSystemFailure, .server(status: 500))
        }
        XCTAssertThrowsError(try adapter.acceptedWrite(try F.response("error-403-scopes.json", status: 403), for: write)) {
            XCTAssertEqual($0 as? StockSystemFailure, .missingScope("INVENTORY_WRITE"))
        }
    }

    // MARK: - The read-back

    func testTheReadBackFindsWhatWasAppliedAndWhatNeedsAPerson() async throws {
        let plan = try await F.plan()
        let queued = StockSystemSamples.date(2026, 11, 20, 10, 1)
        let transport = F.Transport()
        let readBack = try await StockSystemPlanDriver.run(adapter.readBackPlan(plan, queuedAt: queued),
                                                           allowed: adapter.allowedEndpoints) { try transport.send($0) }
        let keys = plan.steps.map(\.idempotencyKey)
        XCTAssertEqual(readBack.applied, [keys[0]])
        XCTAssertEqual(readBack.mismatched, [.init(idempotencyKey: keys[1], difference: .quantity)])
        XCTAssertEqual(plan.remaining(after: readBack).map(\.stagedLineID), ["S7"], "only the absent step is sent again")
        XCTAssertEqual(plan.needsAttention(after: readBack).map(\.stagedLineID), ["S2"])

        XCTAssertEqual(transport.sent.count, 2)
        let body = try XCTUnwrap(transport.sent[0].jsonBody)
        XCTAssertEqual(body["types"] as? [String], ["ADJUSTMENT"])
        XCTAssertEqual(body["location_ids"] as? [String], [F.main])
        XCTAssertEqual(body["catalog_object_ids"] as? [String], ["VAR-COOL-5L", "VAR-CAP-455", "VAR-FILTER"])
        XCTAssertEqual(body["updated_after"] as? String, "2026-11-20T09:56:00Z")
        XCTAssertEqual(transport.sent[1].jsonBody?["cursor"] as? String, "CUR-CHANGES-PAGE-2")
    }

    func testAKeyOnAnotherMovementItemOrLocationOrTwiceIsAMismatch() async throws {
        let step = PartsUsedWritePlan.Adjustment(idempotencyKey: "key-1", stagedLineID: "S1", itemID: "VAR-1",
                                                 locationID: F.main, quantity: "0.5", unit: .l, reason: .waste, note: nil)
        func change(_ id: String, from: String = "IN_STOCK", to: String = "WASTE", item: String = "VAR-1",
                    fromLocation: String = F.main, toLocation: String = F.main, quantity: String = "0.50000") -> [String: Any] {
            ["type": "ADJUSTMENT", "adjustment": ["id": id, "reference_id": "key-1", "from_state": from, "to_state": to,
                                                   "catalog_object_id": item, "from_location_id": fromLocation,
                                                   "to_location_id": toLocation, "quantity": quantity]]
        }
        let cases: [([[String: Any]], StockSystemReadBack)] = [
            ([change("A")], .init(applied: ["key-1"])),
            ([change("A", to: "SOLD")], .init(applied: [], mismatched: [.init(idempotencyKey: "key-1", difference: .movement)])),
            ([change("A", item: "VAR-2")], .init(applied: [], mismatched: [.init(idempotencyKey: "key-1", difference: .item)])),
            ([change("A", toLocation: F.van)], .init(applied: [], mismatched: [.init(idempotencyKey: "key-1", difference: .location)])),
            ([change("A", quantity: "0.5001")], .init(applied: [], mismatched: [.init(idempotencyKey: "key-1", difference: .quantity)])),
            ([change("A"), change("B")], .init(applied: [], mismatched: [.init(idempotencyKey: "key-1", difference: .duplicate)])),
            ([change("A"), change("A")], .init(applied: ["key-1"])),  // the same change seen twice is one change
            ([], .init(applied: [])),
        ]
        let plan = try JSONDecoder().decode(PartsUsedWritePlan.self, from: F.json([
            "jobID": "JOB-1", "connectorID": "square",
            "entries": [["kind": "adjustment", "adjustment": [
                "idempotencyKey": step.idempotencyKey, "stagedLineID": step.stagedLineID, "itemID": step.itemID,
                "locationID": step.locationID, "quantity": step.quantity, "unit": "l", "reason": "waste"]]],
        ]))
        for (changes, expected) in cases {
            let body = try F.json(["changes": changes])
            let readBack = try await StockSystemPlanDriver.run(adapter.readBackPlan(plan, queuedAt: F.pulledAt),
                                                               allowed: adapter.allowedEndpoints) { _ in
                StockSystemResponse(status: 200, body: body)
            }
            XCTAssertEqual(readBack, expected, "\(changes)")
        }
    }

    func testTheReadBackAsksForAtMostFiveHundredItemsAtATime() async throws {
        let entries: [[String: Any]] = (0..<600).map { index in
            ["kind": "adjustment", "adjustment": [
                "idempotencyKey": "key-\(index)", "stagedLineID": "S\(index)", "itemID": "VAR-\(index)",
                "locationID": index < 550 ? F.main : F.van, "quantity": "1", "unit": "each", "reason": "waste"]]
        }
        let plan = try JSONDecoder().decode(PartsUsedWritePlan.self,
                                            from: F.json(["jobID": "JOB-1", "connectorID": "square", "entries": entries]))
        var asked: [(String, Int)] = []
        let readBack = try await StockSystemPlanDriver.run(adapter.readBackPlan(plan, queuedAt: F.pulledAt),
                                                           allowed: adapter.allowedEndpoints) { request in
            let body = request.jsonBody ?? [:]
            asked.append(((body["location_ids"] as? [String])?.first ?? "", (body["catalog_object_ids"] as? [String])?.count ?? 0))
            return StockSystemResponse(status: 200, body: Data(#"{}"#.utf8))
        }
        XCTAssertEqual(asked.map(\.0), [F.main, F.main, F.van])
        XCTAssertEqual(asked.map(\.1), [500, 50, 50])
        XCTAssertEqual(plan.remaining(after: readBack).count, 600)
    }

    // MARK: - Errors

    func testErrorBodiesMapToTheCommonCategories() throws {
        typealias E = SquareStockAdapter.Endpoint
        let cases: [(String, Int, [String: String], StockSystemEndpoint, StockSystemFailure)] = [
            ("error-401-expired.json", 401, [:], E.catalogSearch, .unauthorized(.expired)),
            ("error-401-revoked.json", 401, [:], E.catalogSearch, .unauthorized(.revoked)),
            ("error-401-unauthorized.json", 401, [:], E.catalogSearch, .unauthorized(.invalid)),
            ("error-403-scopes.json", 403, [:], E.locations, .missingScope("MERCHANT_PROFILE_READ")),
            ("error-403-scopes.json", 403, [:], E.catalogSearch, .missingScope("ITEMS_READ")),
            ("error-403-scopes.json", 403, [:], E.inventoryCounts, .missingScope("INVENTORY_READ")),
            ("error-403-scopes.json", 403, [:], E.inventoryChanges, .missingScope("INVENTORY_READ")),
            ("error-403-scopes.json", 403, [:], E.inventoryWrite, .missingScope("INVENTORY_WRITE")),
            ("error-429.json", 429, [:], E.inventoryCounts, .rateLimited(retryAfter: nil)),
            ("error-429.json", 429, ["retry-after": "7"], E.inventoryCounts, .rateLimited(retryAfter: 7)),
            ("error-400-validation.json", 400, [:], E.inventoryWrite,
             .rejected(code: "INVALID_VALUE", field: "changes[0].adjustment.quantity")),
            ("error-500.json", 500, [:], E.inventoryWrite, .server(status: 500)),
            ("error-500.json", 503, [:], E.inventoryWrite, .server(status: 503)),
        ]
        for (file, status, headers, endpoint, expected) in cases {
            let failure = adapter.failure(try F.response(file, status: status, headers: headers), endpoint: endpoint)
            XCTAssertEqual(failure, expected, file)
            let sentence = try XCTUnwrap(failure).sentence(system: adapter.displayName)
            XCTAssertTrue(sentence.contains("Square"), sentence)
            XCTAssertFalse(sentence.contains("Fixture text"), "the system's own words are never repeated: \(sentence)")
        }
        XCTAssertNil(adapter.failure(try F.response("locations.json"), endpoint: E.locations))
        XCTAssertEqual(adapter.failure(StockSystemResponse(status: 404, body: Data()), endpoint: E.locations), .notFound)
        XCTAssertEqual(adapter.failure(StockSystemResponse(status: 418, body: Data("teapot".utf8)), endpoint: E.locations),
                       .rejected(code: nil, field: nil))
        XCTAssertEqual(adapter.failure(StockSystemResponse(status: 413, body: Data()), endpoint: E.inventoryWrite), .tooLarge)
        XCTAssertEqual(StockSystemFailure.unauthorized(.expired).sentence(system: "Square"),
                       "Square says the key has expired. Paste a new one in Settings › Field Assist › Stock system.")
    }

    func testAFailureInAPlanStopsIt() async throws {
        let transport = F.Transport()
        transport.overrides["/v2/inventory/counts/batch-retrieve"] = try F.response("error-401-revoked.json", status: 401)
        do {
            _ = try await F.pull(transport: transport)
            XCTFail("a revoked key stops the pull")
        } catch {
            XCTAssertEqual(error as? StockSystemFailure, .unauthorized(.revoked))
            XCTAssertTrue((error as? StockSystemFailure)?.isTerminal == true)
        }
        XCTAssertEqual(transport.sent.count, 4)
    }

    func testCapabilitiesAreAStockSystemWithoutJobsThatTakesWasteOnly() {
        let capabilities = adapter.capabilities(chosenReason: .waste)
        XCTAssertEqual(capabilities.connectorID, "square")
        XCTAssertEqual(capabilities.displayName, "Square")
        XCTAssertFalse(capabilities.hasJobs)
        XCTAssertFalse(capabilities.wholeNumbersOnly)
        XCTAssertFalse(capabilities.adjustmentNote)
        XCTAssertEqual(capabilities.adjustmentReasons, [.waste])
        XCTAssertEqual(PartsUsedWritePlan.route(capabilities: adapter.capabilities(chosenReason: .internalUse), reference: nil),
                       .adjustments(nil), "a reason Square doesn't keep is no reason")
        XCTAssertEqual(adapter.hosts, StockSystemHosts(production: "connect.squareup.com", sandbox: "connect.squareupsandbox.com"))
    }
}
