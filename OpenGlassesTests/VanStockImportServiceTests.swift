import XCTest
@testable import OpenGlasses

/// Plan IH P3 — a workbook is read into a review; nothing is written until it is applied.
@MainActor
final class VanStockImportServiceTests: XCTestCase {

    private var directory: URL!
    private var store: VanStockStore!
    private var clock = Date(timeIntervalSince1970: 1_790_000_000)
    private var refusal: VanStockImportService.Refusal?

    private lazy var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private lazy var stock = VanStockService(
        store: store,
        verify: { TaskPart(number: VaultPartsIndex.normalise($0), verified: false) },
        partsIndex: { VaultPartsIndex(files: []) },
        activeJob: { nil },
        now: { [unowned self] in self.clock },
        calendar: calendar)

    private lazy var imports = VanStockImportService(store: store, service: stock,
                                                     isAllowed: { [unowned self] in self.refusal })

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("van-stock-import-tests-\(UUID().uuidString)", isDirectory: true)
        store = VanStockStore(directory: directory, now: clock)
        refusal = nil
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func workbook(_ rows: [[String]]) -> Data {
        let cells = rows.map { $0.map { XLSX.Cell.text($0) } }
        return XLSXWriter.data(for: XLSX.Workbook(sheets: [XLSX.Sheet(name: "Stock", columns: [], rows: cells)]),
                               modified: clock)
    }

    func testAShopsListLoadsAnEmptyVanInOneBatchAndOneUndoTakesItBack() {
        imports.handle(data: workbook([["Part number", "Description", "Qty", "Min"],
                                       ["00123", "Flame sensor", "4", "2"],
                                       ["", "Wire nuts", "50", ""]]), fileName: "shop.xlsx")
        guard case .reviewing(let proposal, let fileName) = imports.stage else { return XCTFail("\(imports.stage)") }
        XCTAssertEqual(fileName, "shop.xlsx")
        XCTAssertEqual(proposal.newLines.count, 2)
        XCTAssertTrue(store.log.isEmpty, "reading the file changed nothing")

        XCTAssertTrue(imports.apply())
        XCTAssertEqual(imports.stage, .idle)
        XCTAssertEqual(store.log.items.map(\.number), ["00123", nil])
        XCTAssertEqual(store.log.items.map { store.log.level(of: $0.id).onHand }, [.whole(4), .whole(50)])
        XCTAssertEqual(store.log.items.first?.minimum, .whole(2))
        XCTAssertEqual(Set(store.log.movements.map(\.batch)).count, 1)

        clock.addTimeInterval(60)
        _ = stock.undo(source: .typed)
        XCTAssertTrue(store.log.isEmpty, "one undo takes the whole import back")
    }

    func testAnExportComesStraightBackAsNothingToChange() throws {
        _ = stock.load([.init(description: "Igniter", quantity: .whole(3))])
        clock.addTimeInterval(60)
        let url = try XCTUnwrap(stock.exportFile())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertEqual(url.lastPathComponent, "Van stock 2026-09-21.xlsx")
        XCTAssertEqual(url.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path,
                       FileManager.default.temporaryDirectory.standardizedFileURL.path,
                       "an export is a temporary file, not something kept in the app's container")

        imports.open(url)
        XCTAssertEqual(imports.stage, .refused(.nothingToChange), "the figures match, so there is nothing to review")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Inbox").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "a file that is not an Inbox copy is left alone")
    }

    func testRefusalsAreSaidAndChangeNothing() {
        imports.handle(data: Data("part,qty".utf8), fileName: "stock.csv")
        XCTAssertEqual(imports.stage, .refused(.workbook(.notAWorkbook)))
        imports.handle(data: workbook([["Remember the ladder"]]), fileName: "notes.xlsx")
        XCTAssertEqual(imports.stage, .refused(.noRecognisableHeader))

        refusal = .switchedOffByOrganisation
        imports.handle(data: workbook([["Description", "Qty"], ["Fuse", "2"]]), fileName: "stock.xlsx")
        XCTAssertEqual(imports.stage, .refused(.switchedOffByOrganisation))
        XCTAssertFalse(imports.apply(), "there is nothing under review to apply")
        XCTAssertTrue(store.log.isEmpty)

        imports.dismiss()
        XCTAssertEqual(imports.stage, .idle)
    }

    func testAnUnreadableListRefusesTheImport() throws {
        try Data("not json".utf8).write(to: directory.appendingPathComponent("van-stock.json"))
        store = VanStockStore(directory: directory, now: clock)
        imports.handle(data: workbook([["Description", "Qty"], ["Fuse", "2"]]), fileName: "stock.xlsx")
        XCTAssertEqual(imports.stage, .refused(.listUnreadable))
    }

    func testCancellingAReviewChangesNothing() {
        imports.handle(data: workbook([["Description", "Qty"], ["Fuse", "2"]]), fileName: "stock.xlsx")
        imports.dismiss()
        XCTAssertEqual(imports.stage, .idle)
        XCTAssertTrue(store.log.isEmpty)
    }
}
