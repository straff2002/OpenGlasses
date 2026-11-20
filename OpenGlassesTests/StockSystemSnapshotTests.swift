import XCTest
@testable import OpenGlasses

/// Plan MM P0 — the snapshot: built from a connector's rows, closed on decode, unknown never zero.
final class StockSystemSnapshotTests: XCTestCase {

    private typealias S = StockSystemSamples

    func testABuiltSnapshotCarriesTheSourceAndTheSystemProvenance() throws {
        let result = S.builder().build(locations: S.locations, rows: [S.row("1", [("L1", "3"), ("L2", nil)])],
                                       pulledAt: S.pulledAt)
        let line = try XCTUnwrap(result.snapshot.lines.first)
        XCTAssertEqual(result.snapshot.source, S.source)
        XCTAssertEqual(result.snapshot.locations.map(\.locationClass), [.base, .site])
        XCTAssertEqual(line.provenance, .system)
        XCTAssertEqual(line.level(at: "L1"), .known(.whole(3)))
        XCTAssertEqual(line.level(at: "L2"), .unknown(.noCount))
        XCTAssertNil(result.summary)
    }

    func testAMalformedRowIsDroppedAndCounted() {
        let rows = [
            S.row("1", [("L1", "3")]),
            S.row("", [("L1", "3")]),                                   // no item id
            S.row("1", [("L1", "9")]),                                  // the same item twice
            StockSystemRawRow(itemID: "2", part: " ", description: "  ", unit: "ea", levels: []),  // nothing to name it
            S.row("3", [("L1", "1")], asOf: "last Tuesday"),            // an unreadable date
            S.row(String(repeating: "x", count: StockSystemPolicy.Cap.identifier + 1), [("L1", "1")]),
        ]
        let result = S.builder().build(locations: S.locations, rows: rows, pulledAt: S.pulledAt)
        XCTAssertEqual(result.snapshot.lines.map(\.itemID), ["1"])
        XCTAssertEqual(result.snapshot.lines.first?.level(at: "L1"), .known(.whole(3)), "the first row stands")
        XCTAssertEqual(result.malformedRows, 5)
        XCTAssertEqual(result.summary, "From Sample System: 5 rows could not be read and were left out.")
    }

    func testTextIsCapped() {
        let long = String(repeating: "a", count: 500)
        let result = S.builder().build(
            locations: [StockSystemRawLocation(id: "L1", name: long)],
            rows: [S.row("1", part: String(repeating: "9", count: 100), description: long, [("L1", "1")])],
            pulledAt: S.pulledAt)
        let line = result.snapshot.lines[0]
        XCTAssertEqual(line.description.count, StockSystemPolicy.Cap.description)
        XCTAssertEqual(line.part?.count, StockSystemPolicy.Cap.part)
        XCTAssertEqual(result.snapshot.locations[0].name.count, StockSystemPolicy.Cap.locationName)
    }

    func testTheLineCapStopsAndSaysHowManyWereLeftOut() {
        let rows = (1...7).map { S.row("\($0)", [("L1", "1")]) }
        let result = S.builder(lineCap: 4).build(locations: S.locations, rows: rows, pulledAt: S.pulledAt)
        XCTAssertEqual(result.snapshot.lines.count, 4)
        XCTAssertEqual(result.leftOut, 3)
        XCTAssertEqual(result.summary, "From Sample System: 3 lines over the 20000-line limit were left out.")
        XCTAssertEqual(StockSystemPolicy.lineCap, 20_000)
    }

    func testAPriceIsDroppedUnlessEnabled() throws {
        let row = S.row("1", [("L1", "1")], price: "12.50", currency: "nzd")
        XCTAssertNil(S.builder().build(locations: S.locations, rows: [row], pulledAt: S.pulledAt).snapshot.lines[0].price)
        let kept = S.builder(pricesEnabled: true).build(locations: S.locations, rows: [row], pulledAt: S.pulledAt).snapshot
        XCTAssertEqual(kept.lines[0].price, StockSystemPrice(amount: "12.50", currency: "NZD"))
        XCTAssertNil(StockSystemPrice(amount: "1.2.3", currency: nil))
        XCTAssertNil(StockSystemPrice(amount: "5", currency: "dollars"))

        // A stored price is dropped on decode unless the decoder enables prices.
        let data = try S.encodeSorted(kept)
        XCTAssertNil(try JSONDecoder().decode(StockSystemSnapshot.self, from: data).lines[0].price)
        let enabled = JSONDecoder()
        enabled.userInfo[.stockSystemPricesEnabled] = true
        XCTAssertEqual(try enabled.decode(StockSystemSnapshot.self, from: data), kept)
    }

