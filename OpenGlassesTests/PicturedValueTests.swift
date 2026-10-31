import CoreGraphics
import XCTest
@testable import OpenGlasses

/// Plan JN P2 — a value read from a picture says so, every time, and an uncertain one is never
/// given: `table_lookup`'s wording, the loose-match rule, a chain's read-back and the reading it
/// files, the region "show me the table" outlines, and the tool's description. Every table,
/// designation and value is invented (`RecognisedTableFixtures`, `RuleChainFixtures`).
@MainActor
final class PicturedValueTests: XCTestCase {

    private typealias F = RecognisedTableFixtures
    private let page = ManualTable.Page(physical: 7, printed: "31")
    private let book = "Invented Book"

    /// Table Q7 read from a picture (the document grid), clear unless a test marks it otherwise.
    private func pictured(_ recognised: RecognisedPage = F.q7Grid()) throws -> ManualTable {
        let reading = RecognisedGrid.table(recognised, caption: F.q7Caption, page: page)
        let table = try XCTUnwrap(CellCertainty.assess(reading, floor: 0.6, secondPass: nil).outcome.table)
        XCTAssertTrue(table.source.isRecognised)
        return table
    }

    /// A grid keyed by numbers, 10 to 16, under one heading over three numbered columns.
    private func numberKeyed() throws -> ManualTable {
        var cells = [F.cell(0...1, 0...0, "Size"), F.cell(0...0, 1...3, "Invented band")]
        cells += ["40", "55", "70"].enumerated().map { F.cell(1, $0.offset + 1, $0.element) }
        for (index, key) in ["10", "12", "14", "16"].enumerated() {
            cells += [F.cell(index + 2, 0, key), F.cell(index + 2, 1, "2\(index)"), F.cell(index + 2, 2, "6\(index)7"),
                      F.cell(index + 2, 3, "4\(index)")]
        }
        return try pictured(RecognisedPage(tables: [.init(cells: cells)]))
    }

    private func source(_ table: ManualTable) -> TableLookup.Source {
        TableLookup.Source(documentId: "d1", documentName: book, table: table)
    }

    private func lookup(_ table: ManualTable, row: String, column: String? = nil) -> TableLookup.Outcome {
        TableLookup.resolve(.init(table: "Table Q7", row: row, column: column), in: [source(table)])
    }

    private let doNotAnswer = "Do not answer from memory. Tell the technician, and offer to show the page (open it with show_source only if they ask)."

    // MARK: - A recognised cell is given, and says where it came from

    func testARecognisedCellIsGivenWithFromAPictureAndThePage() throws {
        let text = TableLookup.render(lookup(try pictured(), row: "QMX90", column: "Spacing"))
        XCTAssertTrue(text.contains("\"35\""), text)
        XCTAssertTrue(text.contains("read from a picture of the table on page 31 of Invented Book"), text)
        let row = try XCTUnwrap(text.components(separatedBy: "\n").first { $0.hasPrefix("row QMX90 (page 31) — column Spacing (mm): \"35\"") },
                                text)
        XCTAssertTrue(row.hasSuffix(" — read from a picture of the table on page 31 of Invented Book"), row)
        XCTAssertTrue(text.contains("read the value back to the technician"), text)
        XCTAssertTrue(text.contains("offer to show the page (open it with show_source only if they ask)"), text)
        XCTAssertTrue(text.contains("Notes printed with a table read from a picture are not read"), text)
        XCTAssertTrue(text.hasSuffix("Source: Invented Book, page 7 (printed 31), Table Q7"), text)
    }

    func testATextLayerTablesAnswerIsByteForByteWhatItWas() {
        let page = ManualTable.Page(physical: 3, printed: "12")
        let table = ManualTable(
            label: "Table 98", title: "Invented spacings", page: page, rowHeaders: ["Designation"],
            columns: [.init(path: ["Spacing (mm)"], unit: "mm")],
            rows: [.init(path: ["QXRT"], cells: [.init(text: "40", value: 40, unit: "mm")], page: page),
                   .init(path: ["QMX90"], cells: [.init(text: "55", value: 55, unit: "mm")], page: page),
                   .init(path: ["QZ12"], cells: [.init(text: "70", value: 70, unit: "mm")], page: page)],
            notes: [.init(marker: nil, text: "Invented note.")])
        let text = TableLookup.render(TableLookup.resolve(.init(table: "Table 98", row: "QMX90", column: "Spacing"),
                                                          in: [source(table)]))
        XCTAssertEqual(text, """
        Table 98 (Invented spacings), Invented Book:
        row QMX90 (page 12) — column Spacing (mm): "55" (the number 55 mm)
        Notes: Invented note.
        Read the value out as printed, with its row, column and page. Do not interpolate, round, or move to another row.
        Source: Invented Book, page 3 (printed 12), Table 98
        """)
        XCTAssertFalse(text.contains("picture"))
    }

