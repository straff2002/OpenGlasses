import XCTest
@testable import OpenGlasses

/// Plan MM P3 — the parts noted for a business's own system, per job and per premises day, kept on
/// the phone until a person confirms them (P4).
@MainActor
final class StagedStockUseStoreTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("staged-stock-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func entry(_ id: String, scope: StagedStockUseEntry.Scope, call: String, quantity: Int = 1,
                       reason: StockAdjustmentReason? = nil) -> StagedStockUseEntry {
        StagedStockUseEntry(
            scope: scope, jobReference: "1027", connectorID: "sample-system", locationID: "L1",
            use: StagedStockUse(id: id, itemID: "ITEM-\(id)", part: "ZX-\(id)", description: "Capacitor",
                                quantity: .whole(quantity), unit: .each, verification: .found(in: "Catalogue"),
                                source: .spoken),
            reason: reason, stagedAt: StockSystemSamples.pulledAt, call: call)
    }

    func testLinesAreReadPerJobAndPerDayAndSurviveARelaunch() {
        let store = StagedStockUseStore(directory: directory)
        XCTAssertTrue(store.stage([entry("A", scope: .job("S1"), call: "C1"), entry("B", scope: .job("S1"), call: "C1")]))
        XCTAssertTrue(store.stage([entry("C", scope: .job("S2"), call: "C2")]))
        XCTAssertTrue(store.stage([entry("D", scope: .day("2026-11-20"), call: "C3", reason: .waste)]))

        let reread = StagedStockUseStore(directory: directory)
        XCTAssertEqual(reread.entries, store.entries)
        XCTAssertEqual(reread.entries(forJob: "S1").map(\.id), ["A", "B"])
        XCTAssertEqual(reread.entries(forJob: "S2").map(\.id), ["C"])
        XCTAssertEqual(reread.entries(forDay: "2026-11-20").map(\.id), ["D"])
        XCTAssertEqual(reread.entries(forDay: "2026-11-20").first?.reason, .waste)
        XCTAssertEqual(reread.entries(forJob: "S1").first?.use.verification, .found(in: "Catalogue"))
        XCTAssertFalse(store.stage([entry("A", scope: .job("S1"), call: "C9")]) && store.entries.count != 4,
                       "a line already noted is not noted twice")
        XCTAssertEqual(store.entries.count, 4)
    }

    func testUndoTakesBackTheLastCallInItsScopeOnly() {
        let store = StagedStockUseStore(directory: directory)
        store.stage([entry("A", scope: .job("S1"), call: "C1")])
        store.stage([entry("B", scope: .job("S1"), call: "C2"), entry("C", scope: .job("S1"), call: "C2")])
        store.stage([entry("D", scope: .job("S2"), call: "C3")])
        XCTAssertEqual(store.undoLastCall(in: .job("S1"))?.map(\.id), ["B", "C"])
        XCTAssertEqual(store.entries.map(\.id), ["A", "D"])
        XCTAssertEqual(store.undoLastCall(in: .job("S1"))?.map(\.id), ["A"])
        XCTAssertNil(store.undoLastCall(in: .job("S1")))
        XCTAssertEqual(StagedStockUseStore(directory: directory).entries.map(\.id), ["D"])
        XCTAssertTrue(store.remove(ids: ["D"]))
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testAFileThatCannotBeReadIsNeverOverwritten() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(StagedStockUseStore.fileName)
        try Data("{\"version\": 9, \"entries\": []}".utf8).write(to: url)
        let store = StagedStockUseStore(directory: directory)
        XCTAssertTrue(store.isUnreadable)
        XCTAssertFalse(store.stage([entry("A", scope: .job("S1"), call: "C1")]))
        XCTAssertEqual(try Data(contentsOf: url), Data("{\"version\": 9, \"entries\": []}".utf8))
        store.removeAll()
        XCTAssertFalse(store.isUnreadable)
        XCTAssertTrue(store.stage([entry("A", scope: .job("S1"), call: "C1")]))
    }

    func testTheFileIsProtectedAndKeptOutOfBackup() throws {
        let store = StagedStockUseStore(directory: directory)
        store.stage([entry("A", scope: .job("S1"), call: "C1")])
        let values = try store.fileURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
        XCTAssertEqual(SensitiveStore.stagedStockUse.record.backupExcluded, true)
        XCTAssertEqual(SensitiveStore.stagedStockUse.record.protection, .completeUntilFirstUserAuthentication)
        XCTAssertEqual(StagedStockUseStore.fileProtection, .completeUntilFirstUserAuthentication)
    }

    func testTheScopeAndTheDayAreStableWords() throws {
        XCTAssertEqual(StagedStockUseEntry.Scope.job("S1").key, "job:S1")
        XCTAssertEqual(StagedStockUseEntry.Scope(key: "day:2026-11-20"), .day("2026-11-20"))
        XCTAssertNil(StagedStockUseEntry.Scope(key: "week:47"))
        XCTAssertNil(StagedStockUseEntry.Scope(key: "job:"))
        XCTAssertEqual(StagedStockUseStore.dayKey(StockSystemSamples.pulledAt, calendar: StockSystemSamples.calendar),
                       "2026-11-20")
        var auckland = Calendar(identifier: .gregorian)
        auckland.timeZone = TimeZone(identifier: "Pacific/Auckland")!
        XCTAssertEqual(StagedStockUseStore.dayKey(StockSystemSamples.date(2026, 11, 20, 13, 0), calendar: auckland),
                       "2026-11-21", "the phone's own day")
    }

    func testRetiringTheSnapshotsKeepsTheNotedLines() throws {
        let snapshots = StockSystemSnapshotStore(directory: directory, connectorIDs: ["square"])
        let staged = StagedStockUseStore(directory: snapshots.folder.deletingLastPathComponent())
        staged.stage([entry("A", scope: .job("S1"), call: "C1")])
        XCTAssertTrue(snapshots.replace(StockSystemConnectionSamples.snapshot()))
        snapshots.retireAll()
        XCTAssertEqual(StagedStockUseStore(directory: directory).entries.map(\.id), ["A"])
    }
}

