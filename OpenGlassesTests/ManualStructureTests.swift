import PDFKit
import UIKit
import XCTest
@testable import OpenGlasses

/// Plan EK — structure read off a manual's type rather than out of its words.
///
/// The end-to-end case builds a PDF that actually carries type (bold at body size, a caption, a
/// page of small labels) with `UIGraphicsPDFRenderer`, then drives it through the shipped
/// extractor, chunker, store and retriever. The rule cases are pure over `TypedLine`, and mirror
/// the cases `Scripts/extract-manual-text.swift --self-check` runs on the Mac side, so the two
/// producers of vault text cannot drift apart unnoticed.
@MainActor
final class ManualStructureTests: XCTestCase {

    private var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ManualStructureTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    /// A picture on a page does not make it a drawing, on either side: the phone reads the page's type
    /// alone, and the Mac tagged every page with an object in it, which hid the prose beside a
    /// photograph from the search and made a Mac measurement differ from the phone (Plan KG P1).
    func testTheMacExtractorTagsADrawingByItsTypeAlone() throws {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Scripts/extract-manual-text.swift")
        let source = try String(contentsOf: script, encoding: .utf8)
        XCTAssertTrue(source.contains("let diagram = isDiagramPage(page, bodySize: bodySize)"))
        XCTAssertFalse(source.contains("text = diagramMarker"), "the tag is written once, by the rule")
    }

    // MARK: - Fixture

    /// A line of a fixture page: the words, their point size, and whether they are bold.
    private struct Line {
        let text: String
        let size: CGFloat
        let bold: Bool
        init(_ text: String, size: CGFloat = 10, bold: Bool = false) {
            self.text = text
            self.size = size
            self.bold = bold
        }
    }

