import XCTest
@testable import OpenGlasses

/// Plan ML P1 — a format 1 log, whole units throughout, becomes format 2 in thousandths, and
/// every figure it gives works out the same as before, times 1,000.
final class VanStockLogMigrationTests: XCTestCase {

    // MARK: The recorded log

    /// 2026-11-01 10:00 UTC plus `minutes`.
    static func time(_ minutes: Int) -> Date {
        ISO8601DateFormatter().date(from: "2026-11-01T10:00:00Z")!.addingTimeInterval(Double(minutes) * 60)
    }

    /// A format 1 log as an older build wrote it: an opening figure, loads, a use for a job, a
    /// removal, a count, an order part covered by a load, a minimum edit, a standard set by base,
    /// a unit edited from each to litres, a use taken back, and a standard this truck changed.
    static let recordedLog = #"""
    {"items":[
     {"codes":[],"created_batch":"b0","description":"Flame sensor","id":"sensor","minimum":2,"number":"62-23543-01",
      "standard":8,"standard_set_by":"van","unit":"each","verification":{"state":"found"},"verified":true},
     {"codes":[],"created_batch":"b0","description":"Fuse","id":"fuse","minimum":5,"unit":"each",
      "verification":{"state":"not_checked"},"verified":false},
     {"codes":[],"created_batch":"b0","description":"Engine oil","id":"oil","unit":"l",
      "verification":{"state":"not_checked"},"verified":false}],
    "movements":[
     {"at":"2026-11-01T08:20:00Z","batch":"opening","id":"opening-oil","item_id":"oil","kind":"opening",
      "opening_counted":true,"opening_unreliable":false,"quantity":4,"source":"typed"},
     {"at":"2026-11-01T10:00:00Z","batch":"b1","id":"m1","item_id":"sensor","kind":"loaded","quantity":4,"source":"spoken"},
     {"at":"2026-11-01T10:01:00Z","batch":"b2","id":"m2","item_id":"sensor","job_reference":"job-2031",
      "job_session_id":"s1","kind":"used","quantity":1,"source":"spoken"},
     {"at":"2026-11-01T10:02:00Z","batch":"b3","id":"m3","item_id":"sensor","kind":"removed","quantity":1,
      "reason":"returned","source":"spoken"},
     {"at":"2026-11-01T10:03:00Z","batch":"b4","id":"m4","item_id":"fuse","kind":"counted","quantity":3,"source":"typed"},
     {"at":"2026-11-01T10:04:00Z","batch":"b5","id":"m5","item_id":"sensor","kind":"ordered","quantity":3,
      "request_id":"r1","source":"spoken"},
     {"at":"2026-11-01T10:05:00Z","batch":"b6","id":"m6","item_id":"sensor","kind":"loaded","quantity":1,"source":"spoken"},
     {"at":"2026-11-01T10:06:00Z","attribute":"minimum","batch":"b7","id":"m7","item_id":"sensor","kind":"edited",
      "new_value":"2","quantity":0,"source":"typed"},
     {"at":"2026-11-01T10:07:00Z","attribute":"standard","batch":"b8","id":"m8","item_id":"sensor","kind":"edited",
      "new_value":"6:base","quantity":0,"source":"sheet"},
     {"at":"2026-11-01T10:08:00Z","attribute":"unit","batch":"b9","id":"m9","item_id":"oil","kind":"edited",
      "new_value":"l","old_value":"each","quantity":0,"source":"typed"},
     {"at":"2026-11-01T10:09:00Z","batch":"b10","id":"m10","item_id":"oil","kind":"used","quantity":1,"source":"spoken"},
     {"at":"2026-11-01T10:10:00Z","batch":"u1","id":"m11","item_id":"oil","kind":"reversed","quantity":0,
      "reverses":"m10","source":"spoken"},
     {"at":"2026-11-01T10:11:00Z","batch":"b12","id":"m12","item_id":"oil","kind":"used","quantity":2,"source":"spoken"},
     {"at":"2026-11-01T10:12:00Z","attribute":"standard","batch":"b13","id":"m13","item_id":"sensor","kind":"edited",
      "new_value":"8:van","old_value":"6:base","quantity":0,"source":"typed"}]}
    """#

    /// The same log as a format 1 file on disk.
    static var recordedFile: String { #"{"van":{"id":"v4","name":"Truck 4"},"version":1,"log":"# + recordedLog + "}" }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func migrated() throws -> VanStockLog {
        VanStockLogMigration.fromFormat1(
            try decoder().decode(VanStockLogMigration.Format1Log.self, from: Data(Self.recordedLog.utf8)))
    }

    /// The same history recorded through today's ledger in whole units, which is what the
    /// migration has to arrive at.
    private func recordedToday() -> VanStockLog {
        let t = Self.time
        var log = VanStockLog()
        log.addItem(id: "sensor", number: "62-23543-01", description: "Flame sensor", verified: true, batch: "b0")
        log.addItem(id: "fuse", description: "Fuse", minimum: .whole(5), batch: "b0")
        log.addItem(id: "oil", description: "Engine oil", batch: "b0")
        log.appendOpening(itemID: "oil", quantity: .whole(4), at: t(-100), source: .typed, counted: true, unreliable: false)
        log.record(.loaded, itemID: "sensor", quantity: .whole(4), at: t(0), batch: "b1", source: .spoken, id: "m1")
        log.record(.used, itemID: "sensor", quantity: .whole(1), at: t(1), batch: "b2", source: .spoken, id: "m2",
                   jobSessionID: "s1", jobReference: "job-2031")
        log.record(.removed, itemID: "sensor", quantity: .whole(1), at: t(2), batch: "b3", source: .spoken, id: "m3",
                   reason: .returned)
        log.record(.counted, itemID: "fuse", quantity: .whole(3), at: t(3), batch: "b4", source: .typed, id: "m4")
        log.record(.ordered, itemID: "sensor", quantity: .whole(3), at: t(4), batch: "b5", source: .spoken, id: "m5",
                   requestID: "r1")
        log.record(.loaded, itemID: "sensor", quantity: .whole(1), at: t(5), batch: "b6", source: .spoken, id: "m6")
        log.edit(itemID: "sensor", .minimum(.whole(2)), at: t(6), batch: "b7", source: .typed, id: "m7")
        log.edit(itemID: "sensor", .standard(.whole(6), setBy: .base), at: t(7), batch: "b8", source: .sheet, id: "m8")
        log.edit(itemID: "oil", .unit(.l), at: t(8), batch: "b9", source: .typed, id: "m9")
        log.record(.used, itemID: "oil", quantity: .whole(1), at: t(9), batch: "b10", source: .spoken, id: "m10")
        log.undoLastBatch(at: t(10), batch: "u1", source: .spoken, makeID: { "m11" })
        log.record(.used, itemID: "oil", quantity: .whole(2), at: t(11), batch: "b12", source: .spoken, id: "m12")
        log.edit(itemID: "sensor", .standard(.whole(8), setBy: .van), at: t(12), batch: "b13", source: .typed, id: "m13")
        return log
    }

    // MARK: Every figure, times 1,000

    func testTheRecordedLogMigratesToExactlyWhatTodaysLedgerRecords() throws {
        let log = try migrated()
        XCTAssertEqual(log, recordedToday())
    }

    func testEveryLevelLowMarkOrderAndTopUpIsAThousandTimesTheFormat1Figure() throws {
        let log = try migrated()
        let levels = log.levels

        // Format 1 gave: sensor 3 on hand with 2 of 3 still on order, fuse counted at 3, oil 2.
        XCTAssertEqual(levels["sensor"]?.onHand.scaled, 3_000)
        XCTAssertEqual(levels["sensor"]?.onOrder.scaled, 2_000)
        XCTAssertEqual(levels["sensor"]?.oldestOrderAt, Self.time(4))
        XCTAssertEqual(levels["sensor"]?.provenance, .inferred)
        XCTAssertEqual(levels["fuse"]?.onHand.scaled, 3_000)
        XCTAssertEqual(levels["fuse"]?.provenance, .counted)
        XCTAssertEqual(levels["oil"]?.onHand.scaled, 2_000, "the use taken back stays taken back")
        XCTAssertEqual(levels.values.filter(\.unreliable).count, 0)

        XCTAssertEqual(log.item(id: "sensor")?.minimum?.scaled, 2_000)
        XCTAssertEqual(log.item(id: "sensor")?.standard?.scaled, 8_000)
        XCTAssertEqual(log.item(id: "sensor")?.standardSetBy, .van)
        XCTAssertEqual(log.item(id: "fuse")?.minimum?.scaled, 5_000)

        // Low: the fuse at 3 against a minimum of 5; the sensor at 3 is above its 2.
        XCTAssertEqual(log.lowItems.map(\.id), ["fuse"])

        // Top-up: the sensor is 5 short of its standard of 8.
        let topUp = VanStockHandover.topUp(log)
        XCTAssertEqual(topUp.map(\.item.id), ["sensor"])
        XCTAssertEqual(topUp.first?.onHand.scaled, 3_000)
        XCTAssertEqual(topUp.first?.short?.scaled, 5_000)

        // The open order survives a fold, at its remaining figure.
        let folded = log.compacted(before: Self.time(60))
        let carriedOrder = folded.movements.first { $0.kind == .ordered }
        XCTAssertEqual(carriedOrder?.quantity.scaled, 2_000)
        XCTAssertEqual(folded.levels, levels)
    }

    func testTheEditStringsAreRescaledAndUndoReadsThemBack() throws {
        var log = try migrated()
        let edits = Dictionary(uniqueKeysWithValues: log.movements.filter { $0.kind == .edited }.map { ($0.id, $0) })
        XCTAssertNil(edits["m7"]?.oldValue)
        XCTAssertEqual(edits["m7"]?.newValue, "2000")
        XCTAssertEqual(edits["m8"]?.newValue, "6000:base")
        XCTAssertEqual(edits["m13"]?.oldValue, "6000:base")
        XCTAssertEqual(edits["m13"]?.newValue, "8000:van")
        XCTAssertEqual(log.movements.filter { $0.kind == .edited || $0.kind == .reversed }.map(\.quantity),
                       Array(repeating: .zero, count: 5), "kinds with no quantity keep their zero")

        // Undo takes back the last batch, the standard this truck set, back to base's 6.
        let undone = log.undoLastBatch(at: Self.time(20), batch: "u2", source: .typed, makeID: { "m14" })
        XCTAssertEqual(undone?.batch, "b13")
        XCTAssertEqual(log.item(id: "sensor")?.standard?.scaled, 6_000)
        XCTAssertEqual(log.item(id: "sensor")?.standardSetBy, .base)
        XCTAssertEqual(VanStockHandover.topUp(log).first?.short?.scaled, 3_000)
    }

    func testALineWhoseUnitWasEditedFromEachToLitresKeepsItsFigures() throws {
        let log = try migrated()
        XCTAssertEqual(log.item(id: "oil")?.unit, .l)
        let unitEdit = log.movements.first { $0.id == "m9" }
        XCTAssertEqual(unitEdit?.oldValue, "each")
        XCTAssertEqual(unitEdit?.newValue, "l")
        // The opening was counted in each and the uses in litres; one scale, so both are × 1,000.
        XCTAssertEqual(log.movements.first { $0.id == "opening-oil" }?.quantity, .whole(4))
        XCTAssertEqual(log.movements.first { $0.id == "m12" }?.quantity, .whole(2))
        XCTAssertEqual(log.level(of: "oil").onHand, .whole(2))
        XCTAssertEqual(log.level(of: "oil").provenance, .inferred)
    }

    // MARK: The pieces

    func testEditTextIsRescaledOnlyWhenItIsAFigure() {
        XCTAssertEqual(VanStockLogMigration.scaledMinimum("4"), "4000")
        XCTAssertEqual(VanStockLogMigration.scaledMinimum("0"), "0")
        XCTAssertEqual(VanStockLogMigration.scaledMinimum("x"), "x")
        XCTAssertEqual(VanStockLogMigration.scaledMinimum("-1"), "-1")
        XCTAssertEqual(VanStockLogMigration.scaledStandard("4:base"), "4000:base")
        XCTAssertEqual(VanStockLogMigration.scaledStandard("4"), "4000")
        XCTAssertEqual(VanStockLogMigration.scaledStandard("4:van"), "4000:van")
    }

    func testAFormat1FigureOutOfRangeRefusesTheLogRatherThanOverflowing() {
        let tooMany = #"{"items":[{"codes":[],"created_batch":"b0","description":"Fuse","id":"fuse","unit":"each","verified":false}],"#
            + #""movements":[{"at":"2026-11-01T10:00:00Z","batch":"b1","id":"m1","item_id":"fuse","kind":"loaded","#
            + #""quantity":2000000,"source":"spoken"}]}"#
        XCTAssertThrowsError(try decoder().decode(VanStockLogMigration.Format1Log.self, from: Data(tooMany.utf8)))
        let negativeMinimum = #"{"items":[{"codes":[],"created_batch":"b0","description":"Fuse","id":"fuse","minimum":-1,"unit":"each","verified":false}],"movements":[]}"#
        XCTAssertThrowsError(try decoder().decode(VanStockLogMigration.Format1Log.self, from: Data(negativeMinimum.utf8)))
    }
}
