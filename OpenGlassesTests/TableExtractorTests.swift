import PDFKit
import UIKit
import XCTest
@testable import OpenGlasses

/// Plan JJ P0 — a captioned table read off a page into headers, rows, cells and notes. Every table
/// is invented (`TableFixtureLayouts`); the pure tests feed positioned words, the end-to-end ones a
/// PDF drawn in the test, read back through PDFKit's text layer exactly as an import reads one.
final class TableExtractorTests: XCTestCase {

    private var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TableExtractorTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    private func only(_ page: TableFixtureLayouts.Page, physical: Int = 1,
                      file: StaticString = #filePath, line: UInt = #line) throws -> ManualTable {
        let found = TableExtractor.extractAll(words: TableFixtureLayouts.words(page),
                                              page: ManualTable.Page(physical: physical))
        XCTAssertEqual(found.count, 1, "one caption on the page", file: file, line: line)
        return try XCTUnwrap(found.first?.outcome.table, "\(String(describing: found.first?.outcome))",
                             file: file, line: line)
    }

    private func readPDF(_ pages: [TableFixtureLayouts.Page], printed: [Int: String] = [:]) throws -> PDFTableReader.Result {
        let url = try TableFixtures.write(TableFixtures.pdf(pages), named: "tables-\(UUID().uuidString).pdf", in: tempRoot)
        return try XCTUnwrap(PDFTableReader.read(url: url, printedLabels: printed))
    }

    // MARK: - A simple grid

    func testASimpleGridExtractsItsHeadersRowsAndCells() throws {
        let table = try only(TableFixtureLayouts.simpleGrid())
        XCTAssertEqual(table.label, "Table 99")
        XCTAssertEqual(table.title, "Conductor ratings")
        XCTAssertEqual(table.rowHeaders, ["Designation", "Conductors"], "both leading text columns head the rows")
        XCTAssertEqual(table.columns.map(\.name), ["Rating group 1", "Rating group 2", "Rating group 3"])
        XCTAssertEqual(table.rows.map(\.path), [["QXRT", "two conductors"], ["QXRT", "three conductors"],
                                                ["QMX90", "two conductors"], ["QMX90", "three conductors"]],
                       "a designation printed once heads the rows under it")
        XCTAssertEqual(table.rows[1].cells.map(\.value), [30, 35, 40])
        XCTAssertEqual(table.rows[1].cells.map(\.text), ["30", "35", "40"])
        XCTAssertTrue(table.notes.isEmpty)
        XCTAssertFalse(table.continues)
    }

    func testATwoLevelHeaderGivesEachColumnItsPath() throws {
        let table = try only(TableFixtureLayouts.twoLevelHeader())
        XCTAssertEqual(table.columns.map(\.path), [
            ["Rating group 1", "Band A"], ["Rating group 1", "Band B"], ["Rating group 1", "Band C"],
            ["Rating group 2", "Band A"], ["Rating group 2", "Band B"], ["Rating group 2", "Band C"],
        ])
        XCTAssertEqual(table.columns[4].name, "Rating group 2 › Band B")
        XCTAssertEqual(table.rowHeaders, ["Ambient (°C)"], "a range like 7-9 is a row header, not a number")
        XCTAssertEqual(table.rows.map(\.path), [["7-9"], ["10-12"], ["13-15"], ["16-18"]])
        XCTAssertEqual(table.rows[2].cells[4].value, 0.86)
    }

    func testUnitsInTheHeaderAndInACellParse() throws {
        let table = try only(TableFixtureLayouts.unitsInHeader())
        XCTAssertEqual(table.columns.map(\.unit), ["m", "V", nil])
        let first = try XCTUnwrap(table.rows.first)
        XCTAssertEqual(first.cells[0], ManualTable.Cell(text: "12.5", value: 12.5, unit: "m"))
        XCTAssertEqual(first.cells[1], ManualTable.Cell(text: "0.8", value: 0.8, unit: "V"))
        XCTAssertEqual(first.cells[2], ManualTable.Cell(text: "16 A", value: 16, unit: "A"), "a cell's own unit")
    }

    func testFootnoteMarkersAttachToCellsAndTheNotesAreKept() throws {
        let table = try only(TableFixtureLayouts.footnotes())
        let cells = table.rows.map { $0.cells[0] }
        XCTAssertEqual(cells.map(\.value), [40, 45, 50], "a marker never changes the number")
        XCTAssertEqual(cells.map(\.markers), [["*"], ["1"], ["a"]])
        XCTAssertEqual(cells.map(\.text), ["40*", "45\u{00B9}", "50 (a)"], "the text is as printed")
        XCTAssertEqual(table.notes, [
            ManualTable.Note(marker: "*", text: "Value for a dry location."),
            ManualTable.Note(marker: "1", text: "Use only with rating group 2."),
            ManualTable.Note(marker: "a", text: "Applies inside an enclosure."),
        ])
    }

    func testAContinuedTableMergesWithEachRowsPage() throws {
        let pages = TableFixtureLayouts.continued()
        let first = try only(pages[0], physical: 4)
        let second = try only(pages[1], physical: 5)
        XCTAssertFalse(first.continues)
        XCTAssertTrue(second.continues, "the caption read (Continued)")
        let merged = TableExtractor.merge([first, second])
        XCTAssertEqual(merged.count, 1)
        let table = try XCTUnwrap(merged.first)
        XCTAssertEqual(table.title, "Spacing", "the first page's caption and headers")
        XCTAssertFalse(table.continues)
        XCTAssertEqual(table.rows.map(\.path), [["QA1"], ["QA2"], ["QA3"], ["QA4"], ["QA5"], ["QA6"]])
        XCTAssertEqual(table.rows.map(\.page.physical), [4, 4, 4, 5, 5, 5])
        XCTAssertEqual(table.pages.map(\.physical), [4, 5])
        XCTAssertEqual(table.columns.first?.unit, "mm")
    }

