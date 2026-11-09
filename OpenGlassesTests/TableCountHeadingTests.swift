import PDFKit
import XCTest
@testable import OpenGlasses

/// Plan KR follow-up — the headings of a short table counted across its columns, a heading that
/// wraps onto a second line, and a heading set over the rows under the columns' own headings.
/// Every label, heading, name and value is invented (`TableFixtureLayouts`); nothing is taken from
/// any book.
final class TableCountHeadingTests: XCTestCase {

    private typealias L = TableFixtureLayouts
    private var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TableCountHeadingTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    private func only(_ page: L.Page, file: StaticString = #filePath, line: UInt = #line) throws -> ManualTable {
        let found = TableExtractor.extractAll(words: L.words(page), page: ManualTable.Page(physical: 1))
        XCTAssertEqual(found.count, 1, "one caption on the page", file: file, line: line)
        return try XCTUnwrap(found.first?.outcome.table, "\(String(describing: found.first?.outcome))", file: file, line: line)
    }

    private func readPDF(_ pages: [L.Page]) throws -> PDFTableReader.Result {
        let url = try TableFixtures.write(TableFixtures.pdf(pages), named: "tables-\(UUID().uuidString).pdf", in: tempRoot)
        return try XCTUnwrap(PDFTableReader.read(url: url))
    }

    private func source(_ table: ManualTable) -> TableLookup.Source {
        .init(documentId: "inv", documentName: "Invented Book", table: table)
    }