    /// A PDF whose pages carry real type. Each line is drawn on its own baseline rather than laid
    /// out in a rect, so what PDFKit reads back is the line structure the test wrote.
    private func makeTypedPDF(_ pages: [[Line]], name: String = "fixture") -> URL {
        let url = tempRoot.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(6)).pdf")
        let bounds = CGRect(x: 0, y: 0, width: 460, height: 700)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        let data = renderer.pdfData { context in
            for page in pages {
                context.beginPage()
                var y: CGFloat = 24
                for line in page {
                    let font = UIFont(name: line.bold ? "Helvetica-Bold" : "Helvetica", size: line.size)
                        ?? UIFont.systemFont(ofSize: line.size)
                    NSAttributedString(string: line.text, attributes: [.font: font, .foregroundColor: UIColor.black])
                        .draw(at: CGPoint(x: 24, y: y))
                    y += line.size + 6
                }
            }
        }
        try? data.write(to: url)
        return url
    }

    /// Page 1 is prose under a bold heading; page 2 is a drawing: a bold caption over a page of
    /// labels set below body size, with no sentence in it.
    private var manualPages: [[Line]] {
        [[
            Line("Turning Off Gas to Unit", bold: true),
            Line("Close the manual gas valve upstream of the union before starting."),
            Line("Wait five minutes for any accumulated gas to clear the cabinet."),
            Line("Check the union for leaks with a soap solution once the gas is back on."),
            Line("The blower door must be closed for the unit to run at all."),
            Line("A hard lockout is cleared by cycling the thermostat or the power."),
            Line("Record the manifold pressure before and after any adjustment is made."),
            Line("Failure To Operate", bold: true),
            Line("Check that the disconnect switch beside the furnace is closed."),
            Line("Confirm twenty four volts across the R and C terminals of the control."),
            Line("Confirm the pressure switch closes when the inducer is running."),
            Line("Replace the ignitor if it does not glow within thirty seconds.")
        ], [
            Line("FIGURE 3", bold: true),
            Line("INTEGRATED CONTROL WIRING", bold: true),
            Line("W1 LOW STAGE HEAT", size: 8),
            Line("W2 HIGH STAGE HEAT", size: 8),
            Line("G FAN", size: 8),
            Line("Y1 LOW STAGE COOL", size: 8),
            Line("Y2 HIGH STAGE COOL", size: 8),
            Line("C THERMOSTAT COMMON", size: 8),
            Line("R 24VAC POWER", size: 8),
            Line("DS DEHUMIDIFICATION", size: 8),
            Line("L LSOM COMM ONLY", size: 8),
            Line("O HEAT PUMP REVERSING VALVE", size: 8),
            Line("LGWP1 LOW GWP SENSOR ONE", size: 8),
            Line("LGWP2 LOW GWP SENSOR TWO", size: 8),
            Line("HUM 120 VAC OUTPUT", size: 8),
            Line("XMFR 120 VAC OUTPUT", size: 8),
            Line("CIRC 120 VAC OUTPUT", size: 8),
            Line("1+ DATA HIGH CONNECTION", size: 8),
            Line("1- DATA LOW CONNECTION", size: 8),
            Line("C 24VAXC COMMON", size: 8)
        ]]
    }

    // MARK: - End to end

    func testTypeSurvivesExtractionChunkingStorageAndRetrieval() async throws {
        let url = makeTypedPDF(manualPages)
        let extracted = try VaultDocumentExtractor.extract(from: url)

        // 1 · The extractor writes the grammar. If this fails, read the diagnostic: it means PDFKit
        // handed back a page whose runs carry no usable font, not that the rules are wrong.
        XCTAssertTrue(extracted.text.contains("## Turning Off Gas to Unit"), diagnostic(url, extracted.text))
        XCTAssertTrue(extracted.text.contains("## Failure To Operate"), diagnostic(url, extracted.text))
        XCTAssertTrue(extracted.text.contains("### Figure 3 — INTEGRATED CONTROL WIRING"), diagnostic(url, extracted.text))
        XCTAssertTrue(extracted.text.contains(ManualStructure.diagramMarker), diagnostic(url, extracted.text))
        XCTAssertEqual(extracted.structuredHeadings, 2)
        XCTAssertEqual(extracted.diagramPages, 1)

        // 2 · The chunker reads it: sections from the headings, the drawing tagged and captioned,
        // and not one grammar marker left in the text a passage would quote back.
        let chunks = DocumentChunker(targetChars: 200, maxChars: 300, overlapChars: 0).chunk(extracted.text)
        XCTAssertTrue(chunks.contains { $0.page == 1 && $0.section == "Turning Off Gas to Unit" }, "\(chunks)")
        XCTAssertTrue(chunks.contains { $0.page == 1 && $0.section == "Failure To Operate" }, "\(chunks)")
        let drawing = chunks.filter { $0.page == 2 }
        XCTAssertFalse(drawing.isEmpty)
        XCTAssertTrue(drawing.allSatisfy { $0.kind == .diagram && $0.figure == "Figure 3" }, "\(drawing)")
        XCTAssertTrue(chunks.filter { $0.page == 1 }.allSatisfy { $0.kind == .prose && $0.figure == nil })
        for chunk in chunks {
            XCTAssertFalse(chunk.text.contains("## "), chunk.text)
            XCTAssertFalse(chunk.text.contains("<!--"), chunk.text)
        }
        // The heading is content and stays; only its hashes go.
        XCTAssertTrue(chunks.contains { $0.text.contains("Turning Off Gas to Unit") })

        // 3 · Storage round-trips both columns, and retrieval reads them into the citation.
        let store = DocumentStore(directory: tempRoot)
        let ref = await store.ingest(name: "Fixture Manual", text: extracted.text, sourceType: "vault_document")
        XCTAssertNotNil(ref)

        let labelHits = store.passages(containingToken: "24VAXC")
        XCTAssertFalse(labelHits.isEmpty, "the drawing's labels have to stay reachable by exact token")
        XCTAssertTrue(labelHits.allSatisfy { $0.kind == .diagram && $0.figure == "Figure 3" }, "\(labelHits)")

        let retriever = VaultRetriever(query: { q, limit in store.query(q, limit: limit) },
                                       tokenSearch: { token, limit in store.passages(containingToken: token, limit: limit) },
                                       policy: RetrievalEvidencePolicy(similarityFloor: 0))
        let outcome = retriever.retrieve(.init(turn: "24VAXC", limit: 4))
        let diagram = try XCTUnwrap(outcome.passages.first { $0.kind == .diagram })
        XCTAssertEqual(diagram.citation, "Fixture Manual, page 2, Figure 3")
        XCTAssertEqual(diagram.kindLabel, "(wiring diagram, Figure 3, page 2)")
        XCTAssertTrue(VaultRetriever.promptBlock(outcome).contains("(wiring diagram, Figure 3, page 2)"),
                      VaultRetriever.promptBlock(outcome))

        // 4 · A semantic query never reaches the drawing — a bag of labels embeds to noise.
        try XCTSkipUnless(Embedder().isAvailable, "No NLEmbedding model available in this environment")
        let semantic = store.query("how do I turn off the gas to the unit", limit: 8)
        XCTAssertFalse(semantic.isEmpty)
        XCTAssertTrue(semantic.allSatisfy { $0.kind == .prose }, "\(semantic.map(\.text))")
        let prose = try XCTUnwrap(semantic.first { $0.section != nil })
        XCTAssertNil(prose.figure)
    }

    func testAPDFWhoseTypeCarriesNoStructureFallsBackToTheLexicalRules() throws {
        // One weight, one size — a re-typeset or recognised manual. Nothing to read off the type,
        // so nothing is marked, and EJ's lexical rules name the sections exactly as before.
        let url = makeTypedPDF([[Line("SAFETY PROCEDURES"),
                                 Line("Lock out the power before opening the blower compartment."),
                                 Line("Wait five minutes for any accumulated gas to clear the cabinet.")]])
        let extracted = try VaultDocumentExtractor.extract(from: url)
        XCTAssertEqual(extracted.structuredHeadings, 0)
        XCTAssertEqual(extracted.diagramPages, 0)
        XCTAssertFalse(extracted.text.contains("## "), extracted.text)
        XCTAssertFalse(DocumentChunker.hasStructuredHeadings(extracted.text))

        let chunks = DocumentChunker().chunk(extracted.text)
        XCTAssertTrue(chunks.contains { $0.text.contains("Lock out the power") }, "\(chunks)")
        XCTAssertTrue(chunks.contains { $0.section == "SAFETY PROCEDURES" }, "\(chunks)")
        XCTAssertTrue(chunks.allSatisfy { $0.kind == .prose && $0.figure == nil })
    }

    /// What the fixture's pages actually came out as, for when an assertion above fails.
    private func diagnostic(_ url: URL, _ text: String) -> String {
        guard let document = PDFDocument(url: url) else { return "unreadable fixture" }
        let typed = ManualStructure.typedPages(of: document)
        let body = ManualStructure.bodySize(of: typed.keys.sorted().compactMap { typed[$0] })
        let lines = (typed[0]?.lines ?? []).prefix(4)
            .map { "\($0.size)pt bold=\($0.bold) '\($0.text)'" }
            .joined(separator: "\n  ")
        return "body=\(body)\n  \(lines)\n---\n\(text.prefix(600))"
    }

    // MARK: - The rules, pure

    private func line(_ text: String, _ size: Double = 10, _ bold: Bool = true) -> ManualStructure.TypedLine {
        ManualStructure.TypedLine(raw: text, size: size, bold: bold)
    }

    func testHeadingShapeAcceptsPlacesAndRejectsEverythingElseSetInBold() {
        // A place in the book: bold, body size, mixed case or caps, no terminator.
        XCTAssertTrue(ManualStructure.isHeading(line("Turning Off Gas to Unit"), bodySize: 10))
        XCTAssertTrue(ManualStructure.isHeading(line("Pressure Switches (Two)", 12), bodySize: 10))
        XCTAssertTrue(ManualStructure.isHeading(line("BOTTOM RETURN AIR"), bodySize: 10))
        // Not a place.
        XCTAssertFalse(ManualStructure.isHeading(line("Turning Off Gas to Unit", 10, false), bodySize: 10),
                       "regular weight is body text")
        XCTAssertFalse(ManualStructure.isHeading(line("W1 LOW STAGE HEAT", 8), bodySize: 10), "below body size")
        XCTAssertFalse(ManualStructure.isHeading(line("FIGURE 58"), bodySize: 10))
        XCTAssertFalse(ManualStructure.isHeading(line("TABLE 16"), bodySize: 10))
        XCTAssertFalse(ManualStructure.isHeading(line("WARNING"), bodySize: 10))
        XCTAssertFalse(ManualStructure.isHeading(line("NOTICE"), bodySize: 10),
                       "the one banner these manuals set on a line of its own")
        XCTAssertFalse(ManualStructure.isHeading(line("NOTE - the blower runs on"), bodySize: 10))
        XCTAssertFalse(ManualStructure.isHeading(line("Close the manual gas valve before starting."), bodySize: 10))
        XCTAssertFalse(ManualStructure.isHeading(line("Before you begin:"), bodySize: 10))
        XCTAssertFalse(ManualStructure.isHeading(line("1"), bodySize: 10), "a callout number on a figure")
        XCTAssertFalse(ManualStructure.isHeading(line("1 2 3 4"), bodySize: 10))
        XCTAssertFalse(ManualStructure.isHeading(line("Page 44"), bodySize: 10), "the publisher's own header")
        XCTAssertFalse(ManualStructure.isHeading(line("(shown in upflow position)"), bodySize: 10),
                       "a qualifier belongs to the line above it")
        // The middle of a paragraph that happens to be set in bold, which is how this class of
        // manual sets its warnings.
        XCTAssertFalse(ManualStructure.isHeading(line("EQUIPMENT MAY EXPERIENCE PREMATURE COM-"), bodySize: 10))
        XCTAssertFalse(ManualStructure.isHeading(line("stallation in mobile homes, recreational vehicles or"), bodySize: 10))
        XCTAssertFalse(ManualStructure.isHeading(line(String(repeating: "Requirement ", count: 8)), bodySize: 10))
    }

    func testCaptionsAreToldFromCrossReferences() {
        XCTAssertEqual(ManualStructure.caption(line("FIGURE 58"))?.label, "Figure 58")
        XCTAssertEqual(ManualStructure.caption(line("TABLE 16."))?.label, "Table 16")
        let inline = ManualStructure.caption(line("FIGURE 58 Integrated Control"))
        XCTAssertEqual(inline?.label, "Figure 58")
        XCTAssertEqual(inline?.inlineTitle, "Integrated Control")
        XCTAssertNil(ManualStructure.caption(line("FIGURE 58", 10, false)), "a caption is set in bold")
        XCTAssertNil(ManualStructure.caption(line("See FIGURE 58 on page 44")))
        XCTAssertNil(ManualStructure.caption(line("FIGURE")))
        // Plan JJ P5: the label as printed, a letter beside the number included.
        let lettered = ManualStructure.caption(line("TABLE 95A Invented limits"))
        XCTAssertEqual(lettered?.label, "Table 95A")
        XCTAssertEqual(lettered?.inlineTitle, "Invented limits")
        XCTAssertEqual(ManualStructure.caption(line("TABLE Q7"))?.label, "Table Q7")
        let runOn = ManualStructure.caption(line("TABLE 16Wiring"))
        XCTAssertEqual(runOn?.label, "Table 16", "a letter run into a word is not the label's")
        XCTAssertEqual(runOn?.inlineTitle, "Wiring")
    }

    /// Plan JW P0: a revision mark in the margin on the caption's line, standing apart or glued to
    /// the word, does not hide the caption — the table extractor's own rule.
    func testAMarginMarkBeforeACaptionIsDropped() {
        let apart = ManualStructure.caption(line("\u{0394} TABLE 99 Widget ratings"))
        XCTAssertEqual(apart?.label, "Table 99")
        XCTAssertEqual(apart?.inlineTitle, "Widget ratings")
        XCTAssertEqual(ManualStructure.caption(line("\u{25B2}TABLE 98A"))?.label, "Table 98A", "glued to the word")
        XCTAssertEqual(ManualStructure.caption(line("| FIGURE 12 Example wiring"))?.label, "Figure 12", "a figure too")
        XCTAssertEqual(ManualStructure.caption(line("\u{25BA} \u{2022} TABLE 99"))?.label, "Table 99", "several marks")
        XCTAssertNil(ManualStructure.caption(line("\u{0394} TABLE 99", 10, false)), "still set in bold")
        XCTAssertNil(ManualStructure.caption(line("\u{25B2} See TABLE 99 on page 4")), "still a cross-reference")
        XCTAssertNil(ManualStructure.caption(line("\u{25B2}")))
        XCTAssertNil(ManualStructure.caption(line("(TABLE 99)")), "a bracket is not a mark")
    }

    func testAMarkedCaptionNamesItsPassage() {
        let page = ManualStructure.TypedPage(lines: [
            line("\u{0394} TABLE 99 Widget ratings"),
            line("Widget ratings are invented for this test and describe nothing real.", 10, false),
        ])
        let rendered = ManualStructure.render(page, bodySize: 10)
        XCTAssertTrue(rendered.text.hasPrefix("### Table 99 \u{2014} Widget ratings"), rendered.text)
    }

    func testABoldParagraphYieldsNoHeadingsButAnIsolatedLineDoes() {
        let lines = [line("DO NOT USE THE UNIT FOR CONSTRUCTION HEAT"),
                     line("UNLESS ALL OF THE FOLLOWING CRITERIA ARE MET"),
                     line("Units may be used for heating of buildings under construction.", 10, false),
                     line("Use of Furnace as Construction Heater"),
                     line("Units may be used if the following conditions are met.", 10, false)]
        XCTAssertFalse(ManualStructure.standsAlone(at: 0, in: lines, bodySize: 10))
        XCTAssertFalse(ManualStructure.standsAlone(at: 1, in: lines, bodySize: 10))
        XCTAssertTrue(ManualStructure.standsAlone(at: 3, in: lines, bodySize: 10))
        // The publisher's own running header, set in the same bold, sits above the first heading on
        // every page of these manuals. It must not swallow it.
        XCTAssertTrue(ManualStructure.standsAlone(at: 1, in: [line("Page 56"), line("BLOWER DATA"),
                                                              line("Bottom return air is listed below.", 10, false)],
                                                  bodySize: 10))
        let rendered = ManualStructure.render(.init(lines: lines), bodySize: 10)
        XCTAssertEqual(rendered.headings, 1)
        XCTAssertTrue(rendered.text.contains("## Use of Furnace as Construction Heater"), rendered.text)
    }

    func testAParentheticalQualifierMergesIntoTheHeadingAboveIt() {
        let rendered = ManualStructure.render(.init(lines: [
            line("PRESSURE SWITCH TUBING INSTALLATION"),
            line("(shown in upflow position)"),
            line("Route the tubing as shown before restoring power to the unit.", 10, false)
        ]), bodySize: 10)
        XCTAssertTrue(rendered.text.hasPrefix("## PRESSURE SWITCH TUBING INSTALLATION (shown in upflow position)"),
                      rendered.text)
        XCTAssertEqual(rendered.headings, 1)
    }

    func testADrawingIsTaggedAndItsCaptionNamesTheWholePage() {
        let lines = [line("Integrated Control", 8, false),
                     line("W1 LOW STAGE HEAT", 8, false),
                     line("FIGURE 58"),
                     line("TABLE 16 THERMOSTAT INPUT TERMINALS"),
                     line("C 24VAXC COMMON", 8, false),
                     line("1- DATA LOW CONNECTION", 8, false)]
        let page = ManualStructure.TypedPage(lines: lines)
        XCTAssertTrue(ManualStructure.isDiagramPage(page, bodySize: 10))
        let rendered = ManualStructure.render(page, bodySize: 10)
        // The page's own figure is written at the top, where every chunk of the page inherits it,
        // and written only once.
        XCTAssertEqual(rendered.text.components(separatedBy: "\n").prefix(2).joined(separator: "|"),
                       "\(ManualStructure.diagramMarker)|### Figure 58")
        XCTAssertEqual(rendered.text.components(separatedBy: "### Figure 58").count - 1, 1)
        XCTAssertTrue(rendered.text.contains("### Table 16 — THERMOSTAT INPUT TERMINALS"), rendered.text)

        // Prose at body size is never a drawing, at any threshold.
        let prose = ManualStructure.TypedPage(lines: (1...12).map {
            line("The inducer draws through the collector box on call \($0).", 10, false)
        })
        XCTAssertFalse(ManualStructure.isDiagramPage(prose, bodySize: 10))
        XCTAssertFalse(ManualStructure.render(prose, bodySize: 10).text.contains(ManualStructure.diagramMarker))
    }

    func testBodySizeIsTheDocumentsModeNotThePages() {
        let prose = ManualStructure.TypedPage(lines: (1...12).map {
            line("The inducer draws through the collector box on call \($0).", 10, false)
        })
        let drawing = ManualStructure.TypedPage(lines: (1...20).map { line("W\($0) LOW STAGE HEAT COMMON", 8) })
        // The drawing's own mode is 8; the document's is 10, which is what makes it a drawing.
        XCTAssertEqual(ManualStructure.bodySize(of: [drawing]), 8)
        XCTAssertEqual(ManualStructure.bodySize(of: [prose, drawing]), 10)
        XCTAssertTrue(ManualStructure.isDiagramPage(drawing, bodySize: 10))
        XCTAssertFalse(ManualStructure.isDiagramPage(drawing, bodySize: 8))
    }
}
