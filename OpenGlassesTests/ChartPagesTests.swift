import SQLite3
import UIKit
import XCTest
@testable import OpenGlasses

/// Plan LX, the words-only part of P2 — a chart found on a manual's page at import, on the phone and
/// with no model, indexed as a passage that says its values were not read; announced to the model
/// so it gives no number from it; and its page staged for the phone, never as the model's picture.
/// One invented manual, drawn into a real PDF so PDFKit's own text layer is read.
@MainActor
final class ChartPagesTests: XCTestCase {

    private typealias Item = TableFixtureLayouts.Item
    private var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChartPagesTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    // MARK: - Fixtures

    /// An invented charging chart: superheat 0 to 40 up the side, outdoor temperature 65 to 115
    /// along the bottom, wet-bulb curve labels and a note inside.
    static func chartPage() -> TableFixtureLayouts.Page {
        var items = [Item(text: "Figure 9. Charging chart, model QMX90", x: 80, y: 150, size: 10, bold: true),
                     Item(text: "Superheat (°F)", x: 40, y: 178)]
        // y ticks right-aligned at x 82: Helvetica's digits are 0.556 em wide.
        for (index, value) in ["40", "30", "20", "10", "0"].enumerated() {
            let width = Double(value.count) * 9 * 0.556
            items.append(Item(text: value, x: 82 - width, y: 195 + Double(index) * 50))
        }
        for (index, value) in ["65", "75", "85", "95", "105", "115"].enumerated() {
            items.append(Item(text: value, x: 110 + Double(index) * 60, y: 420))
        }
        items.append(Item(text: "Outdoor temperature (°F)", x: 200, y: 440))
        for (label, x, y) in [("57", 395.0, 212.0), ("62", 300, 262), ("67", 250, 318), ("72", 180, 372)] {
            items.append(Item(text: label, x: x, y: y))
        }
        items.append(Item(text: "Do not charge below 55 °F", x: 130, y: 228, size: 7))
        items.append(Item(text: "41", x: 300, y: TableFixtureLayouts.pageHeight - 40))
        return items
    }

    private func manualPDF() throws -> URL {
        try TableFixtures.write(TableFixtures.pdf([TableFixtures.prosePage(), TableFixtureLayouts.simpleGrid(),
                                                   Self.chartPage()]),
                                named: "manual.pdf", in: tempRoot)
    }