/// Plan MM P3 — the Stock screen's figures while a system holds the count: read-only, unknowns
/// shown as unknown with the reason, the age said plainly, and the uses noted for the job or day.
final class StockSystemScreenModelTests: XCTestCase {

    private typealias C = StockSystemConnectionSamples
    private let locale = Locale(identifier: "en_US")

    private func model(_ snapshot: StockSystemSnapshot?, now: Date = StockSystemSamples.pulledAt,
                       noted: [StagedStockUseEntry] = [], scope: StagedStockUseEntry.Scope? = nil,
                       reference: String? = nil, query: String = "") async -> StockSystemScreenModel {
        await MainActor.run {
            StockSystemScreenModel(snapshot: snapshot, system: "Fallback name", here: [C.main.id], noted: noted,
                                   scope: scope, jobReference: reference, now: now, query: query, locale: locale)
        }
    }

    func testFiguresAreTheSystemsAndAnUnknownIsNeverZero() async {
        let snapshot = await MainActor.run { StockSystemVanStockHarness.snapshot() }
        let model = await model(snapshot)
        XCTAssertEqual(model.system, "Square")
        XCTAssertEqual(model.asOf, StockSystemSamples.pulledAt)
        XCTAssertNil(model.staleLine)
        let byID = Dictionary(uniqueKeysWithValues: model.rows.map { ($0.id, $0) })
        XCTAssertEqual(byID["ITEM-CAP"]?.figure, "3")
        XCTAssertEqual(byID["ITEM-CAP"]?.detail, "ZX-455")
        XCTAssertEqual(byID["ITEM-CAP"]?.isLow, false, "above its reorder point")
        XCTAssertEqual(byID["ITEM-COOL"]?.figure, "12.5 l")
        XCTAssertEqual(byID["ITEM-FUSE"]?.figure, "0")
        XCTAssertEqual(byID["ITEM-FUSE"]?.isLow, true, "at none, with no reorder point")
        XCTAssertNil(byID["ITEM-WELD"]?.figure)
        XCTAssertEqual(byID["ITEM-WELD"]?.unknownReason, "Held to more decimal places than the phone keeps")
        XCTAssertEqual(byID["ITEM-GREASE"]?.unknownReason, "Counted in “tin”, a unit the phone doesn't keep")
        XCTAssertEqual(byID["ITEM-GREASE"]?.isLow, false)
        for row in model.rows where row.figure == nil {
            XCTAssertNotNil(row.unknownReason, "\(row.name) says why it has no figure")
        }
        XCTAssertEqual(model.rows.map(\.name), model.rows.map(\.name).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
    }

    func testAStaleSnapshotSaysSoPlainlyAndNoFiguresSaysThat() async {
        let snapshot = await MainActor.run { StockSystemVanStockHarness.snapshot() }
        let stale = await model(snapshot, now: StockSystemSamples.pulledAt.addingTimeInterval(25 * 3600))
        XCTAssertNotNil(stale.staleLine)
        let none = await model(nil)
        XCTAssertFalse(none.hasFigures)
        XCTAssertEqual(none.system, "Fallback name")
        XCTAssertTrue(none.rows.isEmpty)
    }

    func testTheNotedUsesForTheJobOrTheDay() async {
        let snapshot = await MainActor.run { StockSystemVanStockHarness.snapshot() }
        func entry(_ id: String, _ scope: StagedStockUseEntry.Scope, reason: StockAdjustmentReason? = nil) -> StagedStockUseEntry {
            StagedStockUseEntry(scope: scope, jobReference: nil, connectorID: "square", locationID: C.main.id,
                                use: StagedStockUse(id: id, itemID: "ITEM-COOL", part: "CL-50", description: "Coolant",
                                                    quantity: StockQuantity(scaled: 500), unit: .l, source: .spoken),
                                reason: reason, stagedAt: StockSystemSamples.pulledAt, call: id)
        }
        let noted = [entry("A", .job("S1")), entry("B", .job("S2"), reason: .waste), entry("C", .day("2026-11-20"))]
        let job = await model(snapshot, noted: noted, scope: .job("S1"), reference: "1027")
        XCTAssertEqual(job.notedTitle, "Noted on job 1027")
        XCTAssertEqual(job.noted.map(\.id), ["A"])
        XCTAssertEqual(job.noted.first?.amount, "0.5 l")
        XCTAssertEqual(job.noted.first?.name, "Coolant (CL-50)")
        let other = await model(snapshot, noted: noted, scope: .job("S2"))
        XCTAssertEqual(other.notedTitle, "Noted on this job")
        XCTAssertEqual(other.noted.first?.writtenOff, true)
        let day = await model(snapshot, noted: noted, scope: .day("2026-11-20"))
        XCTAssertEqual(day.notedTitle, "Noted today")
        XCTAssertEqual(day.noted.map(\.id), ["C"])
        let vehicle = await model(snapshot, noted: noted, scope: nil)
        XCTAssertNil(vehicle.notedTitle)
        XCTAssertTrue(vehicle.noted.isEmpty)
    }

    func testSearchNarrowsTheSystemsLines() async {
        let snapshot = await MainActor.run { StockSystemVanStockHarness.snapshot() }
        let found = await model(snapshot, query: "zx-455")
        XCTAssertEqual(found.rows.map(\.id), ["ITEM-CAP"])
        let words = await model(snapshot, query: "welding wire")
        XCTAssertEqual(words.rows.map(\.id), ["ITEM-WELD"])
    }
}