    func testAContinuationWithNothingBeforeItStaysOnItsOwn() throws {
        let second = try only(TableFixtureLayouts.continued()[1], physical: 9)
        let merged = TableExtractor.merge([second])
        XCTAssertEqual(merged.count, 1)
        XCTAssertTrue(merged[0].continues, "marked as continuing a table that was not found")
        let unrelated = try only(TableFixtureLayouts.simpleGrid(), physical: 8)
        XCTAssertEqual(TableExtractor.merge([unrelated, second]).count, 2, "a different label never joins")
    }

    // MARK: - What is not a table

    func testADrawingWithNumbersExtractsNothing() {
        XCTAssertTrue(TableExtractor.extractAll(words: TableFixtureLayouts.words(TableFixtureLayouts.drawingFigure()),
                                                page: .init(physical: 1)).isEmpty,
                      "a figure caption is not a table caption")
        let loose = TableExtractor.extractAll(words: TableFixtureLayouts.words(TableFixtureLayouts.drawingUnderTableCaption()),
                                              page: .init(physical: 1))
        XCTAssertEqual(loose.map(\.outcome.failure), [.tooFewRows])
        let dense = TableExtractor.extractAll(
            words: TableFixtureLayouts.words(TableFixtureLayouts.drawingUnderTableCaption(pitch: 12)),
            page: .init(physical: 1))
        XCTAssertEqual(dense.map(\.outcome.failure), [.varyingColumnCount],
                       "labels close enough to read as rows still never line up into columns")
    }

    func testACaptionOverProseExtractsNothingAndSaysSo() {
        let found = TableExtractor.extractAll(words: TableFixtureLayouts.words(TableFixtureLayouts.captionOverProse()),
                                              page: .init(physical: 1))
        XCTAssertEqual(found.map(\.caption.label), ["Table 92"])
        XCTAssertEqual(found.map(\.outcome.failure), [.tooFewRows])
    }

    func testAPageWithNoWordsHasNoTextLayer() {
        let caption = TableExtractor.Caption(label: "Table 99", title: "", continues: false)
        XCTAssertEqual(TableExtractor.extract(words: [], caption: caption, page: .init(physical: 1)),
                       .failed(.noTextLayer))
        XCTAssertEqual(TableExtractor.extract(words: TableFixtureLayouts.words(TableFixtureLayouts.unitsInHeader()),
                                              caption: caption, page: .init(physical: 1)),
                       .failed(.captionNotFound))
    }

    func testCellsSpanningColumnsBeyondTheToleranceAreRefused() {
        var page: TableFixtureLayouts.Page = [TableFixtureLayouts.Item(text: "TABLE 90 Spans", x: 50, y: 60, size: 10, bold: true)]
        page += [("Designation", 50.0), ("Group 1", 200), ("Group 2", 300)].map {
            TableFixtureLayouts.Item(text: $0.0, x: $0.1, y: 90, bold: true)
        }
        for (index, name) in ["QA1", "QA2", "QA3", "QA4"].enumerated() {
            let y = 106 + Double(index) * 14
            page.append(.init(text: name, x: 50, y: y))
            if index.isMultiple(of: 2) {
                page.append(.init(text: "10", x: 200, y: y))
                page.append(.init(text: "12", x: 300, y: y))
            } else {
                // One value printed across both columns, as a merged cell is.
                page.append(.init(text: "applies to both groups alike", x: 200, y: y))
            }
        }
        let found = TableExtractor.extractAll(words: TableFixtureLayouts.words(page), page: .init(physical: 1))
        XCTAssertEqual(found.map(\.outcome.failure), [.mergedCells])
    }

    // MARK: - Captions and cells

    /// One direction only: every table caption `ManualStructure` names a chunk by is a caption
    /// here, with the same label. The extractor also reads plain captions on a page with no bold,
    /// which the chunker never names.
    func testEveryChunkerTableCaptionIsAnExtractorCaption() {
        let cases: [(String, Bool)] = [("TABLE 99 Conductor ratings", true), ("Table 96", true),
                                       ("TABLE 96 (Continued)", true), ("See Table 99 for values", false),
                                       ("TABLE 99 Conductor ratings", false), ("FIGURE 94 Terminal block", true)]
        for (text, bold) in cases {
            let typed = ManualStructure.caption(ManualStructure.TypedLine(raw: text, size: 10, bold: bold))
            let words = TableFixtureLayouts.words([TableFixtureLayouts.Item(text: text, x: 50, y: 60, size: 10, bold: bold)])
            let positioned = TableExtractor.lines(of: words).first.flatMap { TableExtractor.caption(of: $0) }
            if let typed, typed.label.hasPrefix("Table") {
                XCTAssertEqual(positioned?.label, typed.label, text)
            }
            if !bold {
                XCTAssertNil(positioned, "on a page that sets anything in bold, a plain line is not a caption: \(text)")
            }
        }
        let continued = TableExtractor.lines(of: TableFixtureLayouts.words(
            [TableFixtureLayouts.Item(text: "TABLE 96 (Continued)", x: 50, y: 60, size: 10, bold: true)]))
        XCTAssertEqual(continued.first.flatMap { TableExtractor.caption(of: $0) },
                       TableExtractor.Caption(label: "Table 96", title: "", continues: true))
    }

