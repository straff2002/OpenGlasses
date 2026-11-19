import XCTest
@testable import OpenGlasses

/// Plan IH P3 — the van's stock out to a workbook, and an edited workbook back as a proposal.
final class VanStockSheetTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_790_000_000)
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func time(_ minutes: Int) -> Date { start.addingTimeInterval(Double(minutes) * 60) }

    private var log: VanStockLog {
        var log = VanStockLog()
        log.addItem(id: "sensor", number: "00123", description: "Flame sensor", minimum: .whole(2), standard: .whole(6),
                    standardSetBy: .base, bin: "left shelf 2", verified: true, batch: "b0")
        log.addItem(id: "igniter", number: "14E65", description: "Igniter", batch: "b0")
        log.addItem(id: "cable", description: "Thermostat cable", unit: .m, standard: .whole(30), standardSetBy: .van, batch: "b0")
        log.addItem(id: "fuse", description: "Fuse", batch: "b0")
        log.record(.counted, itemID: "sensor", quantity: .whole(4), at: time(0), batch: "b0", source: .typed)
        log.record(.loaded, itemID: "igniter", quantity: .whole(1), at: time(0), batch: "b0", source: .spoken)
        log.record(.used, itemID: "igniter", quantity: .whole(2), at: time(1), batch: "b1", source: .spoken, jobReference: "job-2031")
        log.record(.ordered, itemID: "igniter", quantity: .whole(1), at: time(2), batch: "b2", source: .spoken, requestID: "r1")
        log.record(.loaded, itemID: "cable", quantity: .whole(40), at: time(3), batch: "b3", source: .spoken)
        return log
    }

    private func verify(_ number: String) -> TaskPart { TaskPart(number: number, verified: number == "22B22") }

    /// The exported stock sheet, as rows of text, ready to be edited.
    private func exported(_ log: VanStockLog, at date: Date) throws -> [XLSXReader.Sheet] {
        try XLSXReader.read(VanStockSheet.data(log, exportedAt: date, calendar: calendar)).get()
    }

    private func column(_ column: VanStockSheet.Column) -> Int { VanStockSheet.Column.allCases.firstIndex(of: column)! }

    /// Replace one cell of the stock sheet, by the line's description.
    private func editing(_ sheets: [XLSXReader.Sheet], line: String, _ target: VanStockSheet.Column,
                         to value: String) -> [XLSXReader.Sheet] {
        sheets.map { sheet in
            guard sheet.name == VanStockSheet.stockSheetName else { return sheet }
            let rows = sheet.rows.map { row -> [String] in
                guard row.count > column(.description), row[column(.description)] == line else { return row }
                var padded = row + Array(repeating: "", count: max(0, VanStockSheet.Column.allCases.count - row.count))
                padded[column(target)] = value
                return padded
            }
            return XLSXReader.Sheet(name: sheet.name, isHidden: sheet.isHidden, rows: rows)
        }
    }

    // MARK: Out

    func testTheStockSheetSaysWhatTheLogSays() throws {
        let sheets = try exported(log, at: time(10))
        XCTAssertEqual(sheets.map(\.name), ["Van stock", "History", "Avenkin"])
        XCTAssertEqual(sheets.map(\.isHidden), [false, false, true])
        let stock = sheets[0].rows
        XCTAssertEqual(stock[0], VanStockSheet.Column.allCases.map(\.rawValue))
        // Flame sensor, Fuse, Igniter, Thermostat cable — by name.
        XCTAssertEqual(stock[1], ["00123", "Flame sensor", "each", "4", "6", "Base", "2", "2", "", "", "left shelf 2",
                                  "2026-09-21 14:13", "sensor"])
        XCTAssertEqual(stock[2], ["", "Fuse", "each", "", "", "", "", "", "", "", "", "", "fuse"],
                       "a line nothing was recorded against has no figure, not a zero")
        XCTAssertEqual(stock[3][column(.partNumber)], "14E65", "not 1.4E+66")
        XCTAssertEqual(stock[3][column(.onHand)], "0")
        XCTAssertEqual(stock[3][column(.onOrder)], "1")
        XCTAssertEqual(stock[3][column(.needsCount)], "Yes")
        XCTAssertEqual(stock[4][column(.unit)], "m")
        XCTAssertEqual(stock[4][column(.standardSetBy)], "This truck")
        XCTAssertEqual(stock[4][column(.toTopUp)], "0", "above its standard load is not short")
    }

    func testTheHistoryIsNewestFirstAndTheFileIsNamedForTheDay() throws {
        let history = try exported(log, at: time(10))[1].rows
        XCTAssertEqual(history[0], ["When", "Line", "What", "Quantity", "Job", "How"])
        XCTAssertEqual(history[1][1...3].map { $0 }, ["Thermostat cable", "loaded", "40"])
        XCTAssertEqual(history[3], ["2026-09-21 14:14", "Igniter (14E65)", "used", "2", "job-2031", "spoken"])
        XCTAssertEqual(VanStockSheet.fileName(exportedAt: time(10), calendar: calendar), "Van stock 2026-09-21.xlsx")
    }

    // MARK: Back, unchanged

    func testAWorkbookNobodyEditedProposesNothing() throws {
        let proposal = try VanStockSheet.proposal(from: exported(log, at: time(10)), log: log).get()
        // The igniter line is unreliable, so its figure is offered as a count even unchanged.
        XCTAssertEqual(proposal.counts.map(\.itemID), ["igniter"])
        XCTAssertEqual(proposal.edits, [])
        XCTAssertEqual(proposal.newLines, [])
        XCTAssertEqual(proposal.missing, [])
        XCTAssertEqual(proposal.refusals, [])
    }

    // MARK: Back, edited

    func testAChangedFigureIsACountAndAChangedDetailIsAnEdit() throws {
        var sheets = try exported(log, at: time(10))
        sheets = editing(sheets, line: "Flame sensor", .onHand, to: "5")
        sheets = editing(sheets, line: "Flame sensor", .minimum, to: "")
        sheets = editing(sheets, line: "Flame sensor", .bin, to: "right shelf 1")
        sheets = editing(sheets, line: "Fuse", .onHand, to: "12.0")
        sheets = editing(sheets, line: "Fuse", .standard, to: "10")
        let proposal = try VanStockSheet.proposal(from: sheets, log: log).get()

        let counts = Dictionary(uniqueKeysWithValues: proposal.counts.map { ($0.itemID, $0) })
        XCTAssertEqual(counts["sensor"], .init(itemID: "sensor", name: "Flame sensor (00123)", from: .whole(4), to: .whole(5), movedSinceExport: false))
        XCTAssertEqual(counts["fuse"], .init(itemID: "fuse", name: "Fuse", from: nil, to: .whole(12), movedSinceExport: false))
        let edits = Dictionary(uniqueKeysWithValues: proposal.edits.map { ($0.itemID, $0.changes) })
        XCTAssertEqual(edits["sensor"], [.minimum(nil), .bin("right shelf 1")], "an emptied cell in our own sheet clears it")
        XCTAssertEqual(edits["fuse"], [.standard(.whole(10), setBy: .van)])

        var applied = log
        VanStockSheet.apply(proposal, to: &applied, at: time(20), batch: "import", verify: verify)
        XCTAssertEqual(applied.level(of: "sensor").onHand, .whole(5))
        XCTAssertEqual(applied.level(of: "sensor").provenance, .counted)
        XCTAssertEqual(applied.level(of: "fuse").onHand, .whole(12))
        XCTAssertNil(applied.item(id: "sensor")?.minimum)
        XCTAssertEqual(applied.item(id: "sensor")?.bin, "right shelf 1")
        XCTAssertEqual(applied.item(id: "fuse")?.standardSetBy, .van)
        XCTAssertEqual(Set(applied.movements.suffix(from: log.movements.count).map(\.batch)), ["import"])
        XCTAssertEqual(Set(applied.movements.suffix(from: log.movements.count).map(\.source)), [.sheet])

        // One undo takes the whole import back.
        applied.undoLastBatch(at: time(21), batch: "undo", source: .typed)
        XCTAssertEqual(applied.levels, log.levels)
        XCTAssertEqual(applied.items, log.items)
    }

    func testANewRowIsANewLineAndItsNumberIsLookedUp() throws {
        var sheets = try exported(log, at: time(10))
        sheets[0] = XLSXReader.Sheet(name: sheets[0].name, isHidden: false,
                                     rows: sheets[0].rows + [["22B22", "Hot surface igniter", "", "3", "4", "", "", "1", "", "", "tray"],
                                                             ["", "", "", "2"]])
        let proposal = try VanStockSheet.proposal(from: sheets, log: log).get()
        XCTAssertEqual(proposal.newLines, [.init(row: 6, number: "22B22", description: "Hot surface igniter", unit: .each,
                                                 onHand: .whole(3), minimum: .whole(1), standard: .whole(4), bin: "tray")])
        XCTAssertEqual(proposal.refusals, [.init(row: 7, reason: .noPartNumberOrDescription)])

        var applied = log
        VanStockSheet.apply(proposal, to: &applied, at: time(20), batch: "import", verify: verify)
        let added = try XCTUnwrap(applied.items.first { $0.number == "22B22" })
        XCTAssertTrue(added.verified)
        XCTAssertEqual(applied.level(of: added.id).onHand, .whole(3))
        XCTAssertEqual(added.standardSetBy, .van)
    }

    func testAMissingRowChangesNothingAndIsListed() throws {
        var sheets = try exported(log, at: time(10))
        sheets[0] = XLSXReader.Sheet(name: sheets[0].name, isHidden: false,
                                     rows: sheets[0].rows.filter { $0.count < 2 || $0[1] != "Flame sensor" })
        let proposal = try VanStockSheet.proposal(from: sheets, log: log).get()
        XCTAssertEqual(proposal.missing.map(\.id), ["sensor"])
        var applied = log
        VanStockSheet.apply(proposal, to: &applied, at: time(20), batch: "import", verify: verify)
        XCTAssertEqual(applied.level(of: "sensor").onHand, .whole(4), "a deleted row never zeroes a line")
        XCTAssertNotNil(applied.item(id: "sensor"))
    }

    func testALineThatMovedSinceTheExportOffersBothFigures() throws {
        var sheets = try exported(log, at: time(10))
        sheets = editing(sheets, line: "Flame sensor", .onHand, to: "6")
        var later = log
        later.record(.used, itemID: "sensor", quantity: .whole(1), at: time(15), batch: "b9", source: .spoken)
        let proposal = try VanStockSheet.proposal(from: sheets, log: later).get()
        let count = try XCTUnwrap(proposal.counts.first { $0.itemID == "sensor" })
        XCTAssertEqual(count.from, .whole(3))
        XCTAssertEqual(count.to, .whole(6))
        XCTAssertTrue(count.movedSinceExport)

        var sheetWins = later
        VanStockSheet.apply(proposal, to: &sheetWins, at: time(20), batch: "import", verify: verify)
        XCTAssertEqual(sheetWins.level(of: "sensor").onHand, .whole(6), "the sheet's figure is the default")

        var phoneWins = later
        VanStockSheet.apply(proposal, to: &phoneWins, keepingPhoneFigure: ["sensor"], at: time(20), batch: "import", verify: verify)
        XCTAssertEqual(phoneWins.level(of: "sensor").onHand, .whole(3))
    }

    func testBadFiguresAndUnitsAreRefusedLineByLine() throws {
        var sheets = try exported(log, at: time(10))
        sheets = editing(sheets, line: "Flame sensor", .onHand, to: "-1")
        sheets = editing(sheets, line: "Fuse", .onHand, to: "2.5")
        sheets = editing(sheets, line: "Thermostat cable", .unit, to: "reel")
        let proposal = try VanStockSheet.proposal(from: sheets, log: log).get()
        XCTAssertEqual(proposal.refusals.map(\.row), [2, 3, 5])
        XCTAssertEqual(proposal.refusals.map(\.reason), [.notAQuantity(column: "On hand", value: "-1", unit: .each),
                                                         .notAQuantity(column: "On hand", value: "2.5", unit: .each),
                                                         .unknownUnit("reel")])
        XCTAssertEqual(proposal.refusals.map(\.quantityRefusal), [.negative, .notWhole, nil])
        XCTAssertEqual(proposal.refusals.map(\.name), ["Flame sensor", "Fuse", "Thermostat cable"])
        XCTAssertEqual(proposal.counts.map(\.itemID), ["igniter"], "the refused lines change nothing")
    }

    func testARepeatedLineIsRefused() throws {
        var sheets = try exported(log, at: time(10))
        sheets[0] = XLSXReader.Sheet(name: sheets[0].name, isHidden: false, rows: sheets[0].rows + [sheets[0].rows[1]])
        let proposal = try VanStockSheet.proposal(from: sheets, log: log).get()
        XCTAssertEqual(proposal.refusals, [.init(row: 6, reason: .repeatsRow(2))])
    }

    // MARK: The file type

    func testTheWorkbookTypeIsDeclaredSoTheSystemOffersThisAppBesideASpreadsheetApp() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OpenGlasses/Info.plist")
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        let documents = try XCTUnwrap(plist["CFBundleDocumentTypes"] as? [[String: Any]])
        let workbook = try XCTUnwrap(documents.first {
            ($0["LSItemContentTypes"] as? [String])?.contains("org.openxmlformats.spreadsheetml.sheet") == true
        })
        XCTAssertEqual(workbook["LSHandlerRank"] as? String, "Alternate", "a spreadsheet app stays the default")
        XCTAssertEqual(plist["LSSupportsOpeningDocumentsInPlace"] as? Bool, false, "read as a copy, never edited in place")
        XCTAssertTrue(VanStockSheet.isWorkbook(URL(fileURLWithPath: "/tmp/Van stock 2026-10-14.XLSX")))
        XCTAssertFalse(VanStockSheet.isWorkbook(URL(fileURLWithPath: "/tmp/stock.xlsm")))
        XCTAssertFalse(VanStockSheet.isWorkbook(URL(string: "https://example.com/stock.xlsx")!))
    }

    // MARK: A sheet we did not write

    func testAForeignSheetIsMatchedByItsHeaders() throws {
        let foreign = [XLSXReader.Sheet(name: "Truck 4", isHidden: false, rows: [
            ["Shop stock list"],
            ["Item", "Desc.", "Qty", "Min"],
            ["00123", "Flame sensor", "9", ""],
            ["", "fuse", "20", "5"],
            ["77-100", "Contactor", "2", ""],
        ])]
        let proposal = try VanStockSheet.proposal(from: foreign, log: log).get()
        XCTAssertEqual(proposal.counts.map(\.itemID), ["sensor", "fuse"])
        XCTAssertEqual(proposal.counts.map(\.to), [.whole(9), .whole(20)])
        XCTAssertEqual(proposal.edits, [.init(itemID: "fuse", name: "Fuse", changes: [.description("fuse"), .minimum(.whole(5))])])
        XCTAssertEqual(proposal.edits.first { $0.itemID == "sensor" }, nil, "an empty cell in a foreign sheet clears nothing")
        XCTAssertEqual(proposal.newLines.map(\.number), ["77-100"])
        XCTAssertEqual(proposal.missing, [], "a foreign sheet is not expected to list every line")
    }

    func testWordsInAPartColumnAreADescription() throws {
        let foreign = [XLSXReader.Sheet(name: "Stock", isHidden: false, rows: [
            ["Part", "Quantity"], ["Wire nuts", "50"], ["0456", "3"],
        ])]
        let proposal = try VanStockSheet.proposal(from: foreign, log: VanStockLog()).get()
        XCTAssertEqual(proposal.newLines.map(\.description), ["Wire nuts", ""])
        XCTAssertEqual(proposal.newLines.map(\.number), [nil, "0456"])
    }

    func testASheetWithNoRecognisableHeaderIsRefused() {
        let foreign = [XLSXReader.Sheet(name: "Notes", isHidden: false, rows: [["Remember the ladder"], ["14T65", "2"]])]
        XCTAssertEqual(VanStockSheet.proposal(from: foreign, log: log), .failure(.noRecognisableHeader))
        XCTAssertEqual(VanStockSheet.proposal(from: Data("not a workbook".utf8), log: log), .failure(.workbook(.notAWorkbook)))
    }

    // MARK: The list's place (Plan MK P0)

    private func meta(_ sheets: [XLSXReader.Sheet]) -> [[String]] {
        sheets.first { $0.name == VanStockSheet.metaSheetName }?.rows ?? []
    }

    private func written(_ van: VanIdentity?) throws -> [XLSXReader.Sheet] {
        try XLSXReader.read(VanStockSheet.data(log, van: van, exportedAt: time(10), calendar: calendar)).get()
    }

    func testThePlaceRoundTripsThroughTheMetaSheet() throws {
        for kind in StockPlace.Kind.allCases {
            let sheets = try written(VanIdentity(id: "s1", name: "Main street", place: kind))
            XCTAssertTrue(meta(sheets).contains([VanStockSheet.placeKey, kind.rawValue]), "\(kind)")
            XCTAssertEqual(try VanStockSheet.rows(from: sheets).get().van,
                           VanIdentity(id: "s1", name: "Main street", place: kind))
        }
    }

    func testAListWithNoPlaceWritesNoPlaceRowAndReadsBackWithNone() throws {
        let sheets = try written(VanIdentity(id: "v4", name: "Truck 4"))
        XCTAssertFalse(meta(sheets).contains { $0.first == VanStockSheet.placeKey })
        XCTAssertEqual(try VanStockSheet.rows(from: sheets).get().van, VanIdentity(id: "v4", name: "Truck 4"))
    }

    func testAnOlderWorkbookWithoutAPlaceRowImportsAsToday() throws {
        // What a build before places wrote: format, exported_at, van_id and van_name, and no place.
        let older = try written(VanIdentity(id: "v4", name: "Truck 4", place: .store)).map { sheet -> XLSXReader.Sheet in
            guard sheet.name == VanStockSheet.metaSheetName else { return sheet }
            let rows = sheet.rows.filter { $0.first != VanStockSheet.placeKey }
            return XLSXReader.Sheet(name: sheet.name, isHidden: sheet.isHidden, rows: rows)
        }
        XCTAssertEqual(meta(older).map { $0.first ?? "" }, ["key", "format", "exported_at", "van_id", "van_name"])
        let read = try VanStockSheet.rows(from: older).get()
        XCTAssertNil(read.van?.place)
        XCTAssertEqual(read.van?.stockPlace.kind, .van)
        XCTAssertEqual(read.rows.count, 4)
        let proposal = try VanStockSheet.proposal(from: older, log: log).get()
        // As for any unedited workbook: only the unreliable igniter is offered, as a count.
        XCTAssertEqual(proposal.counts.map(\.itemID), ["igniter"])
        XCTAssertEqual(proposal.edits, [])
        XCTAssertEqual(proposal.newLines, [])
    }

    func testAPlaceFromANewerBuildReadsAsVan() throws {
        let newer = try written(VanIdentity(id: "s1", name: "Bar", place: .store)).map { sheet -> XLSXReader.Sheet in
            guard sheet.name == VanStockSheet.metaSheetName else { return sheet }
            let rows = sheet.rows.map { $0.first == VanStockSheet.placeKey ? [VanStockSheet.placeKey, "boat"] : $0 }
            return XLSXReader.Sheet(name: sheet.name, isHidden: sheet.isHidden, rows: rows)
        }
        XCTAssertEqual(try VanStockSheet.rows(from: newer).get().van?.place, .van)
    }

    func testTheVaultTheListChecksAgainstIsNeverWrittenIntoTheWorkbook() throws {
        let van = VanIdentity(id: "s1", name: "Main street", place: .store, checkVaultID: "vault-secret-9")
        let data = VanStockSheet.data(log, van: van, exportedAt: time(10), calendar: calendar)
        let sheets = try XLSXReader.read(data).get()
        for sheet in sheets {
            XCTAssertFalse(sheet.rows.joined().contains { $0.contains("vault-secret-9") }, sheet.name)
        }
        XCTAssertNil(try VanStockSheet.rows(from: sheets).get().van?.checkVaultID)
    }

    // MARK: The workbook follows the place (Plan MK P2)

    private func written(_ van: VanIdentity?, kind: StockPlace.Kind) throws -> [XLSXReader.Sheet] {
        try XLSXReader.read(VanStockSheet.data(log, van: van, exportedAt: time(10), calendar: calendar, kind: kind)).get()
    }

    func testTheSheetAndFileAreNamedForThePlace() throws {
        let expected: [StockPlace.Kind: String] = [
            .van: "Van stock", .truck: "Truck stock", .store: "Store stock", .warehouse: "Warehouse stock", .stock: "Stock",
        ]
        for (kind, title) in expected {
            XCTAssertEqual(VanStockSheet.stockSheetName(kind), title)
            XCTAssertLessThanOrEqual(VanStockSheet.stockSheetName(kind).count, VanStockSheet.sheetNameLimit)
            XCTAssertEqual(try written(nil, kind: kind).map(\.name), [title, "History", "Avenkin"], "\(kind)")
            XCTAssertEqual(VanStockSheet.fileName(exportedAt: time(10), calendar: calendar, kind: kind),
                           "\(title) 2026-09-21.xlsx")
        }
        XCTAssertEqual(VanStockSheet.stockSheetNames.count, 5)
    }

    func testTheStandardSetByColumnSpeaksForThePlace() throws {
        let expected: [StockPlace.Kind: (base: String, own: String)] = [
            .van: ("Base", "This truck"), .truck: ("Base", "This truck"), .store: ("Office", "This store"),
            .warehouse: ("Office", "This warehouse"), .stock: ("Office", "This list"),
        ]
        for (kind, words) in expected {
            let stock = try written(nil, kind: kind)[0].rows
            // Flame sensor's standard came from outside the list; the cable's the list set itself.
            XCTAssertEqual(stock[1][column(.standardSetBy)], words.base, "\(kind)")
            XCTAssertEqual(stock[4][column(.standardSetBy)], words.own, "\(kind)")
        }
    }

    func testOfficeAndBaseBothReadAsSetFromOutsideTheList() throws {
        for word in ["Base", "base", "Office", "OFFICE", " office "] {
            let sheets = editing(try exported(log, at: time(10)), line: "Flame sensor", .standardSetBy, to: word)
            let row = try VanStockSheet.rows(from: sheets).get().rows.first { $0.description == "Flame sensor" }
            XCTAssertEqual(row?.standardSetByBase, true, word)
        }
        for word in ["This store", "This truck", "This list", "This warehouse", ""] {
            let sheets = editing(try exported(log, at: time(10)), line: "Flame sensor", .standardSetBy, to: word)
            let row = try VanStockSheet.rows(from: sheets).get().rows.first { $0.description == "Flame sensor" }
            XCTAssertEqual(row?.standardSetByBase, false, word)
        }
    }

    func testAStoresExportImportedStraightBackChangesNothing() throws {
        let store = VanIdentity(id: "s1", name: "Main street", place: .store)
        let sheets = try written(store, kind: .store)
        XCTAssertEqual(sheets[0].name, "Store stock")
        let proposal = try VanStockSheet.proposal(from: sheets, log: log).get()
        // As for any unedited workbook: only the unreliable igniter is offered, as a count.
        XCTAssertEqual(proposal.counts.map(\.itemID), ["igniter"])
        XCTAssertEqual(proposal.edits, [])
        XCTAssertEqual(proposal.newLines, [])

        // Taken over on another phone, each standard keeps who set it.
        let takeover = try VanStockHandover.takeover(from: sheets, at: time(20), batch: "t").get()
        XCTAssertEqual(takeover.van?.place, .store)
        let byName = Dictionary(uniqueKeysWithValues: takeover.log.items.map { ($0.description, $0.standardSetBy) })
        XCTAssertEqual(byName["Flame sensor"], .base, "the office's figure stays the office's")
        XCTAssertEqual(byName["Thermostat cable"], .van, "the store's own figure stays its own")
    }

    func testAnOlderVanStockWorkbookAndAForeignOneStillImport() throws {
        // A store's phone reading a workbook an older build wrote, named "Van stock".
        let older = try exported(log, at: time(10))
        XCTAssertEqual(older[0].name, "Van stock")
        XCTAssertEqual(try VanStockSheet.rows(from: older).get().rows.count, 4)

        // A sheet somebody else wrote, under a name of their own, after a hidden sheet.
        let foreign = [
            XLSXReader.Sheet(name: VanStockSheet.metaSheetName, isHidden: true, rows: [["key", "value"]]),
            XLSXReader.Sheet(name: "Cellar", isHidden: false, rows: [["Description", "Qty"], ["Soda water", "6"]]),
        ]
        let read = try VanStockSheet.rows(from: foreign).get()
        XCTAssertEqual(read.rows.map(\.description), ["Soda water"])
    }

    // MARK: Measured quantities (Plan ML P2)

    /// Engine oil at 4.25 litres against a standard of 5 with a minimum of 2.5, and wire nuts in packs.
    private var measured: VanStockLog {
        var log = VanStockLog()
        log.addItem(id: "oil", number: "OIL-5W30", description: "Engine oil", unit: .l, minimum: StockQuantity(scaled: 2500),
                    standard: .whole(5), standardSetBy: .van, batch: "b0")
        log.addItem(id: "nuts", description: "Wire nuts", unit: .pack, batch: "b0")
        log.record(.counted, itemID: "oil", quantity: StockQuantity(scaled: 4250), at: time(0), batch: "b0", source: .typed)
        log.record(.ordered, itemID: "oil", quantity: StockQuantity(scaled: 500), at: time(1), batch: "b1", source: .spoken)
        log.record(.counted, itemID: "nuts", quantity: .whole(4), at: time(0), batch: "b0", source: .typed)
        return log
    }

    func testAnExportWritesDecimalNumberCells() throws {
        let data = VanStockSheet.data(measured, exportedAt: time(10), calendar: calendar)
        // The parts are stored, not compressed, so the sheet's XML is in the bytes as written.
        let xml = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(xml.contains("<v>4.25</v>"), "on hand")
        XCTAssertTrue(xml.contains("<v>0.75</v>"), "to top up")
        XCTAssertTrue(xml.contains("<v>2.5</v>"), "minimum")
        XCTAssertTrue(xml.contains("<v>0.5</v>"), "on order")
        XCTAssertTrue(xml.contains("<v>4</v>"), "a whole figure is written as it always was")
        XCTAssertFalse(xml.contains("<v>4250</v>"), "never thousandths")
        XCTAssertFalse(xml.contains(">4.25</t>"), "never as text")

        let oil = try exported(measured, at: time(10))[0].rows.first { $0.count > 1 && $0[1] == "Engine oil" }
        XCTAssertEqual(oil?[column(.onHand)], "4.25")
        XCTAssertEqual(oil?[column(.toTopUp)], "0.75")
    }

    func testAnExportImportedStraightBackChangesNothing() throws {
        let log = measured
        let sheets = try exported(log, at: time(10))
        let proposal = try VanStockSheet.proposal(from: sheets, log: log).get()
        XCTAssertEqual(proposal.counts, [])
        XCTAssertEqual(proposal.edits, [])
        XCTAssertEqual(proposal.newLines, [])
        XCTAssertEqual(proposal.refusals, [])
        var applied = log
        VanStockSheet.apply(proposal, to: &applied, at: time(20), batch: "import", verify: verify)
        XCTAssertEqual(applied, log)
    }

    func testDecimalsAreReadInTheRowsUnit() throws {
        var sheets = try exported(measured, at: time(10))
        sheets = editing(sheets, line: "Engine oil", .onHand, to: "3.125")
        sheets = editing(sheets, line: "Wire nuts", .onHand, to: "2.5")
        let proposal = try VanStockSheet.proposal(from: sheets, log: measured).get()
        XCTAssertEqual(proposal.counts.map(\.to), [StockQuantity(scaled: 3125)])
        XCTAssertEqual(proposal.refusals.map(\.reason), [.notAQuantity(column: "On hand", value: "2.5", unit: .pack)])
        XCTAssertEqual(proposal.refusals.first?.name, "Wire nuts")
        XCTAssertEqual(proposal.refusals.first?.quantityRefusal, .notWhole)
    }

    func testMoreThanThreeDecimalPlacesRefusesTheLine() throws {
        let sheets = editing(try exported(measured, at: time(10)), line: "Engine oil", .onHand, to: "4.2513")
        let proposal = try VanStockSheet.proposal(from: sheets, log: measured).get()
        XCTAssertEqual(proposal.refusals.map(\.reason), [.notAQuantity(column: "On hand", value: "4.2513", unit: .l)])
        XCTAssertEqual(proposal.refusals.first?.quantityRefusal, .tooManyDecimals)
        XCTAssertEqual(proposal.counts, [])
    }

    func testHowASpreadsheetStoresANumberIsRead() {
        XCTAssertEqual(VanStockSheet.quantity("4.2499999999999991", unit: .l), .value(StockQuantity(scaled: 4250)),
                       "a formula's binary noise is the nearest thousandth")
        XCTAssertEqual(VanStockSheet.quantity("4.25E-1", unit: .l), .value(StockQuantity(scaled: 425)))
        XCTAssertEqual(VanStockSheet.quantity("2.0000000000000004", unit: .each), .value(.whole(2)))
        XCTAssertEqual(VanStockSheet.quantity("4", unit: .l), .value(.whole(4)), "an older workbook's 4 is 4 units")
        XCTAssertEqual(VanStockSheet.quantity("4.250", unit: .l), .value(StockQuantity(scaled: 4250)))
        XCTAssertEqual(VanStockSheet.quantity("12.0", unit: .each), .value(.whole(12)))
        XCTAssertEqual(VanStockSheet.quantity("", unit: .l), .absent)
        XCTAssertEqual(VanStockSheet.quantity("4.2513", unit: .l), .refused(.tooManyDecimals))
        XCTAssertEqual(VanStockSheet.quantity("2.5", unit: .pack), .refused(.notWhole))
        XCTAssertEqual(VanStockSheet.quantity("-1", unit: .l), .refused(.negative))
        XCTAssertEqual(VanStockSheet.quantity("1e7", unit: .l), .refused(.tooLarge))
        XCTAssertEqual(VanStockSheet.quantity("four", unit: .l), .refused(.notANumber))
        XCTAssertEqual(VanStockSheet.quantity("0x10", unit: .each), .refused(.notANumber), "not a spreadsheet's spelling")
        XCTAssertEqual(VanStockSheet.quantity("nan", unit: .l), .refused(.notANumber))
        XCTAssertEqual(VanStockSheet.quantity("4,25", unit: .l), .refused(.notANumber), "storage always uses a point")
    }

    func testARowsUnitIsReadBeforeItsFiguresEvenWhenThePhoneCountsItWhole() throws {
        // On the phone the oil is counted in each; the sheet moves it to litres with a decimal count.
        var phone = VanStockLog()
        phone.addItem(id: "oil", description: "Engine oil", batch: "b0")
        phone.record(.counted, itemID: "oil", quantity: .whole(4), at: time(0), batch: "b0", source: .typed)
        var sheets = try exported(phone, at: time(10))
        sheets = editing(sheets, line: "Engine oil", .unit, to: "l")
        sheets = editing(sheets, line: "Engine oil", .onHand, to: "4.25")
        let proposal = try VanStockSheet.proposal(from: sheets, log: phone).get()
        XCTAssertEqual(proposal.refusals, [])
        XCTAssertEqual(proposal.edits.first?.changes, [.unit(.l)])
        XCTAssertEqual(proposal.counts.map(\.to), [StockQuantity(scaled: 4250)])
        VanStockSheet.apply(proposal, to: &phone, at: time(20), batch: "import", verify: verify)
        XCTAssertEqual(phone.item(id: "oil")?.unit, .l)
        XCTAssertEqual(phone.level(of: "oil").onHand, StockQuantity(scaled: 4250))
    }

    func testARowMovingALineToEachWithWholeFiguresIsApplied() throws {
        // The phone holds 4.25 l with a minimum of 2.5; the row says each, 4 on hand, a minimum of 2
        // and a standard of 5. Applied in the row's own order, the unit change finds whole figures.
        var sheets = try exported(measured, at: time(10))
        sheets = editing(sheets, line: "Engine oil", .unit, to: "each")
        sheets = editing(sheets, line: "Engine oil", .onHand, to: "4")
        sheets = editing(sheets, line: "Engine oil", .minimum, to: "2")
        let proposal = try VanStockSheet.proposal(from: sheets, log: measured).get()
        XCTAssertEqual(proposal.refusals, [])
        var applied = measured
        VanStockSheet.apply(proposal, to: &applied, at: time(20), batch: "import", verify: verify)
        XCTAssertEqual(applied.item(id: "oil")?.unit, .each)
        XCTAssertEqual(applied.level(of: "oil").onHand, .whole(4))
        XCTAssertEqual(applied.item(id: "oil")?.minimum, .whole(2))
        XCTAssertEqual(applied.item(id: "oil")?.standard, .whole(5))

        // One undo takes it all back, the unit included.
        applied.undoLastBatch(at: time(21), batch: "undo", source: .typed)
        XCTAssertEqual(applied.items, measured.items)
        XCTAssertEqual(applied.levels, measured.levels)
    }

    func testARowWithNoUnitHoldsItsFiguresToTheLinesOwnUnit() throws {
        let foreign = [XLSXReader.Sheet(name: "Stock", isHidden: false, rows: [
            ["Description", "Qty"], ["Engine oil", "3.75"], ["Wire nuts", "2.5"], ["Grease", "0.5"],
        ])]
        let proposal = try VanStockSheet.proposal(from: foreign, log: measured).get()
        XCTAssertEqual(proposal.counts.map(\.to), [StockQuantity(scaled: 3750)])
        XCTAssertEqual(proposal.refusals.map(\.reason), [
            .notAQuantity(column: "On hand", value: "2.5", unit: .pack),
            .notAQuantity(column: "On hand", value: "0.5", unit: .each),
        ], "a new line with no unit is counted in each")
        XCTAssertEqual(proposal.newLines, [])

        let takeover = try VanStockHandover.takeover(from: foreign, at: time(20), batch: "t").get()
        XCTAssertEqual(takeover.log.items.map(\.description), [], "every row is each with no unit, and 3.75 each is not one")
        XCTAssertEqual(takeover.refusals.count, 3)
    }
}
