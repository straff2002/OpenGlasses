import XCTest
@testable import OpenGlasses

/// Plan MK P0 — a line's number is found, not found, or not checked, and says which book answered
/// (§4). Everything stored before keeps reading as it did.
final class VanStockVerificationTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func item(json: String) throws -> VanStockItem {
        try JSONDecoder().decode(VanStockItem.self, from: Data(json.utf8))
    }

    private let olderLine = #"{"id":"i1","number":"00123","description":"Flame sensor","unit":"each","codes":[],"created_batch":"b0""#

    // MARK: The three states

    func testTheStatesAndTheirBooks() {
        XCTAssertEqual(VanStockVerification.found(in: "Supplier catalogue").vault, "Supplier catalogue")
        XCTAssertEqual(VanStockVerification.notFound(in: "Supplier catalogue").state, .notFound)
        XCTAssertNil(VanStockVerification(state: .notChecked, vault: "Supplier catalogue").vault,
                     "nothing was asked, so no book answered")
        XCTAssertNil(VanStockVerification.found(in: "  ").vault)
        XCTAssertTrue(VanStockVerification.found(in: nil).isFound)
        XCTAssertFalse(VanStockVerification.notFound(in: "Furnace manual").isFound)
        XCTAssertFalse(VanStockVerification.notChecked.isFound)
    }

    func testAVerificationRoundTrips() throws {
        for value in [VanStockVerification.found(in: "Supplier catalogue"), .found(in: nil),
                      .notFound(in: "Furnace manual"), .notChecked] {
            XCTAssertEqual(try JSONDecoder().decode(VanStockVerification.self, from: JSONEncoder().encode(value)), value)
            XCTAssertEqual(VanStockVerification(storedValue: value.storedValue), value)
        }
        XCTAssertEqual(VanStockVerification.notFound(in: "Book: volume 2").storedValue, "not_found:Book: volume 2")
        XCTAssertEqual(VanStockVerification(storedValue: "not_found:Book: volume 2").vault, "Book: volume 2")
    }

    func testAStateFromANewerBuildReadsAsNotChecked() throws {
        let newer = Data(#"{"state":"superseded","vault":"Furnace manual"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(VanStockVerification.self, from: newer).state, .notChecked)
        XCTAssertEqual(VanStockVerification(storedValue: "superseded:Furnace manual"), .notChecked)
    }

    // MARK: Lines stored before

    func testAStoredTrueIsFound() throws {
        let line = try item(json: olderLine + #","verified":true}"#)
        XCTAssertEqual(line.verification, .found(in: nil))
        XCTAssertTrue(line.verified)
    }

    func testAStoredFalseIsNotCheckedNeverNotFound() throws {
        let line = try item(json: olderLine + #","verified":false}"#)
        XCTAssertEqual(line.verification, .notChecked, "today's false cannot say whether anything was searched")
        XCTAssertFalse(line.verified)
    }

    func testALineWithNoVerificationAtAllIsNotChecked() throws {
        XCTAssertEqual(try item(json: olderLine + "}").verification, .notChecked)
    }

    func testTheNewKeyWinsAndBothAreWrittenForAnOlderBuild() throws {
        let line = VanStockItem(id: "i1", number: "00123", description: "Flame sensor",
                                verification: .notFound(in: "Supplier catalogue"), createdBatch: "b0")
        let data = try JSONEncoder().encode(line)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["verified"] as? Bool, false, "an older build requires verified")
        XCTAssertNotNil(object["verification"])
        XCTAssertEqual(try JSONDecoder().decode(VanStockItem.self, from: data), line)

        let disagreeing = olderLine + #","verified":true,"verification":{"state":"not_found","vault":"Furnace manual"}}"#
        XCTAssertEqual(try item(json: disagreeing).verification, .notFound(in: "Furnace manual"))
    }

    func testTheOldInitialiserStillMeansWhatItDid() {
        XCTAssertEqual(VanStockItem(description: "Igniter", verified: true, createdBatch: "b0").verification, .found(in: nil))
        XCTAssertEqual(VanStockItem(description: "Igniter", createdBatch: "b0").verification, .notChecked)
        var log = VanStockLog()
        XCTAssertEqual(log.addItem(description: "Igniter", verified: true, batch: "b0").verification, .found(in: nil))
        XCTAssertEqual(log.addItem(number: "22B22", description: "Igniter", verification: .notFound(in: "Furnace manual"),
                                   batch: "b0").verification, .notFound(in: "Furnace manual"))
    }

    func testTheBoolOnlyChangesTheStateWhenTheAnswerChanges() {
        var line = VanStockItem(description: "Igniter", verification: .notFound(in: "Furnace manual"), createdBatch: "b0")
        line.verified = false
        XCTAssertEqual(line.verification, .notFound(in: "Furnace manual"), "already not found, so nothing changes")
        line.verified = true
        XCTAssertEqual(line.verification, .found(in: nil))
        line.verification = .found(in: "Furnace manual")
        line.verified = true
        XCTAssertEqual(line.verification, .found(in: "Furnace manual"), "a found line keeps its book")
        line.verified = false
        XCTAssertEqual(line.verification, .notChecked)
    }

    // MARK: The log

    func testAnOldLogWithAVerifiedEditStillDecodesAndUndoes() throws {
        let older = Data("""
        {"items":[{"id":"i1","number":"00123","description":"Flame sensor","unit":"each","codes":[],
                   "verified":true,"created_batch":"b0"}],
         "movements":[{"id":"m1","item_id":"i1","kind":"edited","quantity":0,"at":"2026-09-21T14:13:20Z",
                       "batch":"b1","source":"sheet","attribute":"verified","old_value":"false","new_value":"true"}]}
        """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var log = try decoder.decode(VanStockLog.self, from: older)
        XCTAssertEqual(log.item(id: "i1")?.verification, .found(in: nil))
        XCTAssertEqual(log.movements.first?.attribute, .verified)

        XCTAssertNotNil(log.undoLastBatch(at: start, batch: "u", source: .typed, makeID: { "r1" }))
        XCTAssertEqual(log.item(id: "i1")?.verification, .notChecked, "an old false comes back as not checked")
    }

    func testANewVerificationEditIsRecordedUnderTheSameAttributeAndUndoes() throws {
        var log = VanStockLog()
        log.addItem(id: "i1", number: "00123", description: "Flame sensor",
                    verification: .notFound(in: "Furnace manual"), batch: "b0")
        XCTAssertTrue(log.edit(itemID: "i1", .verification(.found(in: "Supplier catalogue")), at: start,
                               batch: "b1", source: .typed, id: "m1"))
        let edit = try XCTUnwrap(log.movements.last)
        XCTAssertEqual(edit.attribute, .verified, "an older build still reads the log")
        XCTAssertEqual(edit.oldValue, "not_found:Furnace manual")
        XCTAssertEqual(edit.newValue, "found:Supplier catalogue")
        XCTAssertEqual(log.item(id: "i1")?.verification, .found(in: "Supplier catalogue"))

        XCTAssertFalse(log.edit(itemID: "i1", .verification(.found(in: "Supplier catalogue")), at: start,
                                batch: "b2", source: .typed), "the same answer is no change")

        log.undoLastBatch(at: start, batch: "u", source: .typed, makeID: { "r1" })
        XCTAssertEqual(log.item(id: "i1")?.verification, .notFound(in: "Furnace manual"), "the book comes back with the state")
    }

    func testTheOldBoolEditStillRecordsTrueAndFalse() {
        var log = VanStockLog()
        log.addItem(id: "i1", number: "00123", description: "Flame sensor", batch: "b0")
        XCTAssertTrue(log.edit(itemID: "i1", .verified(true), at: start, batch: "b1", source: .typed))
        XCTAssertEqual(log.movements.last?.oldValue, "false")
        XCTAssertEqual(log.movements.last?.newValue, "true")
        XCTAssertEqual(log.item(id: "i1")?.verification, .found(in: nil))
        log.undoLastBatch(at: start, batch: "u", source: .typed)
        XCTAssertEqual(log.item(id: "i1")?.verification, .notChecked)
    }

    // MARK: The book a number is looked up in (Plan MK P1, §4)

    private final class Books {
        var job: VanStockBook?
        var named: [String: VanStockBook] = [:]
        var namedAsked: [String] = []
        var searches: [String] = []

        @MainActor
        func book(_ name: String, holds numbers: Set<String>) -> VanStockBook {
            VanStockBook(name: name, verify: { [unowned self] number in
                self.searches.append(name)
                let cleaned = VaultPartsIndex.normalise(number)
                return TaskPart(number: cleaned, partDescription: numbers.contains(cleaned) ? "From \(name)" : nil,
                                verified: numbers.contains(cleaned))
            })
        }

        @MainActor
        var seam: VanStockBooks {
            VanStockBooks(job: { [unowned self] in self.job },
                          named: { [unowned self] id in self.namedAsked.append(id); return self.named[id] })
        }
    }

    @MainActor
    private func service(_ store: VanStockStore, _ books: Books, clock: @escaping () -> Date = { Date(timeIntervalSince1970: 1_790_000_000) })
        -> VanStockService {
        var counter = 0
        return VanStockService(store: store, books: books.seam, partsIndex: { VaultPartsIndex(files: []) },
                               activeJob: { nil }, now: clock,
                               makeID: { counter += 1; return "id-\(counter)" })
    }

    @MainActor
    private func store() -> (VanStockStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("van-stock-verification-tests-\(UUID().uuidString)", isDirectory: true)
        return (VanStockStore(directory: directory, now: start), directory)
    }

    @MainActor
    func testTheBookOrderIsTheJobThenTheNamedVaultThenNone() {
        let (store, directory) = store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let books = Books()
        books.named["catalogue"] = books.book("Supplier catalogue", holds: ["00123"])
        books.job = books.book("Furnace manual", holds: [])
        store.checkNumbers(against: "catalogue")
        var clock = start
        let service = service(store, books, clock: { clock })

        // A job is open: its vault answers, and the named one is not asked.
        _ = service.load([.init(part: "00123", description: "Flame sensor", quantity: .whole(1))])
        XCTAssertEqual(store.log.items.last?.verification, .notFound(in: "Furnace manual"))
        XCTAssertEqual(books.namedAsked, [])

        // No job: the list's named vault answers.
        books.job = nil
        clock.addTimeInterval(60)
        _ = service.load([.init(part: "00456", description: "Igniter", quantity: .whole(1))])
        XCTAssertEqual(store.log.items.last?.verification, .notFound(in: "Supplier catalogue"))
        clock.addTimeInterval(60)
        _ = service.count([.init(part: "00123", quantity: .whole(4))])
        XCTAssertEqual(store.log.items.first?.verification, .found(in: "Supplier catalogue"),
                       "a later look with a book upgrades a not-found line it holds")

        // No job and no named vault: nothing is searched.
        store.checkNumbers(against: nil)
        let searched = books.searches.count
        clock.addTimeInterval(60)
        _ = service.load([.init(part: "00789", description: "Fuse", quantity: .whole(1))])
        XCTAssertEqual(books.searches.count, searched, "no book, no search")
        XCTAssertEqual(store.log.items.last?.verification, .notChecked)
    }

    @MainActor
    func testARemovedVaultIsNoBook() {
        let (store, directory) = store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let books = Books()
        store.checkNumbers(against: "gone")   // named, then removed: the seam has no book for it
        let service = service(store, books)
        _ = service.load([.init(part: "00123", description: "Flame sensor", quantity: .whole(1))])
        XCTAssertEqual(books.namedAsked, ["gone"])
        XCTAssertEqual(store.log.items.first?.verification, .notChecked)

        // The phone's own seam: a vault that is not installed is no book.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vs-books-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = FieldSessionService(sessionsRoot: root)
        XCTAssertNil(sessions.vanStockBook(forVault: "no-such-vault-\(UUID().uuidString)"))
        XCTAssertNil(sessions.vanStockJobBook, "no job open, so no job book")
    }

    @MainActor
    func testNoBookNeverRecordsNotFoundAndALaterBookUpgradesIt() {
        let (store, directory) = store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let books = Books()
        var clock = start
        let service = service(store, books, clock: { clock })
        _ = service.load([.init(part: "00123", description: "Flame sensor", quantity: .whole(1))])
        XCTAssertEqual(store.log.items.first?.verification, .notChecked, "nothing was searched, so it is not not found")
        XCTAssertFalse(VanStockRows.rows(store.log).first?.isNotFound ?? true, "and carries no mark")

        books.named["catalogue"] = books.book("Supplier catalogue", holds: [])
        store.checkNumbers(against: "catalogue")
        clock.addTimeInterval(60)
        _ = service.load([.init(part: "00123", quantity: .whole(1))])
        XCTAssertEqual(store.log.items.first?.verification, .notFound(in: "Supplier catalogue"),
                       "a later look that has a book records what it said")

        // A look that has no book never takes the answer back.
        store.checkNumbers(against: nil)
        clock.addTimeInterval(60)
        _ = service.load([.init(part: "00123", quantity: .whole(1))])
        XCTAssertEqual(store.log.items.first?.verification, .notFound(in: "Supplier catalogue"))
    }

    @MainActor
    func testTheSentenceTheReadBackAndTheMarkNameTheBook() {
        let (store, directory) = store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let books = Books()
        books.named["catalogue"] = books.book("Supplier catalogue", holds: ["00123"])
        store.checkNumbers(against: "catalogue")
        store.setPlace(.store)
        var clock = start
        let service = service(store, books, clock: { clock })

        let loaded = service.load([.init(part: "00456", description: "Gin", quantity: .whole(2))])
        XCTAssertTrue(loaded.contains("Part number 00456 is not in Supplier catalogue and has not been on this list."), loaded)
        let check = service.check(.init(part: "00456"))
        XCTAssertTrue(check.hasSuffix("The part number is not found in Supplier catalogue."), check)
        let row = VanStockRows.rows(store.log).first
        XCTAssertEqual(row?.isNotFound, true)
        XCTAssertEqual(row?.notFoundLabel, "Not found in Supplier catalogue")

        clock.addTimeInterval(60)
        let found = service.load([.init(part: "00123", description: "Tonic", quantity: .whole(2))])
        XCTAssertFalse(found.contains("Read it back"), "a number its book holds is not spelled out")
        XCTAssertFalse(service.check(.init(part: "00123")).contains("not found"))
        XCTAssertNil(VanStockRows.rows(store.log).first { $0.item.number == "00123" }?.notFoundLabel)
        for text in [loaded, check, found] {
            XCTAssertFalse(text.contains("manuals"), text)
        }
    }
}