    // MARK: - A text layer with no bold

    func testAPlainCaptionOverAGridExtractsOnAPageWithNoBold() throws {
        let table = try only(TableFixtureLayouts.singleFontGrid())
        XCTAssertEqual(table.label, "Table 95")
        XCTAssertEqual(table.title, "Spacing limits")
        XCTAssertEqual(table.rowHeaders, ["Designation"], "the header is read without weight")
        XCTAssertEqual(table.columns.map(\.name), ["Limit (A)", "Spacing (mm)"])
        XCTAssertEqual(table.columns.map(\.unit), ["A", "mm"])
        XCTAssertEqual(table.rows.map(\.path), [["QA7"], ["QA8"], ["QA9"], ["QA11"]])
        XCTAssertEqual(table.rows[2].cells.map(\.value), [23, 38])
    }

    func testAWrappedTitleOnAPageWithNoBoldIsReadAsTheTitle() throws {
        let table = try only(TableFixtureLayouts.singleFontWrappedTitle())
        XCTAssertEqual(table.title, "Invented spacing limits for the invented designations set out in this example, "
                       + "arranged for a test of a title that wraps")
        XCTAssertEqual(table.columns.map(\.name), ["Limit (A)", "Spacing (mm)"])
        XCTAssertEqual(table.rows.map(\.path), [["QB2"], ["QB3"], ["QB5"]])
    }

    func testThePlainCaptionLineIsNotACaptionWhereThePageCarriesBold() {
        let words = TableFixtureLayouts.words(TableFixtureLayouts.singleFontGrid(boldElsewhere: true))
        XCTAssertTrue(TableExtractor.captions(in: words).isEmpty)
        XCTAssertTrue(TableExtractor.extractAll(words: words, page: .init(physical: 1)).isEmpty)
    }

    func testProseThatBeginsWithATableReferenceExtractsNothing() {
        let found = TableExtractor.extractAll(words: TableFixtureLayouts.words(TableFixtureLayouts.proseTableReference()),
                                              page: .init(physical: 1))
        XCTAssertEqual(found.map(\.caption.label), ["Table 95"],
                       "the long line is a sentence; only the short line stands alone")
        XCTAssertEqual(found.map(\.outcome.failure), [.tooFewRows], "and no grid follows it")
        let line = { (text: String) in
            TableExtractor.lines(of: TableFixtureLayouts.words([.init(text: text, x: 50, y: 60)])).first
                .flatMap { TableExtractor.caption(of: $0, pageHasBold: false) }
        }
        XCTAssertNil(line("Table 95 lists the limits. The rows below are invented."), "a sentence ends before the line does")
        XCTAssertNil(line("See Table 95"), "a reference that does not begin the line")
        XCTAssertEqual(line("TABLE 95 (Continued)"), TableExtractor.Caption(label: "Table 95", title: "", continues: true))
    }

    func testAPlainCaptionExtractsFromAPDFWithNoBoldInItsTextLayer() throws {
        let result = try readPDF([TableFixtures.prosePage(), TableFixtureLayouts.singleFontGrid(),
                                  TableFixtureLayouts.proseTableReference()])
        XCTAssertEqual(result.captioned, 2, "the table and the short prose line")
        XCTAssertEqual(result.extracted, 1)
        XCTAssertEqual(result.failures, [.tooFewRows: 1])
        XCTAssertEqual(result.tables.first?.rows.compactMap { $0.cells.first?.value }, [14, 17, 23, 29])
    }

    func testCellsParseNumbersUnitsAndMarkers() {
        func cell(_ text: String, unit: String? = nil) -> ManualTable.Cell {
            TableExtractor.parseCell(text, markers: [], columnUnit: unit)
        }
        XCTAssertEqual(cell("1,5").value, 1.5, "a decimal comma")
        XCTAssertEqual(cell("12,000").value, 12_000, "a thousands separator")
        XCTAssertNil(cell("1/0").value, "a designation, not a number")
        XCTAssertNil(cell("7-9").value, "a range is a row header")
        XCTAssertEqual(cell("\u{2212}3").value, -3, "a typeset minus")
        XCTAssertEqual(cell("2.5 mm\u{00B2}"), ManualTable.Cell(text: "2.5 mm\u{00B2}", value: 2.5, unit: "mm\u{00B2}"),
                       "a squared unit is a unit, not a footnote")
        XCTAssertEqual(cell("40\u{00B9}").markers, ["1"])
        XCTAssertEqual(cell("40\u{00B9}").value, 40)
        XCTAssertEqual(cell("35**", unit: "A"), ManualTable.Cell(text: "35**", value: 35, unit: "A", markers: ["**"]))
        XCTAssertEqual(cell("\u{2014}", unit: "A"), ManualTable.Cell(text: "\u{2014}"), "no number, no unit")
        XCTAssertEqual(TableExtractor.unit(in: ["Rating group 2", "Size [mm\u{00B2}]"]), "mm\u{00B2}")
        XCTAssertNil(TableExtractor.unit(in: ["Rating group 2 (see note)"]), "words in brackets are not a unit")
    }

    // MARK: - Row passages

