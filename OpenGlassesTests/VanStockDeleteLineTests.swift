import XCTest
@testable import OpenGlasses

/// Deleting one line of stock from its page: it leaves the list with its lots, its count and
/// anything asked for; Undo puts it back where it stood; an older build still reads the file; and
/// a clinic's line with doses given or wasted is not deleted. Invented lines only.
@MainActor
final class VanStockDeleteLineTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_790_000_000)
    private func time(_ minutes: Int) -> Date { start.addingTimeInterval(Double(minutes) * 60) }

    /// Three lines, the middle one loaded and asked for.
    private func list() -> VanStockLog {
        var log = VanStockLog()
        log.addItem(id: "a", number: "AA-1", description: "Run capacitor", batch: "b0")
        log.addItem(id: "b", number: "BB-2", description: "Flame sensor", minimum: .whole(1), batch: "b0")
        log.addItem(id: "c", number: "CC-3", description: "Igniter", batch: "b0")
        log.record(.loaded, itemID: "b", quantity: .whole(4), at: time(0), batch: "b1", source: .spoken)
        log.record(.ordered, itemID: "b", quantity: .whole(2), at: time(1), batch: "b2", source: .spoken)
        return log
    }

    // MARK: - The ledger

    func testDeletingTakesTheLineOffAndKeepsItsHistory() throws {
        var log = list()
        let movementsBefore = log.movements.count
        let deleted = try XCTUnwrap(log.deleteItem("b", at: time(2), batch: "d1", source: .typed, id: "m-d1"))
        XCTAssertEqual(deleted.description, "Flame sensor")
        XCTAssertEqual(log.items.map(\.id), ["a", "c"])
        XCTAssertNil(log.levels["b"], "a line off the list has no level")
        XCTAssertFalse(log.lowItems.contains { $0.id == "b" })
        XCTAssertEqual(log.movements.count, movementsBefore + 1, "the history stays, with one note")
        let note = try XCTUnwrap(log.movements.last)
        XCTAssertEqual(note.kind, .edited)
        XCTAssertEqual(note.batch, "d1")
        XCTAssertEqual(note.oldValue, note.newValue, "the note changes nothing")
        XCTAssertTrue(log.canUndo)
    }

    func testDeletingALineTheListDoesNotHaveChangesNothing() {
        var log = list()
        let before = log
        XCTAssertNil(log.deleteItem("nope", at: time(2), batch: "d1", source: .typed))
        XCTAssertEqual(log, before)
    }

    func testUndoPutsTheLineBackWhereItStoodWithItsFigures() throws {
        var log = list()
        let before = log
        log.deleteItem("b", at: time(2), batch: "d1", source: .typed)
        let undone = try XCTUnwrap(log.undoLastBatch(at: time(3), batch: "u1", source: .typed))
        XCTAssertEqual(undone.restoredItems.map(\.id), ["b"])
        XCTAssertEqual(log.items, before.items, "back in the same place, unchanged")
        XCTAssertEqual(log.level(of: "b").onHand, .whole(4))
        XCTAssertEqual(log.level(of: "b").onOrder, .whole(2))
        XCTAssertTrue(log.deletedLines.isEmpty)
        XCTAssertFalse(log.canUndo, "an undo is not undone")
    }

    func testTheFirstAndLastLinesGoBackInPlaceToo() {
        for (id, order) in [("a", ["a", "b", "c"]), ("c", ["a", "b", "c"])] {
            var log = list()
            log.deleteItem(id, at: time(2), batch: "d1", source: .typed)
            log.undoLastBatch(at: time(3), batch: "u1", source: .typed)
            XCTAssertEqual(log.items.map(\.id), order, id)
        }
    }

    func testTheLinesLotsGoAndComeBackWithIt() throws {
        var log = list()
        let lot = try XCTUnwrap(log.addLot(id: "lot-1", itemID: "b", code: "L1", expiry: nil,
                                           receivedAt: time(1), batch: "b3"))
        log.record(.loaded, itemID: "b", quantity: .whole(3), at: time(1), batch: "b3", source: .scanned, lotID: lot.id)
        log.deleteItem("b", at: time(2), batch: "d1", source: .typed)
        XCTAssertTrue(log.lots(of: "b").isEmpty)
        log.undoLastBatch(at: time(3), batch: "u1", source: .typed)
        XCTAssertEqual(log.lots(of: "b"), [lot])
        XCTAssertEqual(log.level(of: "b").lots["lot-1"]?.onHand, .whole(3))
    }

    func testOnceSomethingElseIsRecordedTheDeletionCannotBeUndone() {
        var log = list()
        log.deleteItem("b", at: time(2), batch: "d1", source: .typed)
        log.record(.used, itemID: "a", quantity: .whole(1), at: time(3), batch: "b4", source: .spoken)
        log.undoLastBatch(at: time(4), batch: "u1", source: .spoken)
        XCTAssertNil(log.item(id: "b"), "undo took back the use, not the deletion")
        XCTAssertNil(log.undoLastBatch(at: time(5), batch: "u2", source: .spoken))
    }

    func testALaterDeletionReplacesTheKeptLine() {
        var log = list()
        log.deleteItem("a", at: time(2), batch: "d1", source: .typed)
        log.deleteItem("c", at: time(3), batch: "d2", source: .typed)
        XCTAssertEqual(log.deletedLines.map(\.item.id), ["c"])
        log.undoLastBatch(at: time(4), batch: "u1", source: .typed)
        XCTAssertEqual(log.items.map(\.id), ["b", "c"])
    }

    func testFoldingTheDeletionAwayForgetsTheKeptLine() {
        var log = list()
        log.deleteItem("b", at: time(2), batch: "d1", source: .typed)
        XCTAssertEqual(log.compacted(before: time(1)).deletedLines.count, 1, "the deletion is still recent")
        XCTAssertTrue(log.compacted(before: time(10)).deletedLines.isEmpty)
    }

    func testANewLineWithTheSameNumberStartsFresh() {
        var log = list()
        log.deleteItem("b", at: time(2), batch: "d1", source: .typed)
        log.addItem(id: "b2", number: "BB-2", description: "Flame sensor", batch: "b5")
        XCTAssertEqual(log.level(of: "b2").onHand, .zero)
        XCTAssertFalse(log.level(of: "b2").isRecorded)
    }

    // MARK: - On disk

    func testTheKeptLineSurvivesEncodingAndAListWithoutOneIsWrittenAsBefore() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let plain = list()
        let plainJSON = try XCTUnwrap(String(data: encoder.encode(plain), encoding: .utf8))
        XCTAssertFalse(plainJSON.contains("deleted_lines"))

        var log = list()
        log.deleteItem("b", at: time(2), batch: "d1", source: .typed)
        let decoded = try decoder.decode(VanStockLog.self, from: encoder.encode(log))
        XCTAssertEqual(decoded, log)
        var restored = decoded
        restored.undoLastBatch(at: time(3), batch: "u1", source: .typed)
        XCTAssertEqual(restored.items, plain.items)
    }

    /// An older build has no `deleted_lines` and no new movement kind: it reads the file as a
    /// list without the deleted line.
    func testAnOlderBuildReadsTheListWithoutTheLine() throws {
        struct OlderLog: Decodable {
            let items: [VanStockItem]
            let movements: [VanStockMovement]
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var log = list()
        log.deleteItem("b", at: time(2), batch: "d1", source: .typed)
        let older = try decoder.decode(OlderLog.self, from: encoder.encode(log))
        XCTAssertEqual(older.items.map(\.id), ["a", "c"])
        XCTAssertEqual(VanStockLog(items: older.items, movements: older.movements).levels.keys.sorted(), ["a", "c"])
    }

    // MARK: - The service

    private var directory: URL!
    private var store: VanStockStore!
    private var clinical = false
    private var counter = 0

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("van-stock-delete-tests-\(UUID().uuidString)", isDirectory: true)
        store = VanStockStore(directory: directory, now: start)
        clinical = false
        counter = 0
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private lazy var service = VanStockService(
        store: store,
        place: { .van },
        partsIndex: { VaultPartsIndex(files: []) },
        activeJob: { nil },
        now: { [unowned self] in self.time(self.counter) },
        makeID: { [unowned self] in
            self.counter += 1
            return "id-\(self.counter)"
        },
        clinical: { [unowned self] in self.clinical })

    func testTheScreenDeletesALineAndUndoSaysWhatCameBack() throws {
        store.update { $0 = self.list() }
        XCTAssertNil(service.deletionBlock(itemID: "b"))
        XCTAssertTrue(service.deleteLine(itemID: "b"))
        XCTAssertNil(store.log.item(id: "b"))
        XCTAssertTrue(service.canUndo)
        let said = service.undo(source: .typed)
        XCTAssertTrue(said.contains("the deletion of"), said)
        XCTAssertNotNil(store.log.item(id: "b"))
    }

    func testTheDeletionIsKeptOnDisk() {
        store.update { $0 = self.list() }
        service.deleteLine(itemID: "b")
        let reopened = VanStockStore(directory: directory, now: start)
        XCTAssertNil(reopened.log.item(id: "b"))
        XCTAssertEqual(reopened.log.deletedLines.map(\.item.id), ["b"])
    }

    func testALineTheListDoesNotHaveIsUnavailable() {
        store.update { $0 = self.list() }
        XCTAssertEqual(service.deletionBlock(itemID: "nope"), .unavailable)
        XCTAssertFalse(service.deleteLine(itemID: "nope"))
    }

    func testAClinicsLineWithADoseGivenOrWastedIsNotDeleted() {
        clinical = true
        for kind in [VanStockMovement.Kind.used, .wasted] {
            store.update { log in
                log = self.list()
                log.record(kind, itemID: "b", quantity: .whole(1), at: self.time(2), batch: "g1", source: .spoken)
            }
            XCTAssertEqual(service.deletionBlock(itemID: "b"), .clinicalRecord, "\(kind)")
            XCTAssertFalse(service.deleteLine(itemID: "b"))
            XCTAssertNotNil(store.log.item(id: "b"))
        }
    }

    func testAClinicsLineWhoseDoseWasTakenBackCanBeDeleted() {
        clinical = true
        store.update { log in
            log = self.list()
            log.record(.used, itemID: "b", quantity: .whole(1), at: self.time(2), batch: "g1", source: .spoken)
            log.undoLastBatch(at: self.time(3), batch: "u0", source: .spoken)
        }
        XCTAssertNil(service.deletionBlock(itemID: "b"))
        XCTAssertNil(service.deletionBlock(itemID: "a"), "nothing given from it")
    }

    func testAVansLineWithUsesCanBeDeleted() {
        store.update { log in
            log = self.list()
            log.record(.used, itemID: "b", quantity: .whole(1), at: self.time(2), batch: "g1", source: .spoken)
        }
        XCTAssertNil(service.deletionBlock(itemID: "b"))
        XCTAssertTrue(service.deleteLine(itemID: "b"))
    }

    // MARK: - The spreadsheet

    func testTheHistorySheetStillNamesADeletedLine() throws {
        var log = list()
        log.deleteItem("b", at: time(2), batch: "d1", source: .typed)
        let sheets = try XLSXReader.read(VanStockSheet.data(log, exportedAt: time(3), calendar: .current)).get()
        let history = try XCTUnwrap(sheets.first { $0.rows.first?.first == "When" })
        let named = history.rows.dropFirst().filter { $0.count > 1 && $0[1] == "Flame sensor" }
        XCTAssertFalse(named.isEmpty, "the deleted line's rows carry its name")
    }
}