    func testBothRowsOfABetweenRowsAnswerCarryTheMarker() throws {
        let text = TableLookup.render(TableLookup.resolve(.init(table: "Table Q7", row: "13", column: "55"),
                                                          in: [source(try numberKeyed())]))
        let rows = text.components(separatedBy: "\n").filter { $0.hasPrefix("- row") }
        XCTAssertEqual(rows.count, 2, text)
        for row in rows {
            XCTAssertTrue(row.hasSuffix("— read from a picture of the table on page 31 of Invented Book"), row)
        }
        XCTAssertTrue(text.contains("\"617\"") && text.contains("\"627\""), text)
    }

    // MARK: - An uncertain one is never given

    func testAnUnclearCellSaysSoNamesThePageAndGivesNoValue() throws {
        var table = try pictured()
        table.rows[1].cells[1].uncertain = true
        let outcome = lookup(table, row: "QMX90", column: "Spacing")
        guard case .unclear(_, let pages, .cell) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(pages, [page])
        let text = TableLookup.render(outcome)
        XCTAssertEqual(text, "Table Q7 (Invented clearances) is printed on page 31 of Invented Book as a picture, and this "
                       + "cell could not be read clearly from the picture, so there is no value to give. " + doNotAnswer
                       + "\nSource: Invented Book, page 7 (printed 31), Table Q7")
        XCTAssertFalse(text.contains("35"), "no value-only token of the cell")
    }

    func testAnUnclearRowNameSaysSo() throws {
        var table = try pictured()
        table.rows[1].keyUncertain = true
        let outcome = lookup(table, row: "QMX90", column: "Spacing")
        guard case .unclear(_, _, .rowKey) = outcome else { return XCTFail("\(outcome)") }
        let text = TableLookup.render(outcome)
        XCTAssertTrue(text.contains("a row's name this lookup depends on could not be read clearly from the picture"), text)
        XCTAssertTrue(text.contains("page 31"), text)
        XCTAssertTrue(text.contains(doNotAnswer), text)
        XCTAssertFalse(text.contains("35"), text)
    }

    func testAnUnclearColumnHeadingSaysSo() throws {
        var table = try pictured()
        table.columns[1].uncertain = true
        let outcome = lookup(table, row: "QMX90", column: "Spacing")
        guard case .unclear(_, _, .columnHeading) = outcome else { return XCTFail("\(outcome)") }
        let text = TableLookup.render(outcome)
        XCTAssertTrue(text.contains("a column's heading this lookup depends on could not be read clearly from the picture"), text)
        XCTAssertTrue(text.contains("page 31"), text)
        XCTAssertTrue(text.contains(doNotAnswer), text)
        XCTAssertFalse(text.contains("35"), text)
    }

    // MARK: - A loose match over an uncertain name gives no value (doubt 5a)

    func testALooseRowMatchIsRefusedWhenAnyRowNameIsUncertain() throws {
        var table = try pictured()
        guard case .found(let clear) = lookup(table, row: "the QZ12 row", column: "Spacing") else { return XCTFail("words") }
        XCTAssertEqual(clear.rows.map(\.path), [["QZ12"]])

        table.rows[0].keyUncertain = true
        let loose = lookup(table, row: "the QZ12 row", column: "Spacing")
        guard case .unclear(_, _, .rowKey) = loose else { return XCTFail("\(loose)") }
        XCTAssertFalse(TableLookup.render(loose).contains("40"), "no value-only token of the row's cell")

        // An exact name on a row whose own name is clear is still read.
        guard case .found(let exact) = lookup(table, row: "QZ12", column: "Spacing") else { return XCTFail("exact") }
        XCTAssertEqual(exact.rows[0].cells[exact.columns[0]].text, "40")
    }