    private func makeStore() -> (DocumentStore, URL) {
        let dir = tempRoot.appendingPathComponent("store-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (DocumentStore(directory: dir), dir)
    }

    private func rows(_ directory: URL) -> [(index: Int, text: String, embedding: Data?, kind: String?, page: Int?)] {
        var db: OpaquePointer?
        sqlite3_open(directory.appendingPathComponent("documents.sqlite").path, &db)
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT chunk_index, text, embedding, kind, page FROM doc_chunks ORDER BY chunk_index", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        var out: [(Int, String, Data?, String?, Int?)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let blob = sqlite3_column_blob(stmt, 2).map { Data(bytes: $0, count: Int(sqlite3_column_bytes(stmt, 2))) }
            let kind = sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 3))
            let page = sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 4))
            out.append((Int(sqlite3_column_int(stmt, 0)), String(cString: sqlite3_column_text(stmt, 1)), blob, kind, page))
        }
        return out
    }

    private func setLocationVersion(_ version: Int, _ directory: URL) {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("documents.sqlite").path, &db), SQLITE_OK)
        sqlite3_exec(db, "UPDATE doc_chunks SET location_version = \(version)", nil, nil, nil)
        sqlite3_close(db)
    }

    // MARK: - Found at import

    func testAChartOnAManualsPageIsFoundFromItsTextLayer() throws {
        let charts = try XCTUnwrap(VaultDocumentExtractor.charts(from: try manualPDF()))
        XCTAssertEqual(charts.count, 1, "the table page and the prose page are not charts")
        let chart = try XCTUnwrap(charts.first)
        XCTAssertEqual(chart.page.physical, 3)
        XCTAssertEqual(chart.page.printed, "41")
        XCTAssertEqual(chart.caption?.label, "Figure 9")
        XCTAssertEqual(chart.axis(.x)?.values, [65, 75, 85, 95, 105, 115])
        XCTAssertEqual(chart.axis(.y)?.values, [0, 10, 20, 30, 40])
        XCTAssertEqual(chart.axis(.x)?.unit, "°F")
        XCTAssertEqual(chart.axis(.y)?.title, "Superheat (°F)")
        XCTAssertTrue(ChartSafetyClass.classify(chart).isCritical)
    }

    func testIngestStoresAWordsOnlyChartPassageAfterTheRows() async throws {
        let (store, dir) = makeStore()
        let url = try manualPDF()
        let extracted = try VaultDocumentExtractor.extract(from: url)
        let tables = try XCTUnwrap(VaultDocumentExtractor.tables(from: url)).tables
        let charts = try XCTUnwrap(VaultDocumentExtractor.charts(from: url))
        let plain = DocumentChunker().chunk(extracted.text.trimmingCharacters(in: .whitespacesAndNewlines))
        let ref = try await XCTUnwrapAsync(await store.ingest(name: "Invented Manual", text: extracted.text,
                                                              sourceType: "vault_document", namespace: "vault:x",
                                                              pageLabels: extracted.pageLabels, tables: tables,
                                                              charts: charts))
        let stored = rows(dir)
        let rowCount = stored.filter { $0.kind == "table_row" }.count
        let chartRows = stored.filter { $0.kind == "chart" }
        XCTAssertEqual(chartRows.count, 1)
        XCTAssertEqual(chartRows.first?.index, plain.count + rowCount, "numbered after the document's text and rows")
        XCTAssertEqual(chartRows.first?.page, 3)
        XCTAssertTrue(chartRows.first?.text.hasPrefix("Chart: Figure 9 \u{2014} Charging chart, model QMX90 (page 41). Values not read") ?? false)
        XCTAssertNotNil(chartRows.first?.embedding, "embedded like any passage")
        XCTAssertEqual(stored.filter { $0.kind != "table_row" && $0.kind != "chart" }.map(\.text), plain.map(\.text),
                       "the document's own chunks are exactly what they are without charts")

        // Never the document's own text, and never in the way of re-locating it.
        XCTAssertFalse(store.fullText(documentId: ref.id)?.contains("Values not read") ?? true)
        XCTAssertFalse(store.pageTexts(documentId: ref.id).contains { $0.text.contains("Values not read") })
        XCTAssertTrue(store.writeLocations(documentId: ref.id, chunks: plain))

        // Found like any passage.
        let byTerms = store.passages(sharingTermsWith: "charging chart superheat outdoor temperature", namespace: "vault:x")
        XCTAssertTrue(byTerms.contains { $0.kind == .chart && $0.figure == "Figure 9" && $0.page == 3 }, "\(byTerms)")
        XCTAssertTrue(store.query("charging chart superheat outdoor temperature", limit: 20, namespace: "vault:x")
            .contains { $0.kind == .chart }, "the semantic route searches them")
        XCTAssertTrue(store.passages(figure: "Figure 9", namespace: "vault:x", limit: 10).contains { $0.kind == .chart })
    }

    func testReplacingTablesKeepsTheChartPassagesAfterTheRows() async throws {
        let (store, dir) = makeStore()
        let url = try manualPDF()
        let extracted = try VaultDocumentExtractor.extract(from: url)
        let tables = try XCTUnwrap(VaultDocumentExtractor.tables(from: url)).tables
        let ref = try await XCTUnwrapAsync(await store.ingest(name: "Invented Manual", text: extracted.text, namespace: "vault:x",
                                                              tables: [], charts: try XCTUnwrap(VaultDocumentExtractor.charts(from: url))))
        let write = await store.replaceTables(tables, documentId: ref.id)
        XCTAssertEqual(write.chartPassages, 0, "the charts were kept, not rewritten")
        let stored = rows(dir)
        XCTAssertEqual(Set(stored.map(\.index)).count, stored.count, "no two passages share an index")
        let lastRow = try XCTUnwrap(stored.filter { $0.kind == "table_row" }.map(\.index).max())
        XCTAssertEqual(stored.filter { $0.kind == "chart" }.map(\.index), [lastRow + 1])
    }

    // MARK: - Brought to stored manuals

    func testTheMigrationAddsChartsToAManualAtTheLastVersionWithoutReadingAnythingElse() async throws {
        let (store, dir) = makeStore()
        let url = try manualPDF()
        let extracted = try VaultDocumentExtractor.extract(from: url)
        let ref = try await XCTUnwrapAsync(await store.ingest(name: "Invented Manual", text: extracted.text,
                                                              sourceType: "vault_document", namespace: "vault:x",
                                                              tables: try XCTUnwrap(VaultDocumentExtractor.tables(from: url)).tables))
        // Indexed by the build before charts: location version 10.
        setLocationVersion(10, dir)
        XCTAssertTrue(store.needsLocation(documentId: ref.id))
        let before = rows(dir)

        let entry = VaultDocumentLedger.Entry(file: "manual.pdf", title: ref.name, documentId: ref.id,
                                              contentHash: "h", chunkCount: ref.chunkCount)
        let outcome = await PassageLocationMigration.migrate(entry: entry, fileURL: url, store: store, pictureReader: nil)
        XCTAssertEqual(outcome, PassageLocationMigration.Outcome.located)

        let after = rows(dir)
        let kept = after.filter { $0.kind != "chart" }
        XCTAssertEqual(kept.map(\.index), before.map(\.index))
        XCTAssertEqual(kept.map(\.text), before.map(\.text))
        XCTAssertEqual(kept.map(\.embedding), before.map(\.embedding), "no text chunk or row was re-embedded")
        XCTAssertEqual(after.filter { $0.kind == "chart" }.map(\.index), [before.map(\.index).max()! + 1])
        XCTAssertFalse(store.needsLocation(documentId: ref.id))
        XCTAssertEqual(store.documents.first { $0.id == ref.id }?.chunkCount, before.count + 1)

        let again = await PassageLocationMigration.migrate(entry: entry, fileURL: url, store: store, pictureReader: nil)
        XCTAssertEqual(again, PassageLocationMigration.Outcome.current, "a second launch has nothing to do")
    }

    // MARK: - What the model is told

    private func chartPassage(text: String = "Chart: Figure 9 \u{2014} Charging chart, model QMX90 (page 41). Values not read: the manual gives them only as a chart.",
                              page: Int = 41, figure: String? = "Figure 9") -> VaultRetriever.Passage {
        VaultRetriever.Passage(documentId: "d", documentName: "Invented Manual", chunkIndex: 30, text: text, page: page,
                               section: nil, similarity: 0.8, score: 0.8, matchedTokens: ["67", "85"], kind: .chart, figure: figure)
    }

    func testAChartPassageIsAnnouncedAndTheModelIsToldNotToGiveANumber() {
        let passage = chartPassage()
        XCTAssertEqual(passage.kindLabel, "(chart, Figure 9, page 41; values not read)")
        XCTAssertEqual(passage.citation, "Invented Manual, page 41, Figure 9")
        XCTAssertEqual(chartPassage(figure: nil).citation, "Invented Manual, page 41 (chart)")
        let block = VaultRetriever.promptBlock(.sufficient([passage]))
        XCTAssertTrue(block.contains("[1] (chart, Figure 9, page 41; values not read) Chart: Figure 9"), block)
        XCTAssertTrue(block.contains(VaultRetriever.chartRule))
        XCTAssertTrue(VaultRetriever.chartRule.contains("Never give a number from the chart"))
        XCTAssertTrue(VaultRetriever.chartRule.contains("general knowledge"))
        XCTAssertFalse(VaultRetriever.promptBlock(.sufficient([chartPassage(text: "x").withKind(.prose)])).contains(VaultRetriever.chartRule))
        // The citation reads back as the page and the figure.
        let parsed = CitationLineParser.parse("Source: " + passage.citation)
        XCTAssertEqual(parsed.first?.page, 41)
        XCTAssertEqual(parsed.first?.figure, "Figure 9")
    }

    // MARK: - The page

    func testAQuestionAnsweredByAChartOpensItsPageForThePhoneOnly() {
        let prose = chartPassage(text: "Charge the unit by superheat.", page: 40, figure: nil).withKind(.prose)
        let chart = chartPassage()
        let best = FieldSessionService.bestFigure(in: [prose, chart])
        XCTAssertEqual(best?.kind, .chart, "a chart is a drawing when a page is chosen")
        XCTAssertEqual(best.flatMap { FieldSessionService.chartPassage(onPageOf: $0, in: [prose, chart]) }, chart)
        XCTAssertTrue(FieldSessionService.isCriticalChart(chart))

        // Found through the numbers a value off a chart is asked with, and still opened.
        let decision = FigureAutoOpenPolicy.decide(turnKind: .question, passageKind: .criticalChart, tokenHits: ["67", "85"])
        XCTAssertEqual(decision, .present(reason: .criticalChart))

        var staged = FieldSessionService.StagedFigure(documentId: "d", documentTitle: "Invented Manual", page: 41,
                                                      figure: "Figure 9", sourceFile: "manual.pdf", origin: .automatic)
        staged.isChart = true
        XCTAssertEqual(ManualFigureAttachment.decide(staged: staged, sourceURL: URL(fileURLWithPath: "/tmp/manual.pdf"),
                                                     hasCameraImage: false, isOnDevice: false),
                       .skip(.chartPage), "a chart's page is never the model's picture")
    }

    func testADrawingChunkOnAChartsPageIsTheChartsPage() {
        let drawing = chartPassage(text: "57 62 67 72 65 75 85", figure: "Figure 9").withKind(.diagram)
        let chart = chartPassage()
        let best = FieldSessionService.bestFigure(in: [drawing, chart])
        XCTAssertEqual(best?.kind, .diagram)
        XCTAssertEqual(best.flatMap { FieldSessionService.chartPassage(onPageOf: $0, in: [drawing, chart]) }, chart)
        XCTAssertNil(FieldSessionService.chartPassage(onPageOf: drawing, in: [drawing, chartPassage(page: 42)]))
    }

    func testWhenAChartsPageOpens() {
        typealias P = FigureAutoOpenPolicy
        XCTAssertEqual(P.decide(turnKind: .question, passageKind: .chart, tokenHits: []), .present(reason: .chartForQuestion))
        XCTAssertEqual(P.decide(turnKind: .question, passageKind: .chart, tokenHits: ["67"]), .present(reason: .chartForQuestion),
                       "a chart's value is asked with numbers")
        XCTAssertEqual(P.decide(turnKind: .statement, passageKind: .chart, tokenHits: []), .none(reason: .notAQuestion),
                       "an ordinary chart opens when asked, as figures do")
        XCTAssertEqual(P.decide(turnKind: .statement, passageKind: .criticalChart, tokenHits: []), .present(reason: .criticalChart),
                       "a critical chart's page always opens with what is said about it")
        XCTAssertEqual(P.decide(turnKind: .showMe, passageKind: .chart, tokenHits: []), .present(reason: .askedForPage))
        XCTAssertEqual(P.decide(turnKind: .reading, passageKind: .criticalChart, tokenHits: ["22"]), .none(reason: .reading),
                       "a reading asks for no page")
        XCTAssertEqual(P.decide(turnKind: .question, passageKind: .chart, tokenHits: [], namedPages: [41], passagePage: 41),
                       .none(reason: .pageNamed), "a named page is manual_figure's; a chart is never attached for the model")
        XCTAssertEqual(P.PassageKind(.chart), .chart)
        XCTAssertEqual(P.PassageKind(.chart, criticalChart: true), .criticalChart)
        XCTAssertEqual(P.PassageKind(.diagram, criticalChart: true), .diagram)
    }
}

private extension VaultRetriever.Passage {
    func withKind(_ kind: DocumentChunker.Kind) -> VaultRetriever.Passage {
        var copy = self
        copy.kind = kind
        return copy
    }
}

private func XCTUnwrapAsync<T>(_ expression: @autoclosure () async throws -> T?, file: StaticString = #filePath,
                               line: UInt = #line) async throws -> T {
    let value = try await expression()
    return try XCTUnwrap(value, file: file, line: line)
}
