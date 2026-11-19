import XCTest
@testable import OpenGlasses

/// Plan IH P2 — what the Van Stock screen shows is worked out from the log and nothing else.
final class VanStockRowsTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private var log: VanStockLog {
        var log = VanStockLog()
        log.addItem(id: "sensor", number: "62-23543-01", description: "Flame sensor", minimum: .whole(2),
                    bin: "left shelf 2", codes: ["0123456789012"], verified: true, batch: "b0")
        log.addItem(id: "cable", description: "thermostat cable", unit: .m, batch: "b0")
        log.addItem(id: "igniter", number: "14T56", description: "Igniter", batch: "b0")
        log.addItem(id: "fuse", description: "Fuse", batch: "b0")
        log.record(.counted, itemID: "sensor", quantity: .whole(2), at: start, batch: "b0", source: .typed)
        log.record(.loaded, itemID: "cable", quantity: .whole(30), at: start, batch: "b0", source: .spoken)
        log.record(.counted, itemID: "fuse", quantity: .whole(0), at: start, batch: "b0", source: .typed)
        return log
    }

    func testRowsAreInNameOrderWhateverTheCase() {
        XCTAssertEqual(VanStockRows.rows(log).map(\.id), ["sensor", "fuse", "igniter", "cable"])
    }

    func testQuantityIsNeverANumberForALineNothingWasRecordedAgainst() {
        let rows = Dictionary(uniqueKeysWithValues: VanStockRows.rows(log).map { ($0.id, $0) })
        XCTAssertEqual(rows["sensor"]?.quantity, "2")
        XCTAssertEqual(rows["cable"]?.quantity, "30 m")
        XCTAssertEqual(rows["fuse"]?.quantity, "0")
        XCTAssertNil(rows["igniter"]?.quantity)
    }

    func testMarks() {
        let rows = Dictionary(uniqueKeysWithValues: VanStockRows.rows(log).map { ($0.id, $0) })
        XCTAssertEqual(rows["sensor"]?.isLow, true, "at its minimum")
        XCTAssertEqual(rows["fuse"]?.isLow, true, "recorded at zero with no minimum")
        XCTAssertEqual(rows["cable"]?.isLow, false)
        XCTAssertEqual(rows["igniter"]?.isLow, false, "never recorded is not the same as run out")
        // Nothing was searched for the igniter's number, so it carries no mark (Plan MK §4).
        XCTAssertEqual(rows["igniter"]?.isNotFound, false)
        XCTAssertNil(rows["igniter"]?.notFoundLabel)
        XCTAssertEqual(rows["sensor"]?.isNotFound, false)
        XCTAssertEqual(rows["fuse"]?.isNotFound, false, "a line with no number has nothing to look up")
    }

    /// Plan MK P2 — the mark shows only on a number its book was searched for and did not hold,
    /// and names that book.
    func testTheMarkIsOnlyOnANumberItsBookDidNotHold() {
        var log = VanStockLog()
        log.addItem(id: "found", number: "11A11", description: "Found", verification: .found(in: "Supplier catalogue"),
                    batch: "b0")
        log.addItem(id: "missing", number: "22B22", description: "Missing",
                    verification: .notFound(in: "Supplier catalogue"), batch: "b0")
        log.addItem(id: "unnamed", number: "33C33", description: "Unnamed", verification: .notFound(in: nil),
                    batch: "b0")
        log.addItem(id: "unchecked", number: "44D44", description: "Unchecked", verification: .notChecked, batch: "b0")
        log.addItem(id: "soda", description: "Soda water", verification: .notFound(in: "Supplier catalogue"),
                    batch: "b0")
        let rows = Dictionary(uniqueKeysWithValues: VanStockRows.rows(log).map { ($0.id, $0) })

        XCTAssertEqual(rows["missing"]?.notFoundLabel, "Not found in Supplier catalogue")
        XCTAssertEqual(rows["unnamed"]?.notFoundLabel, "Not in the manuals", "no book was recorded")
        XCTAssertNil(rows["found"]?.notFoundLabel)
        XCTAssertNil(rows["unchecked"]?.notFoundLabel, "nothing searched is no mark")
        XCTAssertNil(rows["soda"]?.notFoundLabel, "a line with no number has nothing to look up")
        XCTAssertEqual(rows.values.filter(\.isNotFound).map(\.id).sorted(), ["missing", "unnamed"])
    }

    func testSearchMatchesDescriptionNumberBinAndCode() {
        XCTAssertEqual(VanStockRows.rows(log, query: "flame").map(\.id), ["sensor"])
        XCTAssertEqual(VanStockRows.rows(log, query: "14t").map(\.id), ["igniter"])
        XCTAssertEqual(VanStockRows.rows(log, query: "SHELF left").map(\.id), ["sensor"])
        XCTAssertEqual(VanStockRows.rows(log, query: "0123456789012").map(\.id), ["sensor"])
        XCTAssertEqual(VanStockRows.rows(log, query: "flame igniter"), [])
        XCTAssertEqual(VanStockRows.rows(log, query: "   ").count, 4)
    }

    func testHistoryIsNewestFirstAndAnUndoMarksWhatItTookBack() {
        var log = self.log
        log.record(.used, itemID: "sensor", quantity: .whole(1), at: start.addingTimeInterval(60), batch: "b1", source: .spoken)
        log.undoLastBatch(at: start.addingTimeInterval(120), batch: "u1", source: .typed)
        let history = VanStockRows.history(log, itemID: "sensor")
        XCTAssertEqual(history.map(\.movement.kind), [.used, .counted])
        XCTAssertEqual(history.map(\.takenBack), [true, false])
        XCTAssertEqual(VanStockRows.history(log, itemID: "nobody"), [])
    }
}