    func testARowFoundByNumberIsRefusedWhenAnyRowNameIsUncertain() throws {
        var table = try numberKeyed()
        guard case .found(let clear) = lookup(table, row: "12 mm", column: "55") else { return XCTFail("by number") }
        XCTAssertEqual(clear.rows.map(\.path), [["12"]])
        table.rows[3].keyUncertain = true
        guard case .unclear(_, _, .rowKey) = lookup(table, row: "12 mm", column: "55") else { return XCTFail("loose") }
        guard case .found = lookup(table, row: "12", column: "55") else { return XCTFail("exact on a clear name") }
    }

    func testALooseColumnMatchIsRefusedWhenAnyHeadingIsUncertain() throws {
        var table = try pictured()
        guard case .found = lookup(table, row: "QMX90", column: "the spacing") else { return XCTFail("words") }
        table.columns[0].uncertain = true
        let loose = lookup(table, row: "QMX90", column: "the spacing")
        guard case .unclear(_, _, .columnHeading) = loose else { return XCTFail("\(loose)") }
        guard case .found(let exact) = lookup(table, row: "QMX90", column: "Spacing") else { return XCTFail("exact") }
        XCTAssertEqual(exact.rows[0].cells[exact.columns[0]].text, "35")
        // A column search by loose words is refused the same way.
        guard case .refused(.unclear(_, _, .columnHeading)) = TableLookup.search(
            .init(table: "Table Q7", row: "", column: "the spacing"), value: 33, rule: .atLeast, in: [source(table)])
        else { return XCTFail("search") }
    }

    func testATextLayerTableMatchesLooselyAsBefore() throws {
        var table = try pictured()
        table.source = .textLayer
        guard case .found = lookup(table, row: "the QZ12 row", column: "the spacing") else { return XCTFail("unchanged") }
    }

    // MARK: - Rule chains

    private func drop() throws -> ChainDefinition {
        try XCTUnwrap(ChainParser.parse(RuleChainFixtures.chainsMarkdown).chains.first { $0.name == "Voltage drop on a run" })
    }

    /// The fixture tables with Table 97 as if read from a picture.
    private func tablesWithPicturedQ97(_ change: (inout ManualTable) -> Void = { _ in }) -> [TableLookup.Source] {
        RuleChainFixtures.tables().map { source in
            guard source.table.label == "Table 97" else { return source }
            var table = source.table
            table.source = .recognised(reader: .documentGrid, meanConfidence: 0.9)
            change(&table)
            return TableLookup.Source(documentId: source.documentId, documentName: source.documentName, table: table)
        }
    }

    private func run(_ chain: ChainDefinition, answers: [String], tables: [TableLookup.Source]) -> (ChainStep, ChainState) {
        var state = ChainState()
        var step = ChainRunner.advance(chain, state: &state, answer: nil, tables: tables)
        for answer in answers {
            guard case .ask = step else { break }
            step = ChainRunner.advance(chain, state: &state, answer: answer, tables: tables)
        }
        return (step, state)
    }

    func testAChainStepFromAPictureIsMarkedAndTheChainStillFinishes() throws {
        let chain = try drop()
        let (step, state) = run(chain, answers: ["QX6", "20", "100", "240"], tables: tablesWithPicturedQ97())
        guard case .finished = step else { return XCTFail("a recognised cell never stops a chain: \(step)") }
        let mark = "from a picture of Table 97 (Run lengths), PDF page 4: check it against the page"
        XCTAssertEqual(ChainRunner.pictureMarks(state), [mark])
        let readBack = ChainRunner.readBack(chain, state: state)
        XCTAssertTrue(readBack.contains("drop: Table 97 (Run lengths), row QX6, column Drop (V): 1.1 V"), readBack)
        XCTAssertTrue(readBack.contains(" — " + mark), readBack)
        XCTAssertEqual(state.entries.filter { $0.pictureMark != nil }.count, 1, "only the step that read the picture")

        let (_, plain) = run(chain, answers: ["QX6", "20", "100", "240"], tables: RuleChainFixtures.tables())
        XCTAssertEqual(ChainRunner.pictureMarks(plain), [])
        XCTAssertFalse(ChainRunner.readBack(chain, state: plain).contains("picture"))
    }

