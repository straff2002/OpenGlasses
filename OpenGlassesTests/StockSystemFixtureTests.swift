import XCTest
@testable import OpenGlasses

/// Plan MM P0 — the contract's two synthetic fixture sets (`Contracts/fixtures/stock-systems/`):
/// the rows build the expected snapshot, the stored snapshot reads back as the same stock, and the
/// confirmed batch becomes the expected write plan.
final class StockSystemFixtureTests: XCTestCase {

    private static let sets = ["with-jobs", "without-jobs"]

    func testRowsBuildTheExpectedSnapshot() throws {
        for set in Self.sets {
            let input = try StockSystemFixtures.input(set)
            let result = input.build()
            let encoded = try StockSystemSamples.encodeSorted(result.snapshot)
            let built = try StockSystemSamples.object(encoded)
            let expected = try StockSystemSamples.object(StockSystemFixtures.data(set, "expected-snapshot.json"))
            XCTAssertEqual(built, expected, "\(set): \(String(decoding: encoded, as: UTF8.self))")
            XCTAssertEqual(result.leftOut, 0, set)
        }
        XCTAssertEqual(try StockSystemFixtures.input("with-jobs").build().malformedRows, 1)
        XCTAssertEqual(try StockSystemFixtures.input("without-jobs").build().malformedRows, 3)
    }

    func testTheStoredSnapshotReadsBackAsTheSameStock() throws {
        for set in Self.sets {
            let input = try StockSystemFixtures.input(set)
            let decoder = JSONDecoder()
            decoder.userInfo[.stockSystemPricesEnabled] = input.pricesEnabled
            let decoded = try decoder.decode(StockSystemSnapshot.self, from: StockSystemFixtures.data(set, "expected-snapshot.json"))
            XCTAssertEqual(decoded, input.build().snapshot, set)
            XCTAssertEqual(decoded.droppedLineCount, 0, set)
        }
    }

    func testTheBatchBecomesTheExpectedWritePlan() throws {
        for set in Self.sets {
            let input = try StockSystemFixtures.input(set)
            let batch = try StockSystemFixtures.batch(set)
            let plan = PartsUsedWritePlan(batch: batch.confirmed, reference: batch.reference,
                                          capabilities: input.systemCapabilities, snapshot: input.build().snapshot)
            let encoded = try StockSystemSamples.encodeSorted(plan)
            let built = try StockSystemSamples.object(encoded)
            let expected = try StockSystemSamples.object(StockSystemFixtures.data(set, "expected-write-plan.json"))
            XCTAssertEqual(built, expected, "\(set): \(String(decoding: encoded, as: UTF8.self))")
            XCTAssertEqual(try JSONDecoder().decode(PartsUsedWritePlan.self,
                                                    from: StockSystemFixtures.data(set, "expected-write-plan.json")), plan, set)
        }
    }

    /// The fixtures stay synthetic and vendor-neutral: invented ids and names only.
    func testTheFixturesNameNoVendor() throws {
        let names = try FileManager.default.subpathsOfDirectory(atPath: StockSystemFixtures.root.path)
            .filter { $0.hasSuffix(".json") || $0.hasSuffix(".md") }
        XCTAssertEqual(names.count, 10)
        for name in names {
            let text = try String(contentsOf: StockSystemFixtures.root.appendingPathComponent(name), encoding: .utf8).lowercased()
            for vendor in ["square", "lightspeed", "shopify", "simpro", "shopmonkey", "tekmetric", "mechanicdesk",
                           "workshop software", "unleashed", "servicetitan", "workiz"] {
                XCTAssertFalse(text.contains(vendor), "\(name) names \(vendor)")
            }
        }
    }
}
