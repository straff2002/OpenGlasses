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
    /// A tester's job 1027: two manuals in one Source line, separated by a semicolon, were saved as
    /// one citation to a page the answer never named.
    func testASemicolonSeparatesTwoManuals() {
        let cited = CitationLineParser.parse(
            "Source: SLP99UHVK Installation Instructions, page 47; Service Manual, page 20.")
        XCTAssertEqual(cited.map(\.label),
                       ["SLP99UHVK Installation Instructions, page 47", "Service Manual, page 20"])
    }

    func testSemicolonSeparatedCoreFilesAreEachTheirOwn() {
        XCTAssertEqual(CitationLineParser.parse("Source: error_codes.md; service_values.md").map(\.label),
                       ["error_codes.md", "service_values.md"])
    }

    func testAPageAfterASemicolonKeepsItsTitle() {
        XCTAssertEqual(CitationLineParser.parse("Source: SLP99UHVK Service Manual, page 20; page 21").map(\.label),
                       ["SLP99UHVK Service Manual, page 20", "SLP99UHVK Service Manual, page 21"])
    }

    func testASecondPageForOneTitleIsASecondCitation() {
        XCTAssertEqual(CitationLineParser.parse("Source: SLP99UHVK Service Manual, page 20, page 47").map(\.label),
                       ["SLP99UHVK Service Manual, page 20", "SLP99UHVK Service Manual, page 47"])
    }

    func testAPageRangeKeepsBothEnds() throws {
        let cited = try XCTUnwrap(CitationLineParser.parse("Source: SLP99UHVK Service Manual, pages 64\u{2013}65").first)
        XCTAssertEqual(cited.page, 64)
        XCTAssertEqual(cited.throughPage, 65)
        XCTAssertEqual(cited.label, "SLP99UHVK Service Manual, pages 64\u{2013}65")
        XCTAssertEqual(CitationLineParser.parse("Source: Service Manual, pages 64-65").first?.throughPage, 65)
    }

    // MARK: - What an answer does with a citation (Plan KE)

    /// Two markers on one line used to make one title, which matched no manual.
    func testASecondMarkerStartsANewBody() {
        let line = "Source: D41 Acme Service Manual A123, page 12. Source: D02 Acme Install Guide B456, page 3"
        XCTAssertEqual(CitationLineParser.parse(line).map(\.label),
                       ["D41 Acme Service Manual A123, page 12", "D02 Acme Install Guide B456, page 3"])
        XCTAssertEqual(CitationLineParser.sourceBody(of: line), "D41 Acme Service Manual A123, page 12")
        XCTAssertEqual(CitationLineParser.sourceBodies(of: line).count, 2)
    }

    func testMarkersOfBothFormsAndCasesAreEachABody() {
        XCTAssertEqual(CitationLineParser.parse("Sources: Acme Manual A, page 1 SOURCE: Acme Manual B, page 2").map(\.label),
                       ["Acme Manual A, page 1", "Acme Manual B, page 2"])
    }

    func testTwoBracketedMarkersOnOneLine() {
        XCTAssertEqual(CitationLineParser.parse("Check it (Source: fault_codes.md) then this (Source: wiring.md).").map(\.title),
                       ["fault_codes.md", "wiring.md"])
    }

    func testABracketLaterInTheProseDoesNotCloseTheCitation() {
        XCTAssertEqual(CitationLineParser.parse("Clean it (Source: Acme Manual, page 4 (diagram)) and refit (the cover).").map(\.label),
                       ["Acme Manual, page 4 (diagram)"])
    }

    func testAWordEndingInSourceIsNotAMarker() {
        XCTAssertTrue(CitationLineParser.parse("Resources: two technicians").isEmpty)
    }

    func testTheScanNoteInEitherSpellingIsDropped() throws {
        for note in ["(text recognised from a scan; verify figures against the printed page)",
                     "(text recognized from a scan; verify figures against the printed page)",
                     "(Text Recognized from a scan)"] {
            let citation = try XCTUnwrap(CitationLineParser.parse("Source: Acme Scanned Manual, page 61 \(note)").first)
            XCTAssertEqual(citation.title, "Acme Scanned Manual", note)
            XCTAssertEqual(citation.page, 61, note)
        }
    }

    /// The whole line the report held: both markers, and the note in the spelling that was missed.
    func testTheReportedLineMakesTwoShortCitations() {
        let line = "Source: D41 Acme Service Manual A123, page 12. Source: D02 Acme Install Guide B456, "
            + "page 3 (text recognized from a scan; verify figures against the printed page)"
        let cited = CitationLineParser.parse(line)
        XCTAssertEqual(cited.map(\.page), [12, 3])
        XCTAssertTrue(cited.allSatisfy { $0.title.count < 40 }, "\(cited.map(\.title))")
    }

    func testProseAfterACitationIsNotATitle() {
        XCTAssertEqual(CitationLineParser.parse("Source: Acme Service Manual A123, page 9. The fan runs on start.").map(\.label),
                       ["Acme Service Manual A123, page 9"])
        XCTAssertEqual(CitationLineParser.parse(
            "Source: D03 Acme Manual, PDF page 20, Step 9. The manual's listed model coverage includes QX100, QX200").map(\.label),
                       ["D03 Acme Manual, page 20"])
        XCTAssertEqual(CitationLineParser.parse("Source: fault_codes.md. Check the fan next, then the relay.").map(\.label),
                       ["fault_codes.md"])
        XCTAssertEqual(CitationLineParser.parse("Source: Acme Manual, page 4, §Sensor Check. Measure it cold, page by page.").map(\.label),
                       ["Acme Manual, page 4, §Sensor Check"])
        XCTAssertEqual(CitationLineParser.parse("Source: Acme Manual, page 4, §3.9.4. Measure it cold.").first?.section, "3.9.4")
        XCTAssertEqual(CitationLineParser.parse("Source: Acme Manual, page 4, Figure 7. Typical wiring of the board.").map(\.label),
                       ["Acme Manual, page 4, Figure 7"])
    }

    func testAFullStopInsideATitleOrASectionIsNotASentenceEnd() {
        for line in ["Source: Acme Corp. Service Manual, page 3",
                     "Source: Service Bulletin No. A123, page 3",
                     "Source: Acme Manual Rev. 2, page 3",
                     "Source: Acme Manual Vol. II, page 3",
                     "Source: U.S. Standard Wiring Guide, page 3",
                     "Source: Acme QX100. Service Manual, page 3"] {
            let cited = CitationLineParser.parse(line)
            XCTAssertEqual(cited.count, 1, line)
            XCTAssertEqual(cited.first?.page, 3, line)
            XCTAssertEqual(cited.first?.label, String(line.dropFirst("Source: ".count)), line)
        }
        XCTAssertEqual(CitationLineParser.parse("Source: Acme Manual, page 3, §Sec. 4 Wiring").first?.section, "Sec. 4 Wiring")
        XCTAssertEqual(CitationLineParser.parse("Source: Acme Manual, pp. 64-65").first?.throughPage, 65)
        XCTAssertEqual(CitationLineParser.closingSentence("Acme Manual, page 4. Figure 58"), "Acme Manual, page 4. Figure 58",
                       "another place is not prose")
    }

    func testABuiltNameIsNotCutAtAFullStop() {
        let name = TeamLearningCitation.prefix + "Fan No. 2. Replace it · 2026-10-01 · approved by Lead"
        let cited = CitationLineParser.parse("Source: \(name)")
        XCTAssertEqual(cited.map(\.title), [name])
        XCTAssertEqual(cited.first?.kind, .teamLearning)
    }

    func testAPDFPageIsThePage() throws {
        let cited = try XCTUnwrap(CitationLineParser.parse("Source: D03 Acme Manual, PDF page 20 (printed page 2-6)").first)
        XCTAssertEqual(cited.title, "D03 Acme Manual")
        XCTAssertEqual(cited.page, 20)
        XCTAssertNil(cited.printedPage, "the PDF page is where it opens")
        XCTAssertEqual(cited.label, "D03 Acme Manual, page 20")
        XCTAssertEqual(CitationLineParser.parse("Source: Acme Manual, PDF pages 20-21").first?.throughPage, 21)
        XCTAssertEqual(CitationLineParser.parse("Source: Acme Manual, PDF p. 20").first?.page, 20)
    }

    func testAPDFPageWithNoCommaBeforeIt() {
        for line in ["Source: Acme Manual PDF page 20", "Source: Acme Manual (PDF page 20)",
                     "Source: Acme Manual (PDF page 20, printed page 14)"] {
            let cited = CitationLineParser.parse(line)
            XCTAssertEqual(cited.map(\.label), ["Acme Manual, page 20"], line)
        }
    }

    func testPrintedPagesAndStepsAreNeverACitation() {
        XCTAssertEqual(CitationLineParser.parse("Source: Acme Manual, PDF page 63, printed page 57, Step 4").map(\.label),
                       ["Acme Manual, page 63"])
        XCTAssertEqual(CitationLineParser.parse("Source: Acme Manual, page 63 (printed 57), Step 4").map(\.label),
                       ["Acme Manual, page 63"])
        XCTAssertTrue(CitationLineParser.parse("Source: printed page 57").isEmpty)
        XCTAssertTrue(CitationLineParser.parse("Source: Step 4").isEmpty)
        XCTAssertEqual(CitationLineParser.parse("Source: Acme Manual, page 3; Step 4").map(\.label), ["Acme Manual, page 3"])
    }

    func testATitleMayStartLikeAStep() {
        XCTAssertEqual(CitationLineParser.parse("Source: Step 4 Commissioning Checklist, page 2").map(\.label),
                       ["Step 4 Commissioning Checklist, page 2"])
    }

    /// With no PDF page, the label is all there is, and it must not read as the page to open.
    func testAPrintedPageOnItsOwnStaysAPrintedPage() throws {
        let cited = try XCTUnwrap(CitationLineParser.parse("Source: Acme Manual, printed page 2-6").first)
        XCTAssertNil(cited.page)
        XCTAssertEqual(cited.printedPage, "2-6")
        XCTAssertEqual(cited.label, "Acme Manual, printed page 2-6")
        XCTAssertEqual(CitationLineParser.parse("Source: \(cited.label)").first, cited, "a label reads back")
        XCTAssertEqual(CitationLineParser.parse("Source: Acme Manual, printed page 5, printed page 6").count, 1)
    }

    func testASecondPDFPageAfterASemicolonCarriesItsTitle() {
        XCTAssertEqual(CitationLineParser.parse("Source: D03 Acme Manual, PDF page 20 (printed page 2-6); PDF page 63 (printed page 57)").map(\.label),
                       ["D03 Acme Manual, page 20", "D03 Acme Manual, page 63"])
    }

    /// Pure and total: nothing a model writes makes it trap, and nothing is invented.
    func testItIsTotal() {
        for line in ["Source:", "Source: .", "Source: . . .", "(Source:", "(Source: )", "Source: (", "Source: )", "Source: ;;,,",
                     "Source: Source: Source:", "source:source:", "Source: printed page", "Source: PDF page", "Source: page",
                     "Source: §", "Source: Step", "Source: (text recognized", "Source: \u{2014}"] {
            XCTAssertTrue(CitationLineParser.parse(line).allSatisfy { !$0.title.isEmpty }, line)
        }
    }
}