    func testAChainStopsOnAnUnclearCellNamingThePage() throws {
        let chain = try drop()
        let tables = tablesWithPicturedQ97 { table in
            let row = table.rows.firstIndex { $0.path == ["QX6"] }!
            table.rows[row].cells[1].uncertain = true
        }
        let (step, state) = run(chain, answers: ["QX6", "20", "100"], tables: tables)
        guard case .stopped(let stop) = step else { return XCTFail("\(step)") }
        XCTAssertTrue(stop.reason.hasPrefix("Table 97 (Run lengths) is printed on PDF page 4 of Invented Book A as a picture, "
                                            + "and this cell could not be read clearly from the picture"), stop.reason)
        XCTAssertTrue(stop.reason.contains("Show the page and work this step from the book."), stop.reason)
        XCTAssertEqual(stop.sourceLine, "Source: Invented Book A, page 4, Table 97")
        XCTAssertFalse(stop.reason.contains("1.1"), "no value-only token of the cell")
        XCTAssertNil(state.values["drop"])
    }

    func testAProposedChainThatReadsAPictureCarriesTheSameMark() throws {
        // A proposal runs through the same runner as an authored chain; parsed back from the form
        // a proposal keeps, it marks the step the same way.
        let proposed = try XCTUnwrap(ChainParser.parse(KeptChains.markdown(try drop())).chains.first)
        let (step, state) = run(proposed, answers: ["QX6", "20", "100", "240"], tables: tablesWithPicturedQ97())
        guard case .finished = step else { return XCTFail("\(step)") }
        XCTAssertEqual(ChainRunner.pictureMarks(state).count, 1)
    }

    // MARK: - The reading filed on the job keeps it

