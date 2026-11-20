import Foundation
import XCTest
@testable import OpenGlasses

/// Plan MM P1 — the Square fixtures (`Contracts/fixtures/square-v2/`), read from the checkout, and a
/// transport that answers the adapter's requests from them.
enum SquareFixtures {

    // `#filePath` is fixed at compile time, so it resolves the same on a developer machine and CI.
    static var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Contracts/fixtures/square-v2")
    }

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: root.appendingPathComponent(name))
    }

    static func response(_ name: String, status: Int = 200, headers: [String: String] = [:]) throws -> StockSystemResponse {
        StockSystemResponse(status: status, body: try data(name), headers: headers)
    }

    static func json(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static let adapter = SquareStockAdapter()

    static let main = "LOC-FIX-MAIN"
    static let van = "LOC-FIX-VAN"

    /// 2026-11-20 10:00 UTC: when the fixture pull finished.
    static let pulledAt = StockSystemSamples.date(2026, 11, 20, 10, 0)

    static func snapshotPlan(_ locations: [String] = [main, van], pricesEnabled: Bool = false)
        -> any StockSystemPullPlan<StockSystemSnapshotPull> {
        adapter.snapshotPlan(locationIDs: locations, pulledAt: pulledAt, accountLabel: "Fixture Motors",
                             pricesEnabled: pricesEnabled)
    }

    static func pull(pricesEnabled: Bool = false, transport: Transport = Transport()) async throws -> StockSystemSnapshotPull {
        try await StockSystemPlanDriver.run(snapshotPlan(pricesEnabled: pricesEnabled), allowed: adapter.allowedEndpoints) {
            try transport.send($0)
        }
    }

    // MARK: The batch

    struct Line: Decodable {
        let id: String
        let itemID: String?
        let part: String?
        let description: String
        let quantityScaled: Int
        let unit: VanStockUnit
        let source: StagedStockUse.Source
    }

    struct Batch: Decodable {
        let jobID: String
        let jobNumber: String?
        let locationID: String
        let lines: [Line]

        var confirmed: ConfirmedStockUseBatch {
            ConfirmedStockUseBatch(
                jobID: jobID, jobNumber: jobNumber, locationID: locationID,
                lines: lines.map {
                    StagedStockUse(id: $0.id, itemID: $0.itemID, part: $0.part, description: $0.description,
                                   quantity: StockQuantity(scaled: $0.quantityScaled), unit: $0.unit, source: $0.source)
                },
                confirmation: .person(.voice))
        }
    }

    static func plan() async throws -> PartsUsedWritePlan {
        let batch = try JSONDecoder().decode(Batch.self, from: data("batch.json"))
        return PartsUsedWritePlan(batch: batch.confirmed, reference: nil,
                                  capabilities: adapter.capabilities(chosenReason: .waste),
                                  snapshot: try await pull().snapshot)
    }

    /// Answers each request from the fixtures, by endpoint and by the cursor in its body, and keeps
    /// every request it was sent.
    final class Transport {
        private(set) var sent: [StockSystemRequest] = []
        /// Replies by endpoint path, in place of the fixtures.
        var overrides: [String: StockSystemResponse] = [:]

        func send(_ request: StockSystemRequest) throws -> StockSystemResponse {
            sent.append(request)
            if let reply = overrides[request.path] { return reply }
            let cursor = request.jsonBody?["cursor"] as? String
            switch request.endpoint {
            case SquareStockAdapter.Endpoint.locations:
                return try SquareFixtures.response("locations.json")
            case SquareStockAdapter.Endpoint.catalogSearch:
                return try SquareFixtures.response(cursor == "CUR-CATALOG-PAGE-2" ? "catalog-search-page-2.json"
                                                                                 : "catalog-search-page-1.json")
            case SquareStockAdapter.Endpoint.inventoryCounts:
                return try SquareFixtures.response(cursor == "CUR-COUNTS-PAGE-2" ? "inventory-counts-page-2.json"
                                                                                : "inventory-counts-page-1.json")
            case SquareStockAdapter.Endpoint.inventoryChanges:
                return try SquareFixtures.response(cursor == "CUR-CHANGES-PAGE-2" ? "inventory-changes-page-2.json"
                                                                                 : "inventory-changes-page-1.json")
            case SquareStockAdapter.Endpoint.inventoryWrite:
                return try SquareFixtures.response("batch-create-success.json")
            default:
                throw StockSystemRequestRefusal.offList
            }
        }
    }
}