    func testEachRowRendersAsOneSentenceNamingTheTableTheRowAndItsPage() throws {
        var table = try only(TableFixtureLayouts.simpleGrid(), physical: 3)
        table.rows = table.rows.map { row in var row = row; row.page.printed = "12"; return row }
        XCTAssertEqual(TableRowPassage.sentence(for: table.rows[1], in: table),
                       "Table 99 (Conductor ratings), row QXRT, three conductors: 30 in Rating group 1, "
                       + "35 in Rating group 2, 40 in Rating group 3 \u{2014} page 12")
        let rendered = TableRowPassage.chunks(for: [table], startingAt: 7)
        XCTAssertEqual(rendered.chunks.map(\.index), [7, 8, 9, 10], "numbered after the document's own text")
        XCTAssertTrue(rendered.chunks.allSatisfy { $0.kind == .tableRow && $0.figure == "Table 99" && $0.page == 3 })
        XCTAssertEqual(rendered.dropped, 0)
    }

    func testRowPassagesAreCappedPerTable() throws {
        let table = try only(TableFixtureLayouts.longTable(rows: 12))
        XCTAssertEqual(table.rows.count, 12)
        let capped = TableRowPassage.chunks(for: [table, table], startingAt: 0, cap: 5)
        XCTAssertEqual(capped.chunks.count, 10, "five from each table")
        XCTAssertEqual(capped.dropped, 14)
        XCTAssertEqual(TableRowPassage.rowCap, 400)
    }

    func testARowWithNoValueHasNoPassage() {
        let table = ManualTable(label: "Table 99", title: "", page: .init(physical: 1),
                                columns: [.init(path: ["Rating group 1"])],
                                rows: [.init(path: ["QXRT"], cells: [.init(text: "")], page: .init(physical: 1))])
        XCTAssertNil(TableRowPassage.sentence(for: table.rows[0], in: table))
        XCTAssertTrue(TableRowPassage.chunks(for: [table], startingAt: 0).chunks.isEmpty)
    }

    func testATableRoundTripsThroughJSON() throws {
        let table = try only(TableFixtureLayouts.footnotes())
        let decoded = try JSONDecoder().decode(ManualTable.self, from: JSONEncoder().encode(table))
        XCTAssertEqual(decoded, table)
    }

    // MARK: - End to end on a PDF's text layer

    func testTheGridExtractsFromARealPDFTextLayer() throws {
        let result = try readPDF([TableFixtures.prosePage(), TableFixtureLayouts.simpleGrid()], printed: [2: "12"])
        XCTAssertEqual(result.captioned, 1)
        XCTAssertEqual(result.extracted, 1)
        XCTAssertTrue(result.failures.isEmpty)
        let table = try XCTUnwrap(result.tables.first)
        XCTAssertEqual(table.page, ManualTable.Page(physical: 2, printed: "12"))
        XCTAssertEqual(table.columns.map(\.name), ["Rating group 1", "Rating group 2", "Rating group 3"])
        XCTAssertEqual(table.rows.map(\.path).last, ["QMX90", "three conductors"])
        XCTAssertEqual(table.rows.flatMap { $0.cells.compactMap(\.value) },
                       [25, 30, 35, 30, 35, 40, 40, 45, 50, 45, 50, 55])
        XCTAssertEqual(TableRowPassage.sentence(for: table.rows[1], in: table),
                       "Table 99 (Conductor ratings), row QXRT, three conductors: 30 in Rating group 1, "
                       + "35 in Rating group 2, 40 in Rating group 3 \u{2014} page 12")
    }

    func testTheImportReadsPrintedPageNumbersFromTheFooter() throws {
        let url = try TableFixtures.write(TableFixtures.pdf([TableFixtureLayouts.simpleGrid(printed: "12")]),
                                          named: "printed.pdf", in: tempRoot)
        let result = try XCTUnwrap(VaultDocumentExtractor.tables(from: url))
        XCTAssertEqual(result.tables.first?.page, ManualTable.Page(physical: 1, printed: "12"))
        XCTAssertNil(VaultDocumentExtractor.tables(from: tempRoot.appendingPathComponent("notes.md")),
                     "a text import has no positions to read")
    }

    func testAContinuedTableMergesAcrossTwoPDFPages() throws {
        let result = try readPDF(TableFixtureLayouts.continued(), printed: [1: "40", 2: "41"])
        XCTAssertEqual(result.captioned, 1, "a continuation is the same table")
        XCTAssertEqual(result.extracted, 1)
        let table = try XCTUnwrap(result.tables.first)
        XCTAssertEqual(table.rows.map { $0.page.printed }, ["40", "40", "40", "41", "41", "41"])
        XCTAssertEqual(table.rows.compactMap { $0.cells.first?.value }, [10, 12, 14, 16, 18, 20])
    }

    func testFootnotesSurviveTheTextLayer() throws {
        let table = try XCTUnwrap(try readPDF([TableFixtureLayouts.footnotes()]).tables.first)
        XCTAssertEqual(table.rows.map { $0.cells[0].markers }, [["*"], ["1"], ["a"]],
                       "a raised digit is read apart from the number it marks")
        XCTAssertEqual(table.rows.map { $0.cells[0].value }, [40, 45, 50])
        XCTAssertEqual(table.notes.map(\.marker), ["*", "1", "a"])
    }