    func testAFiledReadingKeepsThePictureMarksAndOlderReadingsReadWithout() throws {
        let marked = SpokenReading(quantity: "chain: Voltage drop on a run", value: "read-back", method: SpokenReading.ruleChainMethod,
                                   pictureMarks: ["from a picture of Table 97 (Run lengths), PDF page 4: check it against the page"])
        XCTAssertTrue(marked.readFromPicture)
        let json = try JSONEncoder().encode(marked)
        XCTAssertTrue(String(decoding: json, as: UTF8.self).contains("picture_marks"))
        XCTAssertEqual(try JSONDecoder().decode(SpokenReading.self, from: json), marked)
        XCTAssertEqual(marked.movedToScope("unit-2").pictureMarks, marked.pictureMarks)

        let plain = SpokenReading(quantity: "supply air", value: "140", unit: "°F", pictureMarks: [])
        XCTAssertNil(plain.pictureMarks)
        XCTAssertFalse(plain.readFromPicture)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(plain), as: UTF8.self).contains("picture_marks"))
    }

    // MARK: - "Show me the table" outlines the region

    func testThePictureAreaIsStoredOnlyWhenPresentAndRoundTrips() throws {
        var table = try pictured()
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(table), as: UTF8.self).contains("pictureAreas"))
        table.pictureAreas = [.init(physical: 7, rect: CGRect(x: 0, y: 120.5, width: 612, height: 300))]
        let decoded = try JSONDecoder().decode(ManualTable.self, from: try JSONEncoder().encode(table))
        XCTAssertEqual(decoded.pictureAreas, table.pictureAreas)
        XCTAssertEqual(decoded.pictureAreas.first?.rect, CGRect(x: 0, y: 120.5, width: 612, height: 300))

        let old = #"{"label":"Table 98","title":"","page":{"physical":3},"rowHeaders":[],"columns":[],"rows":[],"notes":[],"continues":false}"#
        XCTAssertEqual(try JSONDecoder().decode(ManualTable.self, from: Data(old.utf8)).pictureAreas, [])
    }

    func testAContinuationReadFromAPictureMakesTheTableOneFromAPicture() {
        let first = ManualTable(label: "Table 98", title: "", page: .init(physical: 3),
                                columns: [.init(path: ["Limit"])],
                                rows: [.init(path: ["QA1"], cells: [.init(text: "10", value: 10)], page: .init(physical: 3))])
        var second = ManualTable(label: "Table 98", title: "", page: .init(physical: 4),
                                 columns: [.init(path: ["Limit"])],
                                 rows: [.init(path: ["QA2"], cells: [.init(text: "12", value: 12)], page: .init(physical: 4))],
                                 continues: true, source: .recognised(reader: .documentGrid, meanConfidence: 0.8))
        second.pictureAreas = [.init(physical: 4, rect: CGRect(x: 0, y: 80, width: 612, height: 400))]
        let merged = TableExtractor.merge([first, second])
        XCTAssertEqual(merged.count, 1)
        XCTAssertTrue(merged[0].source.isRecognised, "never presented as the PDF's text")
        XCTAssertEqual(merged[0].pictureAreas, second.pictureAreas)
    }

    func testTheRegionMapsToThePDFsOwnPageSpace() {
        let region = CGRect(x: 50, y: 100, width: 500, height: 200)
        XCTAssertEqual(PictureRegion.pdfRect(ofPageRect: region, mediaBox: CGRect(x: 0, y: 0, width: 612, height: 792)),
                       CGRect(x: 50, y: 492, width: 500, height: 200))
        XCTAssertEqual(PictureRegion.pdfRect(ofPageRect: region, mediaBox: CGRect(x: 10, y: 20, width: 612, height: 792)),
                       CGRect(x: 60, y: 512, width: 500, height: 200))
    }

    func testALookupOnAPictureLeavesItsRegionToOutlineAndNoRowToMark() {
        var memory = AnswerSourceMemory()
        let area = ManualTable.PictureArea(physical: 7, rect: CGRect(x: 0, y: 120, width: 612, height: 300))
        let other = ManualTable.PictureArea(physical: 8, rect: CGRect(x: 0, y: 40, width: 612, height: 300))
        let citations = TableLookup.citations(documentName: book, label: "Table Q7", pages: [page])
        memory.noteTableLookup(rows: [], citations: citations, pictureAreas: [area, other, area], sessionId: "s1")
        XCTAssertEqual(memory.pictureAreas(for: citations[0]), [area], "this page's region, once")
        XCTAssertEqual(memory.retrieved(for: citations[0]), [], "no row passage to mark on a picture")

        let text = TableLookup.citations(documentName: book, label: "Table 98", pages: [.init(physical: 3)])
        memory.noteTableLookup(rows: [], citations: text, sessionId: "s1")
        XCTAssertEqual(memory.pictureAreas(for: text[0]), [])
        XCTAssertEqual(memory.pictureAreas(for: Citation(kind: .manual, title: book, page: 7)), [], "not a table citation")
    }

    func testTheSheetSaysTheOutlineIsWhereThePictureWasRead() {
        let area = ManualTable.PictureArea(physical: 7, rect: CGRect(x: 0, y: 120, width: 612, height: 300))
        let pdf = URL(fileURLWithPath: "/nonexistent/book.pdf")
        let model = ManualPageSheetModel(citation: "Invented Book, page 7, Table Q7", documentTitle: book, citedPage: 7,
                                         manufacturerPDF: pdf, pdfPageCount: 9, documentIsPDF: true,
                                         pictureAreas: [area])
        XCTAssertEqual(model.pictureAreas(onPage: 7), [area])
        XCTAssertNotNil(model.pictureLine)
        XCTAssertTrue(model.pictureLine?.contains("printed as a picture") == true)
        let plain = ManualPageSheetModel(citation: "Invented Book, page 7", documentTitle: book, citedPage: 7,
                                         manufacturerPDF: pdf, pdfPageCount: 9, documentIsPDF: true)
        XCTAssertNil(plain.pictureLine)
    }

    func testShowSourceSaysTheRegionIsOutlined() {
        var staged = FieldSessionService.StagedFigure(documentId: "d1", documentTitle: book, page: 7, figure: "Table Q7")
        staged.pictureAreas = [.init(physical: 7, rect: CGRect(x: 0, y: 120, width: 612, height: 300))]
        let reply = ShowSourceTool.reply(pages: [staged], marks: [.outlined], onScreen: true, removed: [])
        XCTAssertTrue(reply.contains("read from a picture"), reply)
        XCTAssertTrue(reply.contains("outlined"), reply)
        XCTAssertFalse(ShowSourceTool.reply(pages: [staged], marks: [.noPassage], onScreen: true, removed: [])
            .contains("outlined"))
    }

    // MARK: - The description

    func testTheToolDescriptionCarriesTheSentenceIntoThePrompt() throws {
        let sentence = "A value from a table printed as a picture comes back marked \"read from a picture of the table\""
        let tool = TableLookupTool(documentStore: nil)
        XCTAssertTrue(tool.description.replacingOccurrences(of: "\n", with: " ").contains(sentence))
        // The prompt's tool list is built from the description itself (registered with a document
        // store; `SystemPromptBuilderTests` holds the registry to it).
        let lines = SystemPromptBuilder.toolLines([(tool.name, tool.description)])
        XCTAssertTrue(lines.contains(sentence), lines)
        XCTAssertTrue(lines.contains("never given"), lines)
    }
}
