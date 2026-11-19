import XCTest
@testable import OpenGlasses

/// Plan IH P0 — the van's stock is what its movements add up to.
final class VanStockLedgerTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_790_000_000)
    private func time(_ minutes: Int) -> Date { start.addingTimeInterval(Double(minutes) * 60) }

    private let itemID = "item-1"

    /// A van with one line on it and nothing recorded.
    private func van(minimum: StockQuantity? = nil) -> VanStockLog {
        var log = VanStockLog()
        log.addItem(id: itemID, number: "62-23543-01", description: "Flame sensor",
                    minimum: minimum, batch: "b0")
        return log
    }

    // MARK: Each kind

    func testALoadAddsAndIsInferred() {
        var log = van()
        XCTAssertNotNil(log.record(.loaded, itemID: itemID, quantity: .whole(4), at: time(0), batch: "b0", source: .spoken))
        let level = log.level(of: itemID)
        XCTAssertEqual(level.onHand, .whole(4))
        XCTAssertEqual(level.provenance, .inferred)
        XCTAssertEqual(level.asOf, time(0))
        XCTAssertFalse(level.unreliable)
    }

    func testAUseAndARemovalSubtract() {
        var log = van()
        log.record(.loaded, itemID: itemID, quantity: .whole(4), at: time(0), batch: "b0", source: .spoken)
        log.record(.used, itemID: itemID, quantity: .whole(1), at: time(1), batch: "b1", source: .spoken,
                   jobSessionID: "s1", jobReference: "job-2031")
        let removal = log.record(.removed, itemID: itemID, quantity: .whole(2), at: time(2), batch: "b2",
                                 source: .spoken, reason: .returned)
        XCTAssertEqual(log.level(of: itemID).onHand, .whole(1))
        XCTAssertEqual(log.level(of: itemID).asOf, time(2))
        XCTAssertEqual(removal?.reason, .returned)
        XCTAssertEqual(log.movements[1].jobReference, "job-2031")
    }

    func testACountSetsTheLevelAndIsCounted() {
        var log = van()
        log.record(.loaded, itemID: itemID, quantity: .whole(4), at: time(0), batch: "b0", source: .spoken)
        log.record(.counted, itemID: itemID, quantity: .whole(7), at: time(1), batch: "b1", source: .typed)
        XCTAssertEqual(log.level(of: itemID).onHand, .whole(7))
        XCTAssertEqual(log.level(of: itemID).provenance, .counted)
    }

    func testProvenanceFlipsToInferredOnTheFirstMovementAfterACount() {
        var log = van()
        log.record(.counted, itemID: itemID, quantity: .whole(3), at: time(0), batch: "b0", source: .typed)
        XCTAssertEqual(log.level(of: itemID).provenance, .counted)
        log.record(.used, itemID: itemID, quantity: .whole(1), at: time(1), batch: "b1", source: .spoken)
        XCTAssertEqual(log.level(of: itemID).provenance, .inferred)
        XCTAssertEqual(log.level(of: itemID).onHand, .whole(2))
    }

    func testACountOfZeroIsAllowedAndOtherKindsNeedAtLeastOne() {
        var log = van()
        XCTAssertNotNil(log.record(.counted, itemID: itemID, quantity: .whole(0), at: time(0), batch: "b0", source: .typed))
        XCTAssertNil(log.record(.loaded, itemID: itemID, quantity: .whole(0), at: time(1), batch: "b1", source: .spoken))
        XCTAssertNil(log.record(.used, itemID: itemID, quantity: .whole(-1), at: time(1), batch: "b1", source: .spoken))
        XCTAssertNil(log.record(.counted, itemID: itemID, quantity: .whole(-1), at: time(1), batch: "b1", source: .typed))
        XCTAssertNil(log.record(.loaded, itemID: "nobody", quantity: .whole(1), at: time(1), batch: "b1", source: .spoken))
        XCTAssertNil(log.record(.reversed, itemID: itemID, quantity: .whole(1), at: time(1), batch: "b1", source: .spoken))
        XCTAssertEqual(log.movements.count, 1)
    }

    func testALineWithNothingRecordedIsAtZeroAndNotRecorded() {
        let log = van()
        XCTAssertEqual(log.level(of: itemID).onHand, .whole(0))
        XCTAssertFalse(log.level(of: itemID).isRecorded)
        XCTAssertNil(log.level(of: itemID).asOf)
    }

    // MARK: A use the log cannot cover

    func testAUsePastZeroIsRecordedMarksTheLineUnreliableAndACountClearsIt() {
        var log = van()
        log.record(.loaded, itemID: itemID, quantity: .whole(1), at: time(0), batch: "b0", source: .spoken)
        XCTAssertNotNil(log.record(.used, itemID: itemID, quantity: .whole(2), at: time(1), batch: "b1", source: .spoken))
        XCTAssertEqual(log.level(of: itemID).onHand, .whole(0))
        XCTAssertTrue(log.level(of: itemID).unreliable)

        // A load does not make the figure trustworthy again; only a count does.
        log.record(.loaded, itemID: itemID, quantity: .whole(3), at: time(2), batch: "b2", source: .spoken)
        XCTAssertTrue(log.level(of: itemID).unreliable)
        log.record(.counted, itemID: itemID, quantity: .whole(3), at: time(3), batch: "b3", source: .typed)
        XCTAssertFalse(log.level(of: itemID).unreliable)
        XCTAssertEqual(log.level(of: itemID).onHand, .whole(3))
    }

    // MARK: Orders

    func testOrdersDoNotChangeTheLevelAndCloseOldestFirst() {
        var log = van()
        log.record(.counted, itemID: itemID, quantity: .whole(0), at: time(0), batch: "b0", source: .typed)
        log.record(.ordered, itemID: itemID, quantity: .whole(2), at: time(1), batch: "b1", source: .spoken, requestID: "r1")
        log.record(.ordered, itemID: itemID, quantity: .whole(1), at: time(2), batch: "b2", source: .spoken, requestID: "r2")
        var level = log.level(of: itemID)
        XCTAssertEqual(level.onHand, .whole(0))
        XCTAssertEqual(level.onOrder, .whole(3))
        XCTAssertEqual(level.oldestOrderAt, time(1))
        XCTAssertEqual(level.asOf, time(0), "an order is not a change to the level")

        log.record(.loaded, itemID: itemID, quantity: .whole(2), at: time(3), batch: "b3", source: .spoken)
        level = log.level(of: itemID)
        XCTAssertEqual(level.onHand, .whole(2))
        XCTAssertEqual(level.onOrder, .whole(1))
        XCTAssertEqual(level.oldestOrderAt, time(2), "the older order closed first")

        log.record(.loaded, itemID: itemID, quantity: .whole(5), at: time(4), batch: "b4", source: .spoken)
        XCTAssertEqual(log.level(of: itemID).onOrder, .whole(0))
        XCTAssertNil(log.level(of: itemID).oldestOrderAt)
    }

    func testACountDoesNotCloseAnOrder() {
        var log = van()
        log.record(.ordered, itemID: itemID, quantity: .whole(1), at: time(0), batch: "b0", source: .spoken)
        log.record(.counted, itemID: itemID, quantity: .whole(4), at: time(1), batch: "b1", source: .typed)
        XCTAssertEqual(log.level(of: itemID).onOrder, .whole(1))
    }

    // MARK: Undo

    func testUndoTakesBackTheWholeLastBatchOnce() {
        var log = van()
        log.record(.loaded, itemID: itemID, quantity: .whole(4), at: time(0), batch: "b0", source: .spoken)
        let other = log.addItem(id: "item-2", description: "45/5 capacitor", batch: "b1")
        log.record(.loaded, itemID: itemID, quantity: .whole(2), at: time(1), batch: "b1", source: .spoken)
        log.record(.loaded, itemID: other.id, quantity: .whole(6), at: time(1), batch: "b1", source: .spoken)

        let undone = log.undoLastBatch(at: time(2), batch: "u1", source: .spoken)
        XCTAssertEqual(undone?.batch, "b1")
        XCTAssertEqual(undone?.movements.count, 2)
        XCTAssertEqual(undone?.removedItems.map(\.id), ["item-2"], "the line the batch created is gone")
        XCTAssertEqual(log.level(of: itemID).onHand, .whole(4))
        XCTAssertNil(log.item(id: "item-2"))
        XCTAssertEqual(log.movements.filter { $0.kind == .reversed }.count, 2, "nothing is removed from the log")

        XCTAssertNil(log.undoLastBatch(at: time(3), batch: "u2", source: .spoken), "an undo cannot be undone")
        XCTAssertEqual(log.level(of: itemID).onHand, .whole(4))
    }

    func testUndoOfAUseReopensWhatItClosed() {
        var log = van()
        log.record(.ordered, itemID: itemID, quantity: .whole(1), at: time(0), batch: "b0", source: .spoken)
        log.record(.loaded, itemID: itemID, quantity: .whole(1), at: time(1), batch: "b1", source: .spoken)
        XCTAssertEqual(log.level(of: itemID).onOrder, .whole(0))
        log.undoLastBatch(at: time(2), batch: "u1", source: .spoken)
        XCTAssertEqual(log.level(of: itemID).onOrder, .whole(1))
        XCTAssertEqual(log.level(of: itemID).onHand, .whole(0))
    }

    func testUndoOnAnEmptyLogIsNothing() {
        var log = VanStockLog()
        XCTAssertNil(log.undoLastBatch(at: time(0), batch: "u1", source: .spoken))
    }

    // MARK: Edits

    func testAnEditChangesTheLineNotesItAndUndoPutsItBack() {
        var log = van()
        XCTAssertTrue(log.edit(itemID: itemID, .standard(.whole(6), setBy: .base), at: time(0), batch: "b1", source: .sheet))
        XCTAssertTrue(log.edit(itemID: itemID, .minimum(.whole(2)), at: time(0), batch: "b1", source: .sheet))
        XCTAssertTrue(log.edit(itemID: itemID, .number("62-23543-02"), at: time(0), batch: "b1", source: .sheet))
        XCTAssertTrue(log.edit(itemID: itemID, .addCode("0123456789012"), at: time(0), batch: "b1", source: .scanned))
        XCTAssertFalse(log.edit(itemID: itemID, .minimum(.whole(2)), at: time(0), batch: "b1", source: .sheet), "no change, no note")
        XCTAssertFalse(log.edit(itemID: itemID, .addCode("0123456789012"), at: time(0), batch: "b1", source: .scanned))
        XCTAssertFalse(log.edit(itemID: "nobody", .minimum(.whole(2)), at: time(0), batch: "b1", source: .sheet))

        var edited = log.item(id: itemID)
        XCTAssertEqual(edited?.standard, .whole(6))
        XCTAssertEqual(edited?.standardSetBy, .base)
        XCTAssertEqual(edited?.minimum, .whole(2))
        XCTAssertEqual(edited?.number, "62-23543-02")
        XCTAssertEqual(edited?.codes, ["0123456789012"])
        XCTAssertEqual(log.level(of: itemID).onHand, .whole(0), "an edit never moves stock")
        XCTAssertEqual(log.movements.filter { $0.kind == .edited }.count, 4)

        log.undoLastBatch(at: time(1), batch: "u1", source: .typed)
        edited = log.item(id: itemID)
        XCTAssertNil(edited?.standard)
        XCTAssertNil(edited?.standardSetBy)
        XCTAssertNil(edited?.minimum)
        XCTAssertEqual(edited?.number, "62-23543-01")
        XCTAssertEqual(edited?.codes, [])
    }

    func testAStandardWithNoFigureHasNoOrigin() {
        var log = van()
        log.edit(itemID: itemID, .standard(.whole(4), setBy: .van), at: time(0), batch: "b1", source: .spoken)
        log.edit(itemID: itemID, .standard(nil, setBy: .base), at: time(1), batch: "b2", source: .typed)
        XCTAssertNil(log.item(id: itemID)?.standard)
        XCTAssertNil(log.item(id: itemID)?.standardSetBy)
    }

    func testANewLinesNumberIsNormalised() {
        var log = VanStockLog()
        let item = log.addItem(number: " #14t65. ", description: " Pressure switch ", batch: "b0")
        XCTAssertEqual(item.number, "14T65")
        XCTAssertEqual(item.description, "Pressure switch")
        XCTAssertNil(log.addItem(number: "  ", description: "Wire nuts", batch: "b0").number)
    }

    // MARK: Low

    func testLowIsAtOrBelowMinimumOrRecordedZeroWithNone() {
        var log = VanStockLog()
        let atMinimum = log.addItem(id: "a", description: "Igniter", minimum: .whole(2), batch: "b0")
        let above = log.addItem(id: "b", description: "Contactor", minimum: .whole(1), batch: "b0")
        let gone = log.addItem(id: "c", description: "Fuse", batch: "b0")
        let neverRecorded = log.addItem(id: "d", description: "Filter", batch: "b0")
        log.record(.counted, itemID: atMinimum.id, quantity: .whole(2), at: time(0), batch: "b0", source: .typed)
        log.record(.counted, itemID: above.id, quantity: .whole(3), at: time(0), batch: "b0", source: .typed)
        log.record(.counted, itemID: gone.id, quantity: .whole(0), at: time(0), batch: "b0", source: .typed)
        XCTAssertEqual(log.lowItems.map(\.id), ["a", "c"])
        XCTAssertFalse(log.lowItems.contains(neverRecorded))
    }

    // MARK: Handover provenance

    func testAHandoverCountIsHandedOverUntilSomethingMoves() {
        var log = van()
        log.record(.counted, itemID: itemID, quantity: .whole(2), at: time(0), batch: "b0", source: .handover)
        XCTAssertTrue(log.level(of: itemID).handedOver)
        log.record(.used, itemID: itemID, quantity: .whole(1), at: time(1), batch: "b1", source: .spoken)
        XCTAssertFalse(log.level(of: itemID).handedOver)
    }

    // MARK: Folding

    func testFoldingOldMovementsLeavesEveryLevelUnchanged() {
        var log = VanStockLog()
        let counted = log.addItem(id: "a", description: "Igniter", batch: "b0")
        let inferred = log.addItem(id: "b", description: "Contactor", batch: "b0")
        let unreliable = log.addItem(id: "c", description: "Fuse", batch: "b0")
        let ordered = log.addItem(id: "d", description: "Filter", batch: "b0")
        let recentOnly = log.addItem(id: "e", description: "Capacitor", batch: "b9")

        log.record(.loaded, itemID: counted.id, quantity: .whole(9), at: time(0), batch: "b0", source: .spoken)
        log.record(.counted, itemID: counted.id, quantity: .whole(5), at: time(1), batch: "b1", source: .handover)
        log.record(.loaded, itemID: inferred.id, quantity: .whole(4), at: time(2), batch: "b2", source: .spoken)
        log.record(.used, itemID: inferred.id, quantity: .whole(1), at: time(3), batch: "b3", source: .spoken)
        log.record(.used, itemID: unreliable.id, quantity: .whole(1), at: time(4), batch: "b4", source: .spoken)
        log.record(.ordered, itemID: ordered.id, quantity: .whole(3), at: time(5), batch: "b5", source: .spoken, requestID: "r1")
        log.record(.loaded, itemID: ordered.id, quantity: .whole(1), at: time(6), batch: "b6", source: .spoken)
        log.record(.loaded, itemID: inferred.id, quantity: .whole(8), at: time(7), batch: "b7", source: .spoken)
        log.undoLastBatch(at: time(8), batch: "u1", source: .spoken)
        // After the cutoff.
        log.record(.used, itemID: counted.id, quantity: .whole(2), at: time(100), batch: "b8", source: .spoken)
        log.record(.loaded, itemID: recentOnly.id, quantity: .whole(6), at: time(101), batch: "b9", source: .spoken)
        log.record(.loaded, itemID: ordered.id, quantity: .whole(1), at: time(102), batch: "b10", source: .spoken)

        let folded = log.compacted(before: time(50))
        XCTAssertEqual(folded.levels, log.levels)
        XCTAssertEqual(folded.items, log.items)
        XCTAssertLessThan(folded.movements.count, log.movements.count)
        XCTAssertEqual(folded.movements.filter { $0.at < time(50) }.map(\.kind).filter { $0 != .opening && $0 != .ordered }, [])

        // And it is stable: folding again changes nothing.
        XCTAssertEqual(folded.compacted(before: time(50)).levels, log.levels)
        XCTAssertEqual(folded.level(of: ordered.id).onOrder, .whole(1))
        XCTAssertEqual(folded.level(of: ordered.id).oldestOrderAt, time(5))
    }

    func testFoldingWithNothingOldChangesNothing() {
        var log = van()
        log.record(.loaded, itemID: itemID, quantity: .whole(4), at: time(10), batch: "b0", source: .spoken)
        XCTAssertEqual(log.compacted(before: time(0)), log)
    }

    func testAnOpeningCannotBeUndone() {
        var log = van()
        log.record(.loaded, itemID: itemID, quantity: .whole(4), at: time(0), batch: "b0", source: .spoken)
        var folded = log.compacted(before: time(10))
        XCTAssertNil(folded.undoLastBatch(at: time(11), batch: "u1", source: .spoken))
        XCTAssertEqual(folded.level(of: itemID).onHand, .whole(4))
    }

    // MARK: Round trip

    func testTheLogSurvivesEncoding() throws {
        var log = van(minimum: .whole(1))
        log.record(.loaded, itemID: itemID, quantity: .whole(4), at: time(0), batch: "b0", source: .spoken)
        log.record(.used, itemID: itemID, quantity: .whole(1), at: time(1), batch: "b1", source: .spoken, jobReference: "job-2031")
        log.edit(itemID: itemID, .standard(.whole(6), setBy: .van), at: time(2), batch: "b2", source: .typed)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(VanStockLog.self, from: encoder.encode(log))
        XCTAssertEqual(decoded, log)
        XCTAssertEqual(decoded.levels, log.levels)
    }
}
