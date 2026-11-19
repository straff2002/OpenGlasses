import XCTest
@testable import OpenGlasses

/// Plan IH P1 — the van's stock on disk: kept, protected, and refused when it cannot be read.
@MainActor
final class VanStockStoreTests: XCTestCase {

    private var directory: URL!
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("van-stock-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private var fileURL: URL { directory.appendingPathComponent("van-stock.json") }

    private func loadOne(into store: VanStockStore, at date: Date) {
        store.update { log in
            let item = log.addItem(id: "item-1", number: "62-23543-01", description: "Flame sensor", batch: "b0")
            log.record(.loaded, itemID: item.id, quantity: .whole(4), at: date, batch: "b0", source: .spoken)
        }
    }

    func testANewStoreIsEmptyAndWritesNothing() {
        let store = VanStockStore(directory: directory, now: start)
        XCTAssertTrue(store.log.isEmpty)
        XCTAssertFalse(store.isUnreadable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testAChangeSurvivesARelaunch() {
        loadOne(into: VanStockStore(directory: directory, now: start), at: start)
        let reopened = VanStockStore(directory: directory, now: start)
        XCTAssertEqual(reopened.log.items.map(\.id), ["item-1"])
        XCTAssertEqual(reopened.log.level(of: "item-1").onHand, .whole(4))
        XCTAssertFalse(reopened.isUnreadable)
    }

    func testAChangeThatChangesNothingIsNotWritten() {
        let store = VanStockStore(directory: directory, now: start)
        XCTAssertEqual(store.update { _ in 7 }, 7)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testTheFileIsProtectedAndStaysInTheBackup() throws {
        loadOne(into: VanStockStore(directory: directory, now: start), at: start)
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        #if !targetEnvironment(simulator)
        XCTAssertEqual(attributes[.protectionKey] as? FileProtectionType, VanStockStore.fileProtection)
        #else
        _ = attributes
        #endif
        let values = try fileURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertNotEqual(values.isExcludedFromBackup, true, "a new phone should still know what is on the truck")
    }

    func testATornFileIsRefusedNotHalfReadAndNotOverwritten() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let torn = Data(#"{"version":1,"log":{"items":[{"id":"item-1","#.utf8)
        try torn.write(to: fileURL)

        let store = VanStockStore(directory: directory, now: start)
        XCTAssertTrue(store.isUnreadable)
        XCTAssertTrue(store.log.isEmpty)
        XCTAssertNil(store.update { $0.addItem(description: "Igniter", batch: "b1") }, "nothing is written over it")
        XCTAssertEqual(try Data(contentsOf: fileURL), torn)
    }

    func testAFileFromALaterFormatIsRefused() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"version":99,"log":{"items":[],"movements":[]}}"#.utf8).write(to: fileURL)
        XCTAssertTrue(VanStockStore(directory: directory, now: start).isUnreadable)
    }

    // MARK: Plan ML P1 — format 2, in thousandths

    private func storedVersion(_ url: URL) throws -> Int? {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        return object?["version"] as? Int
    }

    private var archiveURL: URL { directory.appendingPathComponent("van-stock-previous.json") }

    func testAFormat1FileLoadsMigratedAndIsRewrittenAsFormat2() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(VanStockLogMigrationTests.recordedFile.utf8).write(to: fileURL)

        let store = VanStockStore(directory: directory, now: VanStockLogMigrationTests.time(60))
        XCTAssertFalse(store.isUnreadable)
        XCTAssertEqual(store.van, VanIdentity(id: "v4", name: "Truck 4"))
        XCTAssertEqual(store.log.level(of: "sensor").onHand.scaled, 3_000)
        XCTAssertEqual(store.log.level(of: "sensor").onOrder.scaled, 2_000)
        XCTAssertEqual(store.log.item(id: "sensor")?.standard?.scaled, 8_000)

        // Written back at once, as format 2, with its figures in thousandths.
        XCTAssertEqual(VanStockStore.formatVersion, 2)
        XCTAssertEqual(try storedVersion(fileURL), 2)
        let onDisk = try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        let movements = (onDisk?["log"] as? [String: Any])?["movements"] as? [[String: Any]]
        XCTAssertEqual(movements?.first { $0["id"] as? String == "m1" }?["quantity"] as? Int, 4_000)

        // Read again, it is format 2 and is not migrated a second time.
        let reopened = VanStockStore(directory: directory, now: VanStockLogMigrationTests.time(60))
        XCTAssertEqual(reopened.log, store.log)
        XCTAssertEqual(reopened.log.level(of: "sensor").onHand.scaled, 3_000)
    }

    func testAFormat3FileIsRefusedAndNeverOverwritten() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // A later format, as format 2 is to an older build: it is refused, never read as something else.
        let later = Data(#"{"version":3,"log":{"items":[{"id":"oil","description":"Engine oil","unit":"l","codes":[],"created_batch":"b0"}],"movements":[{"id":"m1","item_id":"oil","kind":"counted","quantity":4250,"at":"2026-11-01T10:00:00Z","batch":"b1","source":"typed"}]}}"#.utf8)
        try later.write(to: fileURL)

        let store = VanStockStore(directory: directory, now: start)
        XCTAssertTrue(store.isUnreadable)
        XCTAssertTrue(store.log.isEmpty)
        XCTAssertNil(store.update { $0.addItem(description: "Igniter", batch: "b1") })
        store.nameVan("Truck 9")
        XCTAssertEqual(try Data(contentsOf: fileURL), later, "the bytes on disk are untouched")
    }

    func testAFormat1ArchiveIsMigratedWhenItIsRestored() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(VanStockLogMigrationTests.recordedFile.utf8).write(to: archiveURL)

        let store = VanStockStore(directory: directory, now: VanStockLogMigrationTests.time(60))
        XCTAssertTrue(store.log.isEmpty)
        XCTAssertTrue(store.hasPrevious)
        XCTAssertTrue(store.restorePrevious())
        XCTAssertEqual(store.van, VanIdentity(id: "v4", name: "Truck 4"))
        XCTAssertEqual(store.log.level(of: "sensor").onHand.scaled, 3_000)
        XCTAssertEqual(store.log.level(of: "oil").onHand.scaled, 2_000)
        XCTAssertEqual(store.log.item(id: "fuse")?.minimum?.scaled, 5_000)
        XCTAssertFalse(store.hasPrevious)
        XCTAssertEqual(try storedVersion(fileURL), 2, "the restored list is kept as format 2")
    }

