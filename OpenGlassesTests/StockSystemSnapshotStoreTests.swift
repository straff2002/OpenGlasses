import XCTest
@testable import OpenGlasses

/// Plan MM P2 — the last good snapshot per connector: replaced atomically with the one before kept,
/// read back after a relaunch, excluded from backup, retired whole.
@MainActor
final class StockSystemSnapshotStoreTests: XCTestCase {

    private typealias C = StockSystemConnectionSamples
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("StockSystemSnapshotStoreTests-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func store() -> StockSystemSnapshotStore {
        StockSystemSnapshotStore(directory: directory, connectorIDs: ["square"])
    }

    private func stored(_ url: URL) -> StockSystemSnapshot? {
        (try? Data(contentsOf: url)).flatMap(StockSystemSnapshotStore.decode)
    }

    func testAReplaceKeepsTheOneBeforeIt() throws {
        let store = store()
        let first = C.snapshot(asOf: StockSystemSamples.date(2026, 11, 20, 9, 0), part: "ZX-1")
        let second = C.snapshot(asOf: StockSystemSamples.date(2026, 11, 20, 9, 30), part: "ZX-2")
        XCTAssertTrue(store.replace(first))
        XCTAssertNil(stored(store.previousURL("square")), "nothing before the first")
        XCTAssertTrue(store.replace(second))
        XCTAssertEqual(store.snapshot(for: "square"), second)
        XCTAssertEqual(stored(store.currentURL("square")), second)
        XCTAssertEqual(stored(store.previousURL("square")), first)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: store.folder.path).filter { $0.contains("incoming") }
        XCTAssertEqual(leftovers, [], "the new file takes its place; nothing half-written stays")
    }

    func testARelaunchReadsTheLastGoodOneAndFallsBackToTheOneBefore() throws {
        let first = C.snapshot(asOf: StockSystemSamples.date(2026, 11, 20, 9, 0), part: "ZX-1")
        let second = C.snapshot(asOf: StockSystemSamples.date(2026, 11, 20, 9, 30), part: "ZX-2")
        let writer = store()
        writer.replace(first)
        writer.replace(second)
        XCTAssertEqual(store().snapshot(for: "square"), second)

        // A current file that cannot be read: the one before it answers, never nothing and never a guess.
        try Data("not a snapshot".utf8).write(to: writer.currentURL("square"))
        XCTAssertEqual(store().snapshot(for: "square"), first)
    }

    func testTheFolderAndItsFilesAreExcludedFromBackup() throws {
        let store = store()
        store.replace(C.snapshot(part: "ZX-1"))
        store.replace(C.snapshot(part: "ZX-2"))
        for url in [store.folder, store.currentURL("square"), store.previousURL("square")] {
            let excluded = try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
            XCTAssertEqual(excluded, true, url.lastPathComponent)
        }
        XCTAssertEqual(SensitiveStore.stockSystemSnapshot.record.backupExcluded, true)
        XCTAssertEqual(StockSystemSnapshotStore.fileProtection, .completeUntilFirstUserAuthentication)
        XCTAssertEqual(SensitiveStore.stockSystemSnapshot.record.protection, .completeUntilFirstUserAuthentication)
    }

    func testRetireRemovesTheCurrentAndThePrevious() throws {
        let store = store()
        store.replace(C.snapshot(part: "ZX-1"))
        store.replace(C.snapshot(part: "ZX-2"))
        store.retire("square")
        XCTAssertNil(store.snapshot(for: "square"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.currentURL("square").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.previousURL("square").path))
        XCTAssertNil(self.store().snapshot(for: "square"), "nothing comes back after a relaunch")

        store.replace(C.snapshot())
        store.retireAll()
        XCTAssertTrue(store.snapshots.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.folder.path))
    }

    func testAConnectorThatIsNotAPlainIdentifierIsNeverAFileName() {
        let builder = StockSystemSnapshotBuilder(source: StockSystemSource(connectorID: "../escape", displayName: "Bad"),
                                                 unitMap: StockSystemSamples.unitMap)
        let bad = builder.build(locations: StockSystemSamples.locations, rows: [], pulledAt: StockSystemSamples.pulledAt).snapshot
        XCTAssertFalse(store().replace(bad))
    }

    func testPricesAreDroppedWhenAStoredSnapshotIsRead() throws {
        var builder = StockSystemSnapshotBuilder(source: StockSystemSource(connectorID: "square", displayName: "Square"),
                                                 unitMap: StockSystemSamples.unitMap)
        builder.pricesEnabled = true
        let priced = builder.build(locations: StockSystemSamples.locations,
                                   rows: [StockSystemSamples.row("ITEM-1", [("L1", "2")], price: "12.50", currency: "NZD")],
                                   pulledAt: StockSystemSamples.pulledAt).snapshot
        XCTAssertNotNil(priced.lines.first?.price)
        let store = store()
        XCTAssertTrue(store.replace(priced))
        XCTAssertNil(self.store().snapshot(for: "square")?.lines.first?.price)
    }
}
