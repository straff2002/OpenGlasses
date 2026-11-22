import XCTest
@testable import OpenGlasses

/// Plan MY P0 — lots on a line, the fold per lot and for the line, the `wasted` kind, doses per
/// carton, and an older log folding exactly as it did. Invented lines and lots only.
final class StockLotLedgerTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_795_000_000)
    private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }
    private func q(_ whole: Int) -> StockQuantity { StockQuantity(whole: whole) }

    private func twoLots() -> (VanStockLog, VanStockItem, StockLot, StockLot) {
        var log = VanStockLog()
        let item = log.addItem(id: "flu", description: "the flu vaccine", codes: ["02000000000015"],
                               dosesPerCarton: 10, batch: "b0")
        let a = log.addLot(id: "lot-a", itemID: item.id, code: "ZZ1001", expiry: StockDay(year: 2027, month: 3, day: 31),
                           receivedAt: at(0), batch: "b1")!
        log.record(.loaded, itemID: item.id, quantity: q(10), at: at(0), batch: "b1", source: .scanned, id: "m1", lotID: a.id)
        let b = log.addLot(id: "lot-b", itemID: item.id, code: "zz1002", expiry: StockDay(year: 2027, month: 9, day: 30),
                           receivedAt: at(1), batch: "b2")!
        log.record(.loaded, itemID: item.id, quantity: q(20), at: at(1), batch: "b2", source: .scanned, id: "m2", lotID: b.id)
        return (log, item, a, b)
    }

    // MARK: - An older log

    /// The golden log: a format 2 list written before lots, with every level-changing kind. It
    /// decodes, folds to the same figures, and writes back byte for byte with no lot keys.
    private static let goldenIH = """
    {"items":[{"codes":["2000000000046"],"created_batch":"b1","description":"45\\/5 capacitor","id":"cap","unit":"each","verification":{"state":"not_checked"},"verified":false},{"codes":[],"created_batch":"b1","description":"Copper pipe","id":"pipe","unit":"m","verification":{"state":"not_checked"},"verified":false}],"movements":[{"at":"2026-11-01T08:00:00Z","batch":"b1","id":"m1","item_id":"cap","kind":"loaded","quantity":6000,"source":"spoken"},{"at":"2026-11-01T08:00:00Z","batch":"b1","id":"m2","item_id":"pipe","kind":"loaded","quantity":12500,"source":"spoken"},{"at":"2026-11-02T09:00:00Z","batch":"b2","id":"m3","item_id":"cap","job_reference":"J-1","kind":"used","quantity":2000,"source":"spoken"},{"at":"2026-11-02T10:00:00Z","batch":"b3","id":"m4","item_id":"cap","kind":"removed","quantity":1000,"reason":"damaged","source":"typed"},{"at":"2026-11-03T10:00:00Z","batch":"b4","id":"m5","item_id":"pipe","kind":"counted","quantity":10250,"source":"typed"},{"at":"2026-11-03T11:00:00Z","batch":"b5","id":"m6","item_id":"cap","kind":"used","quantity":5000,"source":"spoken"},{"at":"2026-11-03T11:05:00Z","batch":"b6","id":"m7","item_id":"pipe","kind":"used","quantity":250,"source":"spoken"},{"at":"2026-11-03T11:06:00Z","batch":"b7","id":"m8","item_id":"pipe","kind":"reversed","quantity":0,"reverses":"m7","source":"spoken"}]}
    """

    private func decode(_ json: String) throws -> VanStockLog {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(VanStockLog.self, from: Data(json.utf8))
    }

    private func encode(_ log: VanStockLog) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(log), as: UTF8.self)
    }

    func testAnOlderLogWithNoLotsFoldsExactlyAsBefore() throws {
        let log = try decode(Self.goldenIH)
        XCTAssertTrue(log.lots.isEmpty)
        XCTAssertTrue(log.movements.allSatisfy { $0.lotID == nil && $0.wasteReason == nil })

        let cap = log.level(of: "cap")
        XCTAssertEqual(cap.onHand, .zero)
        XCTAssertTrue(cap.unreliable, "5 used with 3 left: as IH always marked it")
        XCTAssertEqual(cap.provenance, .inferred)
        XCTAssertTrue(cap.lots.isEmpty)

        let pipe = log.level(of: "pipe")
        XCTAssertEqual(pipe.onHand, StockQuantity(scaled: 10_250), "the reversed use is not counted")
        XCTAssertEqual(pipe.provenance, .counted)
        XCTAssertFalse(pipe.unreliable)
        XCTAssertEqual(pipe, VanStockLevel(itemID: "pipe", onHand: StockQuantity(scaled: 10_250), provenance: .counted,
                                           asOf: ISO8601DateFormatter().date(from: "2026-11-03T10:00:00Z")))
    }

    func testAnOlderLogWritesBackUnchanged() throws {
        let log = try decode(Self.goldenIH)
        let written = try encode(log)
        XCTAssertFalse(written.contains("\"lots\""))
        XCTAssertFalse(written.contains("lot_id"))
        XCTAssertFalse(written.contains("waste_reason"))
        XCTAssertFalse(written.contains("doses_per_carton"))
        XCTAssertEqual(try decode(written), log)
        XCTAssertEqual(written, Self.goldenIH.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Lots

    func testTwoLotsFoldApartAndSumToTheLine() {
        var (log, item, a, b) = twoLots()
        log.record(.used, itemID: item.id, quantity: q(1), at: at(2), batch: "b3", source: .spoken, id: "m3", lotID: a.id)
        log.record(.used, itemID: item.id, quantity: q(3), at: at(3), batch: "b4", source: .spoken, id: "m4", lotID: b.id)
        let level = log.level(of: item.id)
        XCTAssertEqual(level.onHand, q(26))
        XCTAssertEqual(level.lots[a.id]?.onHand, q(9))
        XCTAssertEqual(level.lots[b.id]?.onHand, q(17))
        XCTAssertEqual(level.lots.values.reduce(.zero) { $0 + $1.onHand }, level.onHand)
    }

    func testAReversedDoseRestoresItsLot() {
        var (log, item, a, _) = twoLots()
        log.record(.used, itemID: item.id, quantity: q(2), at: at(2), batch: "b3", source: .spoken, id: "m3", lotID: a.id)
        XCTAssertEqual(log.level(of: item.id).lots[a.id]?.onHand, q(8))
        log.undoLastBatch(at: at(3), batch: "undo", source: .spoken)
        XCTAssertEqual(log.level(of: item.id).lots[a.id]?.onHand, q(10))
        XCTAssertEqual(log.level(of: item.id).onHand, q(30))
    }

    func testALotCodeIsKeptExactlyAsRead() {
        let (log, item, _, b) = twoLots()
        XCTAssertEqual(b.code, "zz1002", "case kept")
        var copy = log
        let leading = copy.addLot(itemID: item.id, code: "007A", expiry: nil, receivedAt: at(4), batch: "b9")
        XCTAssertEqual(leading?.code, "007A", "leading zeros kept")
        XCTAssertNil(copy.addLot(itemID: item.id, code: "zz1002", expiry: nil, receivedAt: at(5), batch: "b10"),
                     "a code the line already holds is that lot, not a second one")
        XCTAssertNil(copy.addLot(itemID: "nowhere", code: "ZZ9", expiry: nil, receivedAt: at(5), batch: "b10"))
        XCTAssertNil(copy.addLot(itemID: item.id, code: "  ", expiry: nil, receivedAt: at(5), batch: "b10"))
    }

    func testAMovementNamingAnotherLinesLotIsNotRecorded() {
        var (log, _, a, _) = twoLots()
        let other = log.addItem(id: "mmr", description: "the other vaccine", batch: "b5")
        XCTAssertNil(log.record(.used, itemID: other.id, quantity: q(1), at: at(5), batch: "b6", source: .spoken, lotID: a.id))
        XCTAssertNil(log.record(.used, itemID: other.id, quantity: q(1), at: at(5), batch: "b6", source: .spoken, lotID: "ghost"))
        XCTAssertNil(log.record(.ordered, itemID: "flu", quantity: q(1), at: at(5), batch: "b6", source: .spoken, lotID: a.id),
                     "an order names no lot")
    }

    func testUndoingTheBatchThatAddedALotTakesTheLotAway() {
        var (log, item, _, b) = twoLots()
        let undone = log.undoLastBatch(at: at(5), batch: "undo", source: .spoken)
        XCTAssertEqual(undone?.removedLots.map(\.id), [b.id])
        XCTAssertNil(log.lot(id: b.id))
        XCTAssertEqual(log.level(of: item.id).onHand, q(10))
        XCTAssertNil(log.level(of: item.id).lots[b.id])
    }

    func testTakingMoreFromALotThanItHeldMarksTheLot() {
        var (log, item, a, b) = twoLots()
        log.record(.used, itemID: item.id, quantity: q(12), at: at(2), batch: "b3", source: .spoken, id: "m3", lotID: a.id)
        let level = log.level(of: item.id)
        XCTAssertEqual(level.lots[a.id]?.onHand, .zero)
        XCTAssertEqual(level.lots[a.id]?.unreliable, true)
        XCTAssertFalse(level.unreliable, "the line held enough in all")
        XCTAssertEqual(level.onHand, q(18))
        XCTAssertEqual(level.lots[b.id]?.unreliable, false)
    }

    // MARK: - Counts per lot

    func testACountOfOneLotSetsItAndMovesTheLineByTheDifference() {
        var (log, item, a, b) = twoLots()
        log.record(.counted, itemID: item.id, quantity: q(7), at: at(2), batch: "b3", source: .typed, id: "m3", lotID: a.id)
        var level = log.level(of: item.id)
        XCTAssertEqual(level.lots[a.id]?.onHand, q(7))
        XCTAssertEqual(level.lots[a.id]?.provenance, .counted)
        XCTAssertEqual(level.onHand, q(27))
        XCTAssertEqual(level.provenance, .counted)
        log.record(.counted, itemID: item.id, quantity: q(25), at: at(3), batch: "b4", source: .typed, id: "m4", lotID: b.id)
        level = log.level(of: item.id)
        XCTAssertEqual(level.onHand, q(32))
        XCTAssertEqual(level.lots[b.id]?.onHand, q(25))
    }

    func testACountOfALotClearsItsMark() {
        var (log, item, a, _) = twoLots()
        log.record(.used, itemID: item.id, quantity: q(12), at: at(2), batch: "b3", source: .spoken, id: "m3", lotID: a.id)
        log.record(.counted, itemID: item.id, quantity: q(0), at: at(3), batch: "b4", source: .typed, id: "m4", lotID: a.id)
        let level = log.level(of: item.id)
        XCTAssertEqual(level.lots[a.id]?.unreliable, false)
        XCTAssertFalse(level.unreliable)
    }

    func testTheCountCheckPerLotSaysMatchesShortAndOver() {
        let (log, item, a, _) = twoLots()
        let before = log.level(of: item.id).lots[a.id]!
        XCTAssertEqual(VanStockCountCheck(before: before, counted: q(10)), .matches(expected: q(10)))
        XCTAssertEqual(VanStockCountCheck(before: before, counted: q(8)), .short(expected: q(10), by: q(2)))
        XCTAssertEqual(VanStockCountCheck(before: before, counted: q(13)), .over(expected: q(10), by: q(3)))
        XCTAssertNil(VanStockCountCheck(before: StockLotLevel(lotID: "new"), counted: q(4)), "a new lot has no figure to check")
        var marked = before
        marked.unreliable = true
        XCTAssertEqual(VanStockCountCheck(before: marked, counted: q(4)), .unreliable)
    }

    // MARK: - Waste

    func testWastedSubtractsAndKeepsItsReason() {
        var (log, item, a, _) = twoLots()
        let movement = log.record(.wasted, itemID: item.id, quantity: q(2), at: at(2), batch: "b3", source: .spoken,
                                  id: "w1", lotID: a.id, wasteReason: .coldChain)
        XCTAssertEqual(movement?.wasteReason, .coldChain)
        XCTAssertNil(movement?.reason, "waste is not a removal")
        XCTAssertEqual(log.level(of: item.id).onHand, q(28))
        XCTAssertEqual(log.level(of: item.id).lots[a.id]?.onHand, q(8))
        XCTAssertTrue(movement?.changesLevel == true)
    }

    func testEveryWasteReasonIsKeptApartFromGivenAndCounted() {
        var (log, item, a, _) = twoLots()
        for (offset, reason) in VanStockMovement.WasteReason.allCases.enumerated() {
            log.record(.wasted, itemID: item.id, quantity: q(1), at: at(Double(10 + offset)), batch: "w\(offset)",
                       source: .typed, lotID: a.id, wasteReason: reason)
        }
        log.record(.used, itemID: item.id, quantity: q(1), at: at(30), batch: "g", source: .typed, lotID: a.id)
        let wasted = log.movements.filter { $0.kind == .wasted }
        XCTAssertEqual(wasted.count, VanStockMovement.WasteReason.allCases.count)
        XCTAssertEqual(Set(wasted.compactMap(\.wasteReason)), Set(VanStockMovement.WasteReason.allCases))
        XCTAssertEqual(log.movements.filter { $0.kind == .used }.count, 1)
        XCTAssertEqual(log.level(of: item.id).lots[a.id]?.onHand, q(3))
        XCTAssertNil(log.record(.wasted, itemID: item.id, quantity: .zero, at: at(31), batch: "z", source: .typed),
                     "a waste of nothing is not recorded")
        let defaulted = log.record(.wasted, itemID: item.id, quantity: q(1), at: at(32), batch: "d", source: .typed)
        XCTAssertEqual(defaulted?.wasteReason, .other)
    }

    func testAWastedMovementRoundTripsThroughJSON() throws {
        var (log, item, a, _) = twoLots()
        log.record(.wasted, itemID: item.id, quantity: q(1), at: at(2), batch: "b3", source: .spoken, id: "w1",
                   lotID: a.id, wasteReason: .openedVialDiscarded)
        let written = try encode(log)
        XCTAssertTrue(written.contains("\"waste_reason\":\"opened_vial_discarded\""))
        XCTAssertTrue(written.contains("\"lot_id\":\"lot-a\""))
        XCTAssertEqual(try decode(written), log)
    }

    // MARK: - Doses per carton

    func testDosesPerCartonIsKeptOnTheLineAndUndone() {
        var log = VanStockLog()
        let item = log.addItem(id: "hep", description: "the other vaccine", batch: "b0")
        XCTAssertNil(item.dosesPerCarton)
        XCTAssertTrue(log.edit(itemID: item.id, .dosesPerCarton(10), at: at(1), batch: "b1", source: .typed))
        XCTAssertEqual(log.item(id: item.id)?.dosesPerCarton, 10)
        XCTAssertFalse(log.edit(itemID: item.id, .dosesPerCarton(0), at: at(2), batch: "b2", source: .typed))
        XCTAssertFalse(log.edit(itemID: item.id, .dosesPerCarton(-3), at: at(2), batch: "b2", source: .typed))
        log.undoLastBatch(at: at(3), batch: "u", source: .typed)
        XCTAssertNil(log.item(id: item.id)?.dosesPerCarton)
        XCTAssertNil(log.addItem(description: "zero", dosesPerCarton: 0, batch: "b4").dosesPerCarton)
    }

    // MARK: - Folding an old history

    func testCompactingKeepsEveryLotsFigure() {
        var (log, item, a, b) = twoLots()
        log.record(.used, itemID: item.id, quantity: q(4), at: at(2), batch: "b3", source: .spoken, id: "m3", lotID: a.id)
        log.record(.wasted, itemID: item.id, quantity: q(1), at: at(3), batch: "b4", source: .spoken, id: "m4",
                   lotID: b.id, wasteReason: .broken)
        let before = log.level(of: item.id)
        let folded = log.compacted(before: at(100))
        XCTAssertEqual(folded.level(of: item.id).onHand, before.onHand)
        XCTAssertEqual(folded.level(of: item.id).lots[a.id]?.onHand, q(6))
        XCTAssertEqual(folded.level(of: item.id).lots[b.id]?.onHand, q(19))
        XCTAssertEqual(folded.lots, log.lots)
        XCTAssertTrue(folded.movements.allSatisfy { $0.kind == .opening })
    }
}