    func testAsOfIsTheOldestSystemDateOtherwiseThePullTime() {
        let undated = S.snapshot([S.row("1", [("L1", "1")])])
        XCTAssertEqual(undated.asOf, S.pulledAt)

        let dated = S.snapshot([
            S.row("1", [("L1", "1")], asOf: "2026-11-20T08:00:00Z"),
            S.row("2", [("L1", "1")], asOf: "2026-11-19T16:10:00.500Z"),
            S.row("3", [("L1", "1")]),
            S.row("4", [("L1", "1")], asOf: "2026-11-21T00:00:00Z"),   // after the pull: a clock out of step
        ])
        XCTAssertEqual(dated.asOf, S.date(2026, 11, 19, 16, 10))
        XCTAssertEqual(dated.lines[3].lineAsOf, S.pulledAt)
        XCTAssertNil(dated.lines[2].lineAsOf)
    }

    /// `known: false` round-trips as unknown with its reason, never as zero; zero round-trips as
    /// zero; the stored form is HF's `onHandScaled` under `quantityScale` 3.
    func testUnknownRoundTripsAsUnknownAndNeverZero() throws {
        let snapshot = S.snapshot([
            S.row("1", [("L1", "0"), ("L2", nil)]),
            S.row("2", unit: "litre", [("L1", "1.23456"), ("L2", "4.25")], reorderPoint: "1.5"),
            S.row("3", unit: "tin", [("L1", "7")]),
        ])
        let data = try S.encodeSorted(snapshot)
        let object = try S.object(data)
        XCTAssertEqual(object["quantityScale"] as? Int, 3)
        let lines = try XCTUnwrap(object["lines"] as? [[String: Any]])
        let levels = try XCTUnwrap(lines[0]["levels"] as? [[String: Any]])
        XCTAssertEqual(levels[0]["onHandScaled"] as? Int, 0)
        XCTAssertEqual(levels[1]["known"] as? Bool, false)
        XCTAssertNil(levels[1]["onHandScaled"])
        XCTAssertNil(lines[2]["unit"], "an unmapped unit has no phone unit")

        let decoded = try JSONDecoder().decode(StockSystemSnapshot.self, from: data)
        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(decoded.lines[0].level(at: "L1"), .known(.zero))
        XCTAssertEqual(decoded.lines[0].level(at: "L2"), .unknown(.noCount))
        XCTAssertEqual(decoded.lines[1].level(at: "L1"), .unknown(.tooManyDecimals))
        XCTAssertEqual(decoded.lines[1].reorderPoint, StockQuantity(scaled: 1500))
        XCTAssertEqual(decoded.lines[2].level(at: "L1"), .unknown(.unmappedUnit("tin")))
    }

    func testDecodingIsClosed() throws {
        let snapshot = S.snapshot([S.row("1", [("L1", "3")])])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: S.encodeSorted(snapshot)) as? [String: Any])

        // An unknown member is ignored.
        object["somethingNew"] = ["a": 1]
        var lines = try XCTUnwrap(object["lines"] as? [[String: Any]])
        lines[0]["alsoNew"] = true
        // A malformed line is dropped and counted: a count off its unit's step, an unknown
        // provenance, a level that is neither a count nor `known: false`, an item listed twice.
        var offStep = lines[0]; offStep["itemID"] = "2"; offStep["levels"] = [["location": "L1", "onHandScaled": 1500]]
        var counted = lines[0]; counted["itemID"] = "3"; counted["provenance"] = "counted"
        var empty = lines[0]; empty["itemID"] = "4"; empty["levels"] = [["location": "L1"]]
        let twice = lines[0]
        object["lines"] = lines + [offStep, counted, empty, twice]

        let decoded = try JSONDecoder().decode(StockSystemSnapshot.self,
                                               from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.lines.map(\.itemID), ["1"])
        XCTAssertEqual(decoded.droppedLineCount, 4)

        // Any scale but 3 is refused.
        for scale in [0, 2, 4] {
            object["quantityScale"] = scale
            XCTAssertThrowsError(try JSONDecoder().decode(StockSystemSnapshot.self,
                                                          from: JSONSerialization.data(withJSONObject: object)))
        }
        object.removeValue(forKey: "quantityScale")
        XCTAssertThrowsError(try JSONDecoder().decode(StockSystemSnapshot.self,
                                                      from: JSONSerialization.data(withJSONObject: object)))
    }
}
