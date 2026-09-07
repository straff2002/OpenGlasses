import XCTest
@testable import OpenGlasses

/// Plan EK P3 — the parser that turns an answer's `Source:` lines back into the pages they name.
///
/// The shapes tested here are the ones the app itself produces: `VaultRetriever.Passage.citation`
/// on its own line, and a vault tool's trailing `(Source: …)`. A chip that opened the wrong page
/// would be worse than no chip, so the cases that must produce *nothing* are as load-bearing as the
/// ones that must produce a citation.
final class CitationLineParserTests: XCTestCase {

    func testAPageOnItsOwn() throws {
        let citations = CitationLineParser.parse("The blower door must be closed.\nSource: SLP99UHVK Service Manual, page 12")
        XCTAssertEqual(citations.count, 1)
        let citation = try XCTUnwrap(citations.first)
        XCTAssertEqual(citation.kind, .manual)
        XCTAssertEqual(citation.title, "SLP99UHVK Service Manual")
        XCTAssertEqual(citation.page, 12)
        XCTAssertNil(citation.figure)
        XCTAssertNil(citation.section)
        XCTAssertEqual(citation.label, "SLP99UHVK Service Manual, page 12")
    }

    func testASectionAndACaptionAreKeptApart() throws {
        let section = try XCTUnwrap(CitationLineParser.parse("Source: SLP99UHVK Service Manual, page 29, §Soft Disable").first)
        XCTAssertEqual(section.section, "Soft Disable")
        XCTAssertNil(section.figure)
        XCTAssertEqual(section.label, "SLP99UHVK Service Manual, page 29, §Soft Disable")

        let figure = try XCTUnwrap(CitationLineParser.parse("Source: SLP99UHVK Installation Instructions, page 44, Figure 58").first)
        XCTAssertEqual(figure.figure, "Figure 58")
        XCTAssertNil(figure.section)
        XCTAssertEqual(figure.page, 44)

        let table = try XCTUnwrap(CitationLineParser.parse("Source: SLP99UHVK Service Manual, page 29, Table 19").first)
        XCTAssertEqual(table.figure, "Table 19")
    }

    func testADrawingWithNoCaption() throws {
        let citation = try XCTUnwrap(CitationLineParser.parse("Source: SLP99UHVK Installation Instructions, page 44 (diagram)").first)
        XCTAssertEqual(citation.page, 44)
        XCTAssertTrue(citation.isDiagram)
        XCTAssertEqual(citation.label, "SLP99UHVK Installation Instructions, page 44 (diagram)")
    }

    func testAManualWithNoPage() throws {
        let citation = try XCTUnwrap(CitationLineParser.parse("Source: RTU-500 Service Manual").first)
        XCTAssertEqual(citation.kind, .manual)
        XCTAssertNil(citation.page)
        XCTAssertEqual(citation.label, "RTU-500 Service Manual")
    }

    func testTheToolsTrailingCoreFileSuffix() {
        let citations = CitationLineParser.parse(
            "R-410A at 118 psig is about 40°F saturated. (Source: pt_charts.md, superheat_subcool.md)")
        XCTAssertEqual(citations.map(\.title), ["pt_charts.md", "superheat_subcool.md"])
        XCTAssertTrue(citations.allSatisfy { $0.kind == .coreFile })
        XCTAssertTrue(citations.allSatisfy { $0.page == nil })
    }

    func testACoreFileWithTheSectionAModelNamed() throws {
        let citation = try XCTUnwrap(CitationLineParser.parse("Source: error_codes.md, §Acme RTU-500").first)
        XCTAssertEqual(citation.kind, .coreFile)
        XCTAssertEqual(citation.title, "error_codes.md")
        XCTAssertEqual(citation.section, "Acme RTU-500")
    }

    func testSeveralSourceLinesInOneAnswerAndNoDuplicates() {
        let answer = """
        E223 is a flame-sense fault.
        Source: SLP99UHVK Service Manual, page 20, §Diagnostic Codes

        The wiring for the flame sensor is on the integrated control.
        Source: SLP99UHVK Installation Instructions, page 44, Figure 58
        Source: SLP99UHVK Service Manual, page 20, §Diagnostic Codes
        """
        let citations = CitationLineParser.parse(answer)
        XCTAssertEqual(citations.count, 2, "the repeated line is the same door")
        XCTAssertEqual(citations.map(\.page), [20, 44])
    }

    func testAnAnswerWithNoSources() {
        XCTAssertTrue(CitationLineParser.parse("").isEmpty)
        XCTAssertTrue(CitationLineParser.parse(RetrievalEvidencePolicy.insufficientSentence).isEmpty)
        XCTAssertTrue(CitationLineParser.parse("I can't tell from the manuals loaded here.").isEmpty)
        XCTAssertTrue(CitationLineParser.parse("Source: none").isEmpty, "a model with nothing to cite opens no door")
        XCTAssertTrue(CitationLineParser.parse("Source:   ").isEmpty)
    }

    func testTheScanProvenanceNoteIsNotPartOfTheDocumentsName() throws {
        let line = "Source: Scanned RTU Manual, page 61, §Sensor Resistance "
            + VaultRetriever.Passage.provenanceNote
        let citation = try XCTUnwrap(CitationLineParser.parse(line).first)
        XCTAssertEqual(citation.title, "Scanned RTU Manual")
        XCTAssertEqual(citation.section, "Sensor Resistance")
        XCTAssertEqual(citation.page, 61)
    }

    func testItReadsWhatTheRetrieverWrites() {
        // The parser's real contract: whatever `Passage.citation` renders, the parser reads back.
        let passages = [
            VaultRetriever.Passage(documentId: "d", documentName: "SLP99UHVK Service Manual", chunkIndex: 0,
                                   text: "…", page: 29, section: "Soft Disable", similarity: 0.9, score: 0.9,
                                   matchedTokens: [], kind: .prose, figure: "Table 19"),
            VaultRetriever.Passage(documentId: "d", documentName: "SLP99UHVK Installation Instructions", chunkIndex: 1,
                                   text: "…", page: 44, section: nil, similarity: 0.9, score: 0.9,
                                   matchedTokens: [], kind: .diagram, figure: "Figure 58"),
            VaultRetriever.Passage(documentId: "d", documentName: "SLP99UHVK Installation Instructions", chunkIndex: 2,
                                   text: "…", page: 45, section: nil, similarity: 0.9, score: 0.9,
                                   matchedTokens: [], kind: .diagram, figure: nil)
        ]
        for passage in passages {
            let parsed = CitationLineParser.parse("Source: \(passage.citation)")
            XCTAssertEqual(parsed.count, 1, passage.citation)
            XCTAssertEqual(parsed.first?.label, passage.citation)
            XCTAssertEqual(parsed.first?.page, passage.page)
        }
    }

    func testCoreFileNamesAreToldFromManualTitles() {
        XCTAssertTrue(CitationLineParser.isCoreFileName("error_codes.md"))
        XCTAssertTrue(CitationLineParser.isCoreFileName("notes.txt"))
        XCTAssertFalse(CitationLineParser.isCoreFileName("SLP99UHVK Service Manual"))
        XCTAssertFalse(CitationLineParser.isCoreFileName("RTU-500"), "a model number is not a file")
    }

    func testAWholeSentenceIsNotADocument() {
        let tooLong = String(repeating: "a", count: CitationLineParser.maxTitleLength + 1)
        XCTAssertTrue(CitationLineParser.parse("Source: \(tooLong)").isEmpty)
    }
}