    private func found(_ outcome: TableLookup.Outcome, file: StaticString = #filePath, line: UInt = #line) throws
        -> TableLookup.Found {
        guard case .found(let found) = outcome else {
            XCTFail("\(outcome)", file: file, line: line)
            throw NotFound()
        }
        return found
    }

    private struct NotFound: Error {}

    private static let group = "Most fill of a widget run, % Number of widgets or multi- widget bundles"

    // MARK: - Counted headings over a short table

    func testCountsUnderAHeadingNameTheColumnsOfATableWithTwoRows() throws {
        let table = try only(L.countedFillTable())
        XCTAssertEqual(table.columns.map(\.path), [[Self.group, "1"], [Self.group, "2"], [Self.group, "3"], [Self.group, "Over 3"]],
                       "the counts are the columns' own headings, under every line of the heading over them")
        XCTAssertEqual(table.rows.map(\.path), [["Plain widgets or multi- widget bundles (plain)"],
                                                ["Ringed widgets or widget bundles"]], "the counts are not a row")
        XCTAssertEqual(table.rows[1].cells.map(\.value), [57, 29, 41, 37])

        let column = "Most fill of a widget run, % › Number of widgets or multi-widget bundles › Over 3"
        let hit = try found(TableLookup.resolve(.init(table: "Table 97", row: "Plain widgets or multi-widget bundles (plain)",
                                                      column: column), in: [source(table)]))
        XCTAssertEqual(hit.columns.count, 1)
        XCTAssertEqual(hit.rows.first?.cells[hit.columns[0]].text, "44")
        let three = try found(TableLookup.resolve(.init(table: "Table 97", row: "Ringed widgets or widget bundles", column: "3"),
                                                  in: [source(table)]))
        XCTAssertEqual(three.rows.first?.cells[three.columns[0]].text, "41", "\"3\" is its own column, not \"Over 3\"")
    }

    func testTheCountedHeadingsReadTheSameFromAPDFTextLayer() throws {
        let read = try readPDF([L.countedFillTable()])
        let table = try XCTUnwrap(read.tables.first { $0.label == "Table 97" })
        XCTAssertEqual(table.columns.map { $0.path.last }, ["1", "2", "3", "Over 3"])
        XCTAssertEqual(table.rows.count, 2)
    }

    func testACountingFirstRowThatNamesARowStaysARowUnderFewerThanThreeRows() throws {
        let table = try only(L.countedFillTable(rowNamed: true))
        XCTAssertEqual(table.rows.count, 3, "a row named at the left is the table's own row")
        XCTAssertEqual(table.rows.first?.path, ["Counted"])
    }

    func testCountsGoUpInWholeNumbersTheLastPerhapsInWords() {
        XCTAssertTrue(TableExtractor.countsUp(["1", "2", "3", "Over 3"]))
        XCTAssertTrue(TableExtractor.countsUp(["1", "2", "3", "4"]))
        XCTAssertTrue(TableExtractor.countsUp(["2", "3", "4 or more"]))
        XCTAssertFalse(TableExtractor.countsUp(["3", "2", "1"]), "going down")
        XCTAssertFalse(TableExtractor.countsUp(["1.5", "2.5", "3.5"]), "not whole")
        XCTAssertFalse(TableExtractor.countsUp(["10 kg", "20 kg"]), "quantities, not counts")
        XCTAssertFalse(TableExtractor.countsUp(["1", "Over 3", "4"]), "words only last")
        XCTAssertFalse(TableExtractor.countsUp(["Over 3"]), "one count is no counting")
        XCTAssertTrue(TableExtractor.numberedRowHeads(rowsUnder: 3, namesARow: true, counts: ["5", "1"]),
                      "three rows under it decide as before")
        XCTAssertTrue(TableExtractor.numberedRowHeads(rowsUnder: 2, namesARow: false, counts: ["1", "2", "Over 2"]))
        XCTAssertFalse(TableExtractor.numberedRowHeads(rowsUnder: 2, namesARow: true, counts: ["1", "2", "Over 2"]))
        XCTAssertFalse(TableExtractor.numberedRowHeads(rowsUnder: 2, namesARow: false, counts: ["4", "9", "2"]))
    }

    // MARK: - A heading that wraps

    func testAHeadingContinuesOnTheLineUnderItOnlyWhenItReadsOn() throws {
        func line(_ items: [L.Item]) throws -> TableExtractor.Line {
            try XCTUnwrap(TableExtractor.lines(of: L.words(items)).first)
        }
        let first = try line([L.Item(text: "Number of widgets or multi-", x: 271, y: 458, size: 11)])
        let wrapped = try line([L.Item(text: "widget bundles", x: 271, y: 470, size: 11)])
        let capital = try line([L.Item(text: "Widget bundles", x: 271, y: 470, size: 11)])
        let indented = try line([L.Item(text: "widget bundles", x: 300, y: 470, size: 11)])
        let far = try line([L.Item(text: "widget bundles", x: 271, y: 500, size: 11)])
        let plain = try line([L.Item(text: "Number of widgets", x: 271, y: 458, size: 11)])
        let after = try line([L.Item(text: "Plain bundles", x: 271, y: 470, size: 11)])
        func continues(_ below: TableExtractor.Line, _ above: TableExtractor.Line) -> Bool {
            TableExtractor.continuesHeading(below.phrases[0], on: below, from: above.phrases[0], on: above)
        }
        XCTAssertTrue(continues(wrapped, first))
        XCTAssertTrue(continues(capital, first), "a word broken with a hyphen carries on whatever its case")
        XCTAssertFalse(continues(indented, first), "set from another edge")
        XCTAssertFalse(continues(far, first), "not straight under it")
        XCTAssertTrue(continues(wrapped, plain), "a small letter reads on")
        XCTAssertFalse(continues(after, plain), "a capital under a whole heading is a heading of its own")
    }

    // MARK: - A heading over the rows, under the columns' own headings

    func testAHeadingUnderTheColumnsHeadingsHeadsTheRowsNotTheColumns() throws {
        let table = try only(L.numberedColumnHeadings())
        XCTAssertEqual(table.columns.map { $0.path.last }, (1...4).map { "\($0) Area, mm\u{00B2}" })
        XCTAssertFalse(table.columns.contains { $0.path.contains("Plain widgets") }, "no column takes the heading over the rows")
        XCTAssertEqual(table.rows.map(\.path), ["W2", "W4", "W6", "W8"].map { ["Plain widgets", $0] })
    }

    func testAConcludedPageStartsTheGroupItsOwnHeadingNames() throws {
        let read = try readPDF(L.groupedRowsOverTwoPages(captioned: true))
        let table = try XCTUnwrap(read.tables.first { $0.label == "Table 98" })
        XCTAssertEqual(table.rows.map(\.path), ["W2", "W4", "W6", "W8"].map { ["Plain widgets of every grade", $0] }
                       + ["W2", "W4", "W6"].map { ["Ringed widgets of every grade", $0] })
        try assertGroupsSettleTheRow(table)
    }

    func testAPageCarryingTheTableOnWithNoCaptionStartsTheGroupItsHeadingNames() throws {
        let read = try readPDF(L.groupedRowsOverTwoPages(captioned: false))
        let table = try XCTUnwrap(read.tables.first { $0.label == "Table 98" })
        XCTAssertEqual(table.rows.map(\.path), ["W2", "W4", "W6", "W8"].map { ["Plain widgets of every grade", $0] }
                       + ["W2", "W4", "W6"].map { ["Ringed widgets of every grade", $0] },
                       "the group carried on from the page before stops at the new heading")
        try assertGroupsSettleTheRow(table)
    }

    private func assertGroupsSettleTheRow(_ table: ManualTable, file: StaticString = #filePath, line: UInt = #line) throws {
        let ringed = try found(TableLookup.resolve(.init(table: "Table 98", row: "Ringed widgets of every grade › W4", column: "1 Area, mm²"),
                                                   in: [source(table)]), file: file, line: line)
        XCTAssertEqual(ringed.rows.first?.cells[ringed.columns[0]].text, "111", file: file, line: line)
        guard case .ambiguous(.row, _, let candidates) = TableLookup.resolve(.init(table: "Table 98", row: "W4"),
                                                                            in: [source(table)]) else {
            return XCTFail("a size printed in both groups is asked which", file: file, line: line)
        }
        XCTAssertEqual(candidates, ["Plain widgets of every grade › W4", "Ringed widgets of every grade › W4"], file: file, line: line)
    }

    // MARK: - The chain over the table

    @MainActor
    func testAFillChainCanStartOnTheCountedHeadingsAndTheListFlagsOneThatCannot() throws {
        let markdown = """
        ## Invented widget fill
        Answers: an invented share of a run's area.

        ```chain
        ask area range 1..1000: What is the run's area?
        lookup fill = Table 97 row Plain widgets or multi-widget bundles (plain) column Most fill of a widget run, % › Number of widgets or multi-widget bundles › Over 3 rule exact
        calc allowed = area * fill / 100
        say "{allowed}"
        ```
        """
        let chain = try XCTUnwrap(ChainParser.parse(markdown).chains.first)
        let table = try only(L.countedFillTable())
        XCTAssertTrue(RuleChainTool.columnProblems(chain, tables: [source(table)]).isEmpty)

        // The same table with the counts read as a row, its columns named only by the heading over
        // them: the chain names a column it does not print, and the list says so.
        var unread = table
        unread.columns = table.columns.map { _ in ManualTable.Column(path: [Self.group]) }
        let problem = try XCTUnwrap(RuleChainTool.columnProblems(chain, tables: [source(unread)]).first)
        XCTAssertEqual(RuleChainTool.listMark(problem), "step 2 (fill) names a column Table 97 does not print")
    }
}