    func testPagesThatAreNotTablesExtractNothingAndAreCounted() throws {
        let scan = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 200)).image { _ in
            UIColor.white.setFill()
            UIRectFill(CGRect(x: 0, y: 0, width: 400, height: 200))
            NSAttributedString(string: "TABLE 89 Scanned", attributes: [.font: UIFont.boldSystemFont(ofSize: 14)])
                .draw(at: CGPoint(x: 10, y: 10))
        }
        let data = UIGraphicsPDFRenderer(bounds: TableFixtures.pageSize).pdfData { context in
            for page in [TableFixtureLayouts.drawingFigure(), TableFixtureLayouts.drawingUnderTableCaption(pitch: 12),
                         TableFixtureLayouts.captionOverProse()] {
                context.beginPage()
                for item in page {
                    let font = UIFont(name: item.bold ? "Helvetica-Bold" : "Helvetica", size: item.size)!
                    NSAttributedString(string: item.text, attributes: [.font: font]).draw(at: CGPoint(x: item.x, y: item.y))
                }
            }
            context.beginPage()
            scan.draw(in: CGRect(x: 50, y: 60, width: 400, height: 200))
        }
        let url = try TableFixtures.write(data, named: "not-tables.pdf", in: tempRoot)
        let result = try XCTUnwrap(PDFTableReader.read(url: url))
        XCTAssertEqual(result.extracted, 0)
        XCTAssertEqual(result.captioned, 2, "the drawing under a table caption and the caption over prose")
        XCTAssertEqual(result.failures, [.varyingColumnCount: 1, .tooFewRows: 1])
        XCTAssertEqual(result.pagesWithoutText, 1, "the scanned page has no text layer to read")
    }
    // MARK: - A revision mark beside the caption (Plan JW P0)

    private typealias L = TableFixtureLayouts

    /// One line of positioned words, as `TableExtractor.lines` reads it.
    private func line(_ items: [TableFixtureLayouts.Item]) throws -> TableExtractor.Line {
        try XCTUnwrap(TableExtractor.lines(of: L.words(items)).first)
    }

    func testAMarkedCaptionIsReadOnAPageThatCarriesBold() throws {
        for mark in ["\u{0394}", "\u{25B2}", "\u{25BA}", "|", "\u{2022}"] {
            let table = try only(L.markedCaption(mark: mark))
            XCTAssertEqual(table.label, "Table 99", mark)
            XCTAssertEqual(table.title, "Widget ratings", "the mark is not part of the title")
            XCTAssertEqual(table.rows.map(\.path), [["W1"], ["W2"], ["W3"], ["W4"]])
            XCTAssertEqual(table.rows[2].cells.map(\.value), [17, 29])
        }
    }

    func testAMarkedCaptionIsReadOnAPageSetInOneWeight() throws {
        let table = try only(L.markedCaption(bold: false))
        XCTAssertEqual(table.label, "Table 99")
        XCTAssertEqual(table.title, "Widget ratings")
        XCTAssertEqual(table.rows.count, 4)
    }

    func testTheMarkCountsTowardNoOtherCaptionRule() throws {
        // Twelve words is the longest plain caption; the mark is not a thirteenth.
        let twelve = "Table 99 Invented widget ratings for the example widgets of this test"
        XCTAssertEqual(twelve.split(separator: " ").count, TableExtractor.plainCaptionMaximumWords)
        let marked = try line([.init(text: "\u{25B2}", x: 18, y: 60), .init(text: twelve, x: 50, y: 60)])
        XCTAssertEqual(TableExtractor.caption(of: marked, pageHasBold: false)?.label, "Table 99")
        // The bold rule reads the first word after the mark: a bold mark over plain prose is not a caption.
        let boldMark = try line([.init(text: "\u{25B2}", x: 18, y: 60, bold: true), .init(text: "Table 99 lists widgets", x: 50, y: 60)])
        XCTAssertNil(TableExtractor.caption(of: boldMark, pageHasBold: true))
        let plainMark = try line([.init(text: "\u{25B2}", x: 18, y: 60), .init(text: "TABLE 99 Widget ratings", x: 50, y: 60, bold: true)])
        XCTAssertEqual(TableExtractor.caption(of: plainMark, pageHasBold: true)?.label, "Table 99",
                       "an unbolded mark before a bold caption")
    }

    func testAMarkAloneDoesNotMakeProseACaption() throws {
        let sentence = "Table 99 shows the ratings of every invented widget on this page and the next one."
        let marked = try line([.init(text: "\u{0394}", x: 18, y: 60), .init(text: sentence, x: 50, y: 60)])
        XCTAssertNil(TableExtractor.caption(of: marked, pageHasBold: false), "a sentence is still a sentence")
        XCTAssertNil(TableExtractor.caption(of: marked, pageHasBold: true), "and prose is not bold")
        let reference = try line([.init(text: "\u{25B2}", x: 18, y: 60), .init(text: "See TABLE 99 for widgets", x: 50, y: 60, bold: true)])
        XCTAssertNil(TableExtractor.caption(of: reference, pageHasBold: true), "a cross-reference after a mark")
        let onlyMarks = try line([.init(text: "\u{25B2}", x: 18, y: 60), .init(text: "|", x: 40, y: 60)])
        XCTAssertNil(TableExtractor.caption(of: onlyMarks, pageHasBold: false))
        // A prose page with a mark before its sentence extracts nothing.
        var page = L.proseTableReference()
        page.append(.init(text: "\u{0394}", x: 18, y: 102))
        XCTAssertTrue(TableExtractor.extractAll(words: L.words(page), page: .init(physical: 1))
            .allSatisfy { $0.outcome.table == nil })
    }

    func testMarksGluedToTheWordOrBracketsAroundItAreToldApart() {
        XCTAssertEqual(TableExtractor.droppingMarginMarks("\u{25B2}TABLE 98A Widget limits"), "TABLE 98A Widget limits")
        XCTAssertEqual(TableExtractor.droppingMarginMarks("\u{0394}TABLE 99"), "TABLE 99")
        XCTAssertEqual(TableExtractor.droppingMarginMarks("\u{0394} | TABLE 99"), "TABLE 99")
        XCTAssertEqual(TableExtractor.droppingMarginMarks("(TABLE 99)"), "(TABLE 99)", "a bracket is not a mark")
        XCTAssertEqual(TableExtractor.droppingMarginMarks("* TABLE 99 applies"), "* TABLE 99 applies", "a footnote marker is not a mark")
        XCTAssertEqual(TableExtractor.droppingMarginMarks("12 TABLE 99"), "12 TABLE 99", "a digit is not a mark")
        XCTAssertEqual(TableExtractor.droppingMarginMarks("TABLE 99"), "TABLE 99")
    }

    func testAMarkedCaptionExtractsFromARealPDFTextLayer() throws {
        let result = try readPDF([TableFixtures.prosePage(), L.markedCaption()])
        XCTAssertEqual(result.captioned, 1)
        XCTAssertEqual(result.extracted, 1)
        let table = try XCTUnwrap(result.tables.first)
        XCTAssertEqual(table.label, "Table 99")
        XCTAssertEqual(table.page.physical, 2)
        XCTAssertEqual(table.rows.count, 4)
    }

    // MARK: - "(Concluded)" (Plan JW P0)

    func testConcludedReadsAsAContinuation() throws {
        let concluding = try line([.init(text: "TABLE 98A (Concluded)", x: 50, y: 60, size: 10, bold: true)])
        let caption = try XCTUnwrap(TableExtractor.caption(of: concluding))
        XCTAssertEqual(caption.label, "Table 98A")
        XCTAssertTrue(caption.continues)
        XCTAssertEqual(caption.title, "")
        let continued = try line([.init(text: "TABLE 98A (Continued)", x: 50, y: 60, size: 10, bold: true)])
        XCTAssertEqual(TableExtractor.caption(of: continued)?.continues, true, "as before")
    }

    func testAConcludingPageOfNotesJoinsTheTableItConcludes() throws {
        let result = try readPDF(L.concluded(), printed: [1: "40", 2: "41"])
        XCTAssertEqual(result.captioned, 1, "one table, not two")
        XCTAssertEqual(result.extracted, 1)
        XCTAssertTrue(result.unextracted.isEmpty, "the notes page is never a table of its own")
        XCTAssertTrue(result.failures.isEmpty, "nor a failure")
        XCTAssertEqual(result.concludingPieces, 1)
        let table = try XCTUnwrap(result.tables.first)
        XCTAssertEqual(table.page, ManualTable.Page(physical: 1, printed: "40"), "cited and opened on the grid page")
        XCTAssertEqual(table.rows.map(\.page.physical), [1, 1, 1, 1])
        XCTAssertEqual(table.notes, [ManualTable.Note(marker: "1", text: "The invented limits apply to dry widgets only."),
                                     ManualTable.Note(marker: "2", text: "Every value here is made up for a test.")],
                       "the concluding page's notes join the table's")
        XCTAssertFalse(table.continues)
    }

    func testAConcludingPageNeverStandsInForATableThatWasNotRead() throws {
        let result = try readPDF(L.concluded(readable: false))
        XCTAssertEqual(result.extracted, 0)
        XCTAssertEqual(result.unextracted.map(\.label), ["Table 98A"], "one pointer, not two")
        XCTAssertEqual(result.unextracted.first?.page.physical, 1, "it points at the caption's own page")
        XCTAssertEqual(result.captioned, 1)
        XCTAssertEqual(result.concludingPieces, 1)
    }

    func testAConcludingPageWithNothingBeforeItIsStillKept() throws {
        let result = try readPDF([TableFixtures.prosePage(), L.concluded()[1]])
        XCTAssertEqual(result.unextracted.map(\.label), ["Table 98A"], "the only pointer there is")
        XCTAssertEqual(result.concludingPieces, 0)
    }

    func testAContinuedTableStillMergesAsBefore() throws {
        let result = try readPDF(L.continued(), printed: [1: "40", 2: "41"])
        XCTAssertEqual(result.extracted, 1)
        XCTAssertEqual(result.concludingPieces, 0, "a continuation with rows is joined by its rows")
        XCTAssertEqual(result.tables.first?.rows.count, 6)
    }

    // MARK: - Headings printed as quantities, bracketed titles, sparse and banded rows, turned pages (Plan JW follow-up)

    func testHeadingsPrintedAsQuantitiesHeadTheColumnsOnAPageSetInOneWeight() throws {
        let table = try only(L.quantityHeadings())
        XCTAssertEqual(table.label, "Table 99")
        XCTAssertTrue(table.title.hasSuffix("(See the invented notes, the example rules and the other example tables.)"),
                      "a long bracketed line under a three-line title is part of the title: \(table.title)")
        XCTAssertEqual(table.rowHeaders, ["Widget, size or grade"], "the row-header heading wrapped over three lines")
        XCTAssertEqual(table.rows.map(\.path), L.quantityKeys.map { [$0] }, "the heading lines are not rows")
        XCTAssertEqual(table.rows[0].cells.map(\.value), [11, 17, 23, 29, 34, 41])
        XCTAssertEqual(table.columns.count, 6)
        for (index, heading) in ["40 kg\u{2021}", "55 kg\u{2021}", "70 kg\u{2021}"].enumerated() {
            XCTAssertEqual(table.columns[index].path.last, heading)
        }
        XCTAssertTrue(table.columns[3].path.contains("85 kg\u{2021}"))
        XCTAssertEqual(table.notes.map(\.marker), ["\u{2021}", "\u{00A7}", "**", nil],
                       "the section sign keys a note of its own, and \"Note:\" is unmarked")
    }

    func testAKeyWithAMarkerGluedToItIsStillFoundByItsNumber() throws {
        let table = try only(L.quantityHeadings())
        let first = TableExtractor.parseCell(try XCTUnwrap(table.rows.first?.path.last), markers: [], columnUnit: nil)
        XCTAssertEqual(first.value, 71)
        XCTAssertEqual(first.markers, ["**"])
        let section = TableExtractor.parseCell("14\u{00A7}", markers: [], columnUnit: nil)
        XCTAssertEqual(section.value, 14, "a section sign after a number is a marker, as a dagger is")
        XCTAssertEqual(section.markers, ["\u{00A7}"])
        XCTAssertEqual(section.text, "14\u{00A7}", "kept as printed")
    }

    func testAShortBracketedUnitUnderTheTitleIsNotReadAsTheTitle() {
        XCTAssertTrue(TableExtractor.opensBracket("(see the notes below)"))
        XCTAssertFalse(TableExtractor.opensBracket("(A)"), "a unit heads a column")
        XCTAssertFalse(TableExtractor.opensBracket("(mm\u{00B2} each)"))
        XCTAssertFalse(TableExtractor.opensBracket("Widget ratings"))
        XCTAssertTrue(TableExtractor.bracketOpen("Widget limits (see the rules"))
        XCTAssertFalse(TableExtractor.bracketOpen("Widget limits (see the rules)"))
    }

    func testRowsOfQuantitiesAreHeadingsOnlyOverRowsOfBareNumbers() {
        typealias Row = TableExtractor.HeaderRuleRow
        func row(_ cells: [String]) -> Row { Row(cells: cells.map { ($0, []) }) }
        let headings = [row(["Widget", "40 kg", "80 kg"]), row(["grade", "Rating A", "Rating B"])]
        let body = [row(["W1", "11", "21"]), row(["W2", "12", "22"]), row(["W3", "13", "23"])]
        XCTAssertTrue(headings[0].isUnitHeading)
        XCTAssertEqual(TableExtractor.pastUnitHeadings(0, in: headings + body), 2, "both heading lines")
        XCTAssertEqual(TableExtractor.pastUnitHeadings(0, in: [headings[0]] + body), 1)
        // Every row prints its units: none of them is a heading.
        let withUnits = [row(["W1", "16 A", "20 A"]), row(["W2", "25 A", "32 A"]), row(["W3", "40 A", "50 A"]),
                         row(["W4", "63 A", "80 A"])]
        XCTAssertEqual(TableExtractor.pastUnitHeadings(0, in: withUnits), 0)
        // Words over the rows, not quantities: nothing to pass.
        XCTAssertEqual(TableExtractor.pastUnitHeadings(0, in: body), 0)
    }

    func testARowOfDashesAndAFewNumbersIsARowOfNumbers() throws {
        typealias Row = TableExtractor.HeaderRuleRow
        let sparse = Row(cells: ["W1", "\u{2014}", "\u{2014}", "9.5", "71", "\u{2014}", "\u{2014}"].map { ($0, []) })
        XCTAssertEqual(sparse.dashesAfterFirst, 4)
        XCTAssertTrue(sparse.isNumeric)
        XCTAssertFalse(Row(cells: ["W1", "\u{2014}", "\u{2014}"].map { ($0, []) }).isNumeric, "dashes alone are no numbers")
        XCTAssertTrue(TableExtractor.isDash("\u{2014}"))
        XCTAssertTrue(TableExtractor.isDash("--"))
        XCTAssertFalse(TableExtractor.isDash("-5"))

        let table = try only(L.sparseFirstRow())
        XCTAssertEqual(table.rows.map(\.path), [["W1"], ["W2"], ["W3"], ["W4"]], "the first row is a row, not a heading")
        XCTAssertEqual(table.columns.map(\.path), [["Inner A"], ["Outer A"], ["Inner B"], ["Outer B"], ["Inner C"], ["Outer C"]])
        XCTAssertEqual(table.rows[0].cells.map(\.value), [nil, nil, 8.7, 64, nil, nil])
    }

    func testARowOfNumbersOverHeadingWordsHeadsTheColumns() throws {
        let table = try only(L.numberedColumnHeadings())
        // The heading set alone over the rows heads them (Plan KR follow-up), not the columns.
        XCTAssertEqual(table.rows.map(\.path), [["Plain widgets", "W2"], ["Plain widgets", "W4"], ["Plain widgets", "W6"],
                                                ["Plain widgets", "W8"]])
        XCTAssertEqual(table.columns.count, 4)
        for index in 0..<4 {
            XCTAssertTrue(table.columns[index].path.contains("\(index + 1) Area, mm\u{00B2}"),
                          "\(table.columns[index].path)")
        }
        XCTAssertEqual(table.rows[1].cells.map(\.value), [7, 14, 21, 28])
    }

    func testANumbersRowIsAHeadingOnlyWhenItRisesAndWordsFollowIt() {
        typealias Row = TableExtractor.HeaderRuleRow
        XCTAssertTrue(Row(cells: ["1", "2", "3", "10"].map { ($0, []) }).ascendingNumbers)
        XCTAssertTrue(Row(cells: ["Group B", "1", "2", "3"].map { ($0, []) }).ascendingNumbers, "a word at its left")
        XCTAssertFalse(Row(cells: ["4", "2", "3"].map { ($0, []) }).ascendingNumbers)
        XCTAssertFalse(Row(cells: ["1", "Widget", "2"].map { ($0, []) }).ascendingNumbers)
        XCTAssertFalse(Row(cells: ["1", "20 kg", "30 kg"].map { ($0, []) }).ascendingNumbers, "quantities, not numbers")
    }

    func testRowsPrintedInBandsReadAsOneBody() throws {
        let result = TableExtractor.extractAll(words: L.words(L.bandedRows()), page: .init(physical: 1))
        let table = try XCTUnwrap(result.first?.outcome.table)
        XCTAssertEqual(table.rows.map(\.path), (1...9).map { ["W\($0)"] }, "every band, not the first only")
        XCTAssertEqual(table.rows[8].cells.map(\.value), [12, 24, 36])
        XCTAssertEqual(table.columns.map(\.unit), ["A", "A", "A"])
    }

    func testAWordWhoseLostSpaceWasSplitBetweenTwoLettersIsCut() throws {
        // A two-digit key and a dash read as one word, the gap between them shared by the key's
        // last digit and the dash: each letter's box runs to the middle of the gap.
        let letters: [CGRect?] = [CGRect(x: 50, y: 0, width: 4, height: 8), CGRect(x: 54, y: 0, width: 16, height: 8),
                                  CGRect(x: 70, y: 0, width: 20, height: 8)]
        let pieces = try XCTUnwrap(PDFTableReader.cuts(letters: letters, size: 8))
        XCTAssertEqual(pieces.map(\.range), [0..<2, 2..<3])
        XCTAssertEqual(pieces[0].box.minX, 50)
        XCTAssertEqual(pieces[0].box.maxX, 62, accuracy: 0.01, "the digit trimmed to an em")
        XCTAssertEqual(pieces[1].box.minX, 82, accuracy: 0.01, "the dash trimmed to an em")
        XCTAssertEqual(pieces[1].box.maxX, 90)
        // Letters of their own widths are never cut, nor is one wide letter beside a narrow one.
        XCTAssertNil(PDFTableReader.cuts(letters: [CGRect(x: 0, y: 0, width: 5, height: 8), CGRect(x: 5, y: 0, width: 5, height: 8)],
                                         size: 8))
        XCTAssertNil(PDFTableReader.cuts(letters: [CGRect(x: 0, y: 0, width: 5, height: 8), CGRect(x: 5, y: 0, width: 20, height: 8)],
                                         size: 8))
    }

    func testABoxIsReadAsThePageIsShown() {
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let box = CGRect(x: 100, y: 700, width: 50, height: 10)
        XCTAssertEqual(PDFTableReader.displayed(box, in: bounds, rotation: 0), CGRect(x: 100, y: 82, width: 50, height: 10),
                       "unturned, the page's own top-down space as before")
        XCTAssertEqual(PDFTableReader.displayed(box, in: bounds, rotation: 90), CGRect(x: 700, y: 100, width: 10, height: 50))
        XCTAssertEqual(PDFTableReader.displayed(box, in: bounds, rotation: 180), CGRect(x: 462, y: 700, width: 50, height: 10))
        XCTAssertEqual(PDFTableReader.displayed(box, in: bounds, rotation: 270), CGRect(x: 82, y: 462, width: 10, height: 50))
    }

    func testATableOnATurnedPageReadsAsItIsShown() throws {
        let document = try XCTUnwrap(TableFixtures.turnedDocument(shown: L.turnedTable(), own: L.turnedFooter()))
        let result = PDFTableReader.read(document: document, printedLabels: [1: "41"])
        XCTAssertEqual(result.captioned, 1)
        XCTAssertEqual(result.extracted, 1)
        let table = try XCTUnwrap(result.tables.first)
        XCTAssertEqual(table.label, "Table 98A")
        XCTAssertEqual(table.page, ManualTable.Page(physical: 1, printed: "41"))
        XCTAssertEqual(table.columns.map(\.path), [["Rating A"], ["Rating B"], ["Rating C"]])
        XCTAssertEqual(table.rows.map(\.path), (1...5).map { ["W\($0)"] }, "the footer beside the rows is not part of them")
        XCTAssertEqual(table.rows[2].cells.map(\.value), [13, 25, 37])

        // The footer, printed the page's own way up, is on its side as shown — a one-letter word
        // on its line too.
        let words = PDFTableReader.positionedWords(on: try XCTUnwrap(document.page(at: 0)))
        let sideways = Set(words.filter(\.sideways).map(\.text))
        XCTAssertTrue(sideways.isSuperset(of: ["March", "2031", "\u{00A9}", "41"]), "\(sideways)")
        XCTAssertFalse(sideways.contains("W1"))

        // The same page unturned: its table's words are on their side, and nothing is read.
        document.page(at: 0)?.rotation = 0
        XCTAssertEqual(PDFTableReader.read(document: document).extracted, 0)
    }
}
