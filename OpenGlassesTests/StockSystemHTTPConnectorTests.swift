import XCTest
@testable import OpenGlasses

/// Plan MM P2 — the common connector end to end over the fixture transport and Square's synthetic
/// fixtures: the locations, a snapshot pull across both cursors, Test connection's reads, and the
/// write and read-back wired through the same driver.
final class StockSystemHTTPConnectorTests: XCTestCase {

    private typealias F = SquareFixtures
    private let adapter = SquareStockAdapter()
    private let key = StockSystemConnectionSamples.key("h")

    private func connector(_ transport: FixtureStockSystemTransport,
                           environment: StockSystemEnvironment = .production) throws -> StockSystemHTTPConnector {
        StockSystemHTTPConnector(
            adapter: adapter,
            destination: try XCTUnwrap(StockSystemDestination(adapter: adapter, route: .squareStockAPI, environment: environment)),
            transport: transport, credential: try XCTUnwrap(StockSystemCredential(key)), chosenReason: .waste,
            accountLabel: "Fixture Motors", now: { F.pulledAt })
    }

    func testTheLocationsComeThroughTheCommonTransport() async throws {
        let transport = FixtureStockSystemTransport.square()
        let locations = try await connector(transport).locations()
        XCTAssertFalse(locations.isEmpty)
        XCTAssertTrue(locations.contains { $0.id == F.main })
        let sent = try XCTUnwrap(transport.sent.first)
        XCTAssertEqual(sent.request.endpoint, SquareStockAdapter.Endpoint.locations)
        XCTAssertEqual(sent.destination.host, "connect.squareup.com")
        XCTAssertEqual(sent.destination.route, .squareStockAPI)
        XCTAssertEqual(sent.credential.key, key)
    }

    func testASnapshotPullFollowsBothCursorsAndMatchesTheAdaptersOwn() async throws {
        let transport = FixtureStockSystemTransport.square()
        let pulled = try await connector(transport).pull(locationIDs: [F.main, F.van], pulledAt: F.pulledAt)
        let direct = try await F.pull()
        XCTAssertEqual(pulled, direct)
        XCTAssertEqual(pulled.snapshot.source.connectorID, "square")
        XCTAssertEqual(pulled.snapshot.source.accountLabel, "Fixture Motors")
        XCTAssertEqual(pulled.snapshot.asOf, F.pulledAt)
        let cursors = transport.sent.compactMap { $0.request.jsonBody?["cursor"] as? String }
        XCTAssertEqual(cursors, ["CUR-CATALOG-PAGE-2", "CUR-COUNTS-PAGE-2"])
        XCTAssertTrue(transport.sent.allSatisfy { !$0.request.endpoint.writes }, "a pull never writes")
        let snapshot = try await connector(transport).pullSnapshot(locationIDs: [F.main, F.van], pulledAt: F.pulledAt)
        XCTAssertEqual(snapshot, direct.snapshot)
    }

    func testASandboxConnectionTalksOnlyToTheSandboxHost() async throws {
        let transport = FixtureStockSystemTransport.square()
        _ = try await connector(transport, environment: .sandbox).locations()
        XCTAssertEqual(Set(transport.sent.map(\.destination.host)), ["connect.squareupsandbox.com"])
    }

    func testTestConnectionReadsOnlyAndSaysWhatWorks() async throws {
        let transport = FixtureStockSystemTransport.square()
        let probe = try await connector(transport).probe()
        XCTAssertTrue(probe.passed)
        XCTAssertEqual(probe.checks.map(\.purpose), [.stock, .catalogue])
        XCTAssertEqual(probe.line(system: "Square", sendingBack: false), "Connected to Square. Stock ✓ Items ✓ — sending back is off.")
        XCTAssertEqual(transport.sent.map(\.request.endpoint), [SquareStockAdapter.Endpoint.locations,
                                                                SquareStockAdapter.Endpoint.inventoryCounts,
                                                                SquareStockAdapter.Endpoint.catalogSearch])
        XCTAssertTrue(transport.sent.allSatisfy { !$0.request.endpoint.writes })
        for sent in transport.sent.dropFirst() {
            XCTAssertEqual(sent.request.jsonBody?["limit"] as? Int, 1, "each probe is a page of one")
        }
    }

    func testAMissingPermissionIsNamedAndABadKeyFails() async throws {
        let fixtures = F.Transport()
        fixtures.overrides["/v2/inventory/counts/batch-retrieve"] = try F.response("error-403-scopes.json", status: 403)
        let probe = try await connector(FixtureStockSystemTransport.square(fixtures)).probe()
        XCTAssertFalse(probe.passed)
        XCTAssertEqual(probe.checks.first, .init(purpose: .stock, missingScope: "INVENTORY_READ"))
        XCTAssertEqual(probe.line(system: "Square", sendingBack: false),
                       StockSystemFailure.missingScope("INVENTORY_READ").sentence(system: "Square"))

        let expired = F.Transport()
        expired.overrides["/v2/locations"] = try F.response("error-401-expired.json", status: 401)
        do {
            _ = try await connector(FixtureStockSystemTransport.square(expired)).probe()
            XCTFail("an expired key passed")
        } catch {
            XCTAssertEqual(error as? StockSystemFailure, .unauthorized(.expired))
        }
    }

    func testTheProbePlanRefusesAWrite() throws {
        let write = try adapter.request(SquareStockAdapter.Endpoint.inventoryWrite, body: ["changes": []])
        XCTAssertThrowsError(try StockSystemProbePlan(adapter: adapter, requests: [write])) {
            XCTAssertEqual($0 as? StockSystemRequestRefusal, .notAllowed)
        }
    }

    /// Wired for the queued sink (P4); nothing in the app calls these yet.
    func testTheWriteAndTheReadBackRunThroughTheSameDriver() async throws {
        let plan = try await F.plan()
        let transport = FixtureStockSystemTransport.square()
        let connector = try connector(transport)
        let applied = try await connector.apply(plan.steps, confirmedAt: F.pulledAt)
        XCTAssertEqual(applied.applied, Set(plan.steps.map(\.idempotencyKey)))
        XCTAssertEqual(transport.sent.filter(\.request.endpoint.writes).count, 1)

        let readBack = try await connector.readBack(plan, queuedAt: StockSystemSamples.date(2026, 11, 20, 10, 1))
        XCTAssertEqual(readBack.applied, [plan.steps[0].idempotencyKey])
        XCTAssertEqual(readBack.mismatched.map(\.difference), [.quantity])
    }
}