    func testRemoveAllClearsAnUnreadableFileAndTheStoreWorksAgain() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: fileURL)
        let store = VanStockStore(directory: directory, now: start)
        XCTAssertTrue(store.isUnreadable)
        store.removeAll()
        XCTAssertFalse(store.isUnreadable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        loadOne(into: store, at: start)
        XCTAssertEqual(VanStockStore(directory: directory, now: start).log.level(of: "item-1").onHand, .whole(4))
    }

    func testOldHistoryIsFoldedOnLoadAndLevelsStayExact() {
        let store = VanStockStore(directory: directory, now: start)
        loadOne(into: store, at: start)
        store.update { $0.record(.used, itemID: "item-1", quantity: .whole(1), at: self.start.addingTimeInterval(60), batch: "b1", source: .spoken) }
        XCTAssertEqual(store.log.movements.count, 2)

        let later = start.addingTimeInterval(Double(VanStockStore.historyDays + 1) * 86_400)
        let reopened = VanStockStore(directory: directory, now: later)
        XCTAssertEqual(reopened.log.movements.map(\.kind), [.opening])
        XCTAssertEqual(reopened.log.level(of: "item-1").onHand, .whole(3))
        // And the fold was written, so the next launch does not redo it.
        XCTAssertEqual(VanStockStore(directory: directory, now: later).log, reopened.log)
    }

    // MARK: Plan MK P0 — place, book and verification on disk

    func testAStoreWrittenBeforePlacesStillReads() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let older = #"{"van":{"id":"v4","name":"Truck 4"},"version":1,"log":{"items":[{"id":"item-1","number":"00123","description":"Flame sensor","unit":"each","codes":[],"verified":true,"created_batch":"b0"},{"id":"item-2","description":"Fuse","unit":"each","codes":[],"verified":false,"created_batch":"b0"}],"movements":[]}}"#
        try Data(older.utf8).write(to: fileURL)

        let store = VanStockStore(directory: directory, now: start)
        XCTAssertFalse(store.isUnreadable)
        XCTAssertEqual(store.van, VanIdentity(id: "v4", name: "Truck 4"))
        XCTAssertNil(store.van?.place)
        XCTAssertNil(store.van?.checkVaultID)
        XCTAssertEqual(store.log.item(id: "item-1")?.verification, .found(in: nil))
        XCTAssertEqual(store.log.item(id: "item-2")?.verification, .notChecked)
    }

    func testThePlaceAndTheBookSurviveARelaunch() {
        let store = VanStockStore(directory: directory, now: start)
        store.setPlace(.store, makeID: { "s1" })
        store.checkNumbers(against: "vault-9")
        store.update { $0.addItem(id: "item-1", number: "00123", description: "Soda water",
                                  verification: .notFound(in: "Supplier catalogue"), batch: "b0") }
        let reopened = VanStockStore(directory: directory, now: start)
        XCTAssertEqual(reopened.van, VanIdentity(id: "s1", name: "", place: .store, checkVaultID: "vault-9"))
        XCTAssertEqual(reopened.log.item(id: "item-1")?.verification, .notFound(in: "Supplier catalogue"))
    }

    func testAnUnreadableStoreTakesNoPlace() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: fileURL)
        let store = VanStockStore(directory: directory, now: start)
        store.setPlace(.store)
        store.checkNumbers(against: "vault-9")
        XCTAssertNil(store.van)
        XCTAssertEqual(try Data(contentsOf: fileURL), Data("{".utf8))
    }
}
