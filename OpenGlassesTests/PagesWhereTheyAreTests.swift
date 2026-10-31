import XCTest
@testable import OpenGlasses

/// Plan KE P2 — every page where it is. All manuals here are invented.

// MARK: - A chunk knows its pages

final class ChunkPageBreakTests: XCTestCase {

    private let wide = DocumentChunker(targetChars: 700, maxChars: 900, overlapChars: 0)

    private func offset(of needle: String, in text: String) throws -> Int {
        let range = try XCTUnwrap(text.range(of: needle), needle)
        return text.distance(from: text.startIndex, to: range.lowerBound)
    }

    func testAChunkOnOnePageHasNoBreaks() {
        XCTAssertEqual(wide.chunk("First sentence here. Second sentence here.")[0].pageBreaks, [])
        XCTAssertEqual(wide.chunk("Page 4\nFirst sentence here. Second sentence here.")[0].pageBreaks, [])
    }

    func testAChunkAcrossAPageSaysWhereEachPageStarts() throws {
        let chunk = try XCTUnwrap(wide.chunk("Open the service panel first.\u{0C}Then isolate the supply.").first)
        let second = try offset(of: "Then isolate", in: chunk.text)
        XCTAssertEqual(chunk.pageBreaks, [.init(offset: 0, page: 1), .init(offset: second, page: 2)])
    }

    func testASentenceThatRunsOverAPageIsCutWhereThePageTurns() throws {
        // A table's run of lines has no full stop, so the tokenizer reads straight through the page.
        let chunk = try XCTUnwrap(wide.chunk("Relay one closes and the timer\u{0C}runs until relay three opens").first)
        XCTAssertEqual(chunk.sentenceStarts.count, 1, "the fixture needs one sentence over the break")
        let turn = try offset(of: "runs until", in: chunk.text)
        XCTAssertEqual(chunk.pageBreaks, [.init(offset: 0, page: 1), .init(offset: turn, page: 2)])
    }

    func testABlankPageIsNoBreak() throws {
        let chunk = try XCTUnwrap(wide.chunk("Alpha check is done.\u{0C}  \n\u{0C}Bravo check is next.").first)
        XCTAssertEqual(chunk.pageBreaks.map(\.page), [1, 3])
    }

    func testThePagesAreOrderedWhateverPageTheChunkIsCitedAt() throws {
        let short = "A short tail."
        let long = String(repeating: "Most of this chunk sits on the second page. ", count: 6)
        let chunker = DocumentChunker(targetChars: 700, maxChars: 900, overlapChars: 0, creditsMajorityPage: true)
        let chunk = try XCTUnwrap(chunker.chunk(short + "\u{0C}" + long).first)
        XCTAssertEqual(chunk.page, 2, "cited at the page holding most of it")
        XCTAssertEqual(chunk.pageBreaks.map(\.page), [1, 2], "and still saying the start is on the first")
    }

    func testAnOversizedSentenceKeepsItsPagesPieceByPiece() {
        let words = (0..<60).map { "word\($0)" }.joined(separator: " ")
        let chunks = DocumentChunker(targetChars: 100, maxChars: 120, overlapChars: 0)
            .chunk(words + "\u{0C}" + words)
        XCTAssertGreaterThan(chunks.count, 2)
        XCTAssertEqual(chunks.first?.page, 1)
        XCTAssertEqual(chunks.last?.page, 2, "a piece past the page turn is on the next page")
        let across = chunks.filter { !$0.pageBreaks.isEmpty }
        XCTAssertLessThanOrEqual(across.count, 1, "only the piece that holds the turn has one")
    }

    func testAPhotographedPageHasNone() {
        let chunks = DocumentChunker(targetChars: 700, maxChars: 900, overlapChars: 0)
            .chunkPages([(number: 7, text: "Alpha sentence here.\u{0C}Bravo sentence here.")])
        XCTAssertEqual(chunks.map(\.page), [7])
        XCTAssertEqual(chunks[0].pageBreaks, [], "the source page is the page")
    }

    func testBreaksRoundTripThroughTheirStoredForm() {
        let breaks: [DocumentChunker.PageBreak] = [.init(offset: 0, page: 11), .init(offset: 412, page: 12)]
        XCTAssertEqual(DocumentChunker.PageBreak.encode(breaks), "0:11,412:12")
        XCTAssertEqual(DocumentChunker.PageBreak.decode("0:11,412:12"), breaks)
        XCTAssertEqual(DocumentChunker.PageBreak.decode(nil), [])
        XCTAssertEqual(DocumentChunker.PageBreak.decode(""), [])
        XCTAssertEqual(DocumentChunker.PageBreak.decode("x,3:4,5"), [.init(offset: 3, page: 4)], "what cannot be read is left out")
    }
}

// MARK: - A table row is not a heading

final class TableRowHeadingTests: XCTestCase {

    func testRowsOfATableAreNotHeadings() {
        for line in ["7 ON LOW ON ON", "12 AUTO Vent shut AUTO AUTO", "9 = Service Mode", "3 = 18 OR 28 Ltr",
                     "24 VAC", "12.5 VDC", "230 VAC, 50HZ", "30 Cu. Ft.", "6 WH",
                     "24 VDC is fed to the fan relay, holding it", "24 VAC at J4-2, closing the contact",
                     "24 VAC TESTED 24 VAC", "18 Ltr 20 Ltr 22 Ltr Rating Output", "1 2 TO PANEL"] {
            XCTAssertNil(DocumentChunker.detectHeading(line), line)
        }
    }

    func testGenuineNumberedHeadingsStay() {
        for line in ["4.2 Gas Piping", "12 Wiring", "12 WIRING", "1 Introduction", "5.3 Safety Requirements",
                     "3 Gas", "9 Control Board to Control Box", "24 VAC Supply", "12.5 VDC Distribution",
                     "24 VDC Load(s)", "230 VAC Power Supply and Distribution"] {
            XCTAssertEqual(DocumentChunker.detectHeading(line), line, line)
        }
    }

    func testCapitalsThatAreNoTitle() {
        for line in ["(DRAIN KIT NOT FITTED)", "Q 7 (MAX", "CLEAR THE TRAY BEFORE FILLING.", "HEATER FAULT. SEE THE LOG BOOK",
                     "Q X R B 40 6 F", "RD/BK RD/BK"] {
            XCTAssertNil(DocumentChunker.detectHeading(line), line)
        }
        XCTAssertEqual(DocumentChunker.detectHeading("BOTTOM RETURN AIR"), "BOTTOM RETURN AIR")
        XCTAssertEqual(DocumentChunker.detectHeading("(SAFETY) AND SERVICE"), "(SAFETY) AND SERVICE")
    }

    func testNumbersThatDoNotGoUpOnAPageAreAColumn() {
        let page = "Parts\n3 Fixed Shelf\n1 Door Bin\n1 Rail Clip\nRest of the page."
        XCTAssertEqual(DocumentChunker.tableLines(in: page), ["3 Fixed Shelf", "1 Door Bin", "1 Rail Clip"])
    }

    func testNumberedHeadingsGoingUpAreLeftAlone() {
        XCTAssertEqual(DocumentChunker.tableLines(in: "1 Scope\nSome words.\n2 Wiring\nMore words.\n12 Earthing"), [])
    }

    func testEachPageKeepsItsOwnCount() {
        // A book that starts its numbering again in a new part has not gone down on a page.
        XCTAssertEqual(DocumentChunker.tableLines(in: "1 Scope\n2 Wiring\u{0C}1 Scope Of Part Two\n2 Earthing"), [])
    }

    func testARunningFooterDoesNotBreakTheCount() {
        let pages = ["3 Wiring\nBody words.\n4 Earthing\n3 Wiring Notes", "Body words.\n3 Wiring Notes"]
        XCTAssertEqual(DocumentChunker.tableLines(in: pages.joined(separator: "\u{0C}")), [])
    }

    func testAValueIsNoNumberInTheCount() {
        let page = "24 VAC Supply\n24 VAC Load(s)\n12 VDC Supply"
        XCTAssertEqual(DocumentChunker.tableLines(in: page), [], "their numbers are volts")
    }

    func testAPageOfLabelsOpensNoSections() {
        let labels = (1...8).map { "PANEL \(["ALPHA", "BRAVO", "CHARLIE", "DELTA", "ECHO", "FOXTROT", "GOLF", "HOTEL"][$0 - 1])" }
        let found = DocumentChunker.tableLines(in: (["SERVICE CHECKS"] + labels).joined(separator: "\n"))
        XCTAssertEqual(found, Set(labels), "a title at the head of the page is still its title")
        XCTAssertEqual(DocumentChunker.tableLines(in: "WIRING\nSome words here.\nTESTING\nMore words here.\nCONTROLS"), [])
    }

    func testATableRowLeavesTheSectionWhereItWas() throws {
        let text = """
        Section 2:
        Service tests run in order.
        3 Fixed Shelf
        1 Door Bin
        7 ON LOW ON ON
        Vent Open is the next test.
        """
        let chunks = DocumentChunker(targetChars: 40, maxChars: 80, overlapChars: 0).chunk("Cover\u{0C}" + text)
        XCTAssertEqual(chunks.last?.section, "Section 2:")
    }

    func testAPageMovesToTheMajorityOnceARowNoLongerSplitsTheSection() throws {
        let tail = "This is the tail of the first page."
        let long = String(repeating: "Nearly all of this passage is printed on the second page. ", count: 5)
        let text = "Section 2:\n" + tail + "\n7 ON LOW ON ON\u{0C}" + long
        let chunker = DocumentChunker(targetChars: 700, maxChars: 900, overlapChars: 0, creditsMajorityPage: true)
        let chunk = try XCTUnwrap(chunker.chunk(text).first { $0.text.contains("Nearly all") })
        XCTAssertEqual(chunk.page, 2)
    }
}

// MARK: - The model sees the break

final class PageMarkPromptTests: XCTestCase {

    private func passage(_ text: String = "Close the valve. Open the vent.", page: Int? = 11,
                         breaks: [DocumentChunker.PageBreak] = [.init(offset: 0, page: 11), .init(offset: 17, page: 12)],
                         printed: [Int: String] = [:]) -> VaultRetriever.Passage {
        VaultRetriever.Passage(documentId: "d", documentName: "Acme Service Manual A123", chunkIndex: 0, text: text,
                               page: page, section: "Wiring", similarity: 0.9, score: 0.9, matchedTokens: [],
                               pageBreaks: breaks, printedLabels: printed)
    }

    func testTheMarkGoesAtEachBreak() {
        XCTAssertEqual(passage().markedText, "[page 11] Close the valve. [page 12] Open the vent.")
    }

    func testAMarkSaysWhatIsPrinted() {
        let marked = passage(printed: [11: "3-3", 12: "3-4"]).markedText
        XCTAssertEqual(marked, "[page 11 (printed 3-3)] Close the valve. [page 12 (printed 3-4)] Open the vent.")
    }

    func testAPassageOnOnePageReadsAsItAlwaysDid() {
        let plain = passage(breaks: [])
        XCTAssertEqual(plain.markedText, plain.text)
        XCTAssertEqual(plain.citation, "Acme Service Manual A123, page 11, §Wiring")
        XCTAssertEqual(VaultRetriever.passageLine(0, plain), "[1] \(plain.text)\nSource: \(plain.citation)")
    }

    func testABreakPastTheTextIsLeftOut() {
        let odd = passage(breaks: [.init(offset: 0, page: 11), .init(offset: 900, page: 12)])
        XCTAssertEqual(odd.markedText, "[page 11] Close the valve. Open the vent.")
    }

    func testTheCitationGivesTheRangeAndTheParserReadsIt() throws {
        let line = "Source: " + passage().citation
        XCTAssertEqual(line, "Source: Acme Service Manual A123, pages 11\u{2013}12, §Wiring")
        let citation = try XCTUnwrap(CitationLineParser.parse(line).first)
        XCTAssertEqual(citation.page, 11)
        XCTAssertEqual(citation.throughPage, 12)
        XCTAssertEqual(citation.section, "Wiring")
    }

    func testAMajorityPageStillGivesTheWholeRange() {
        XCTAssertTrue(passage(page: 12).citation.contains("pages 11\u{2013}12"))
    }

    func testADrawingAcrossPagesParsesToo() throws {
        var drawing = passage()
        drawing.kind = .diagram
        drawing.figure = nil
        let citation = try XCTUnwrap(CitationLineParser.parse("Source: " + drawing.citation).first)
        XCTAssertEqual(citation.throughPage, 12)
        XCTAssertTrue(citation.isDiagram)
    }

    func testAnAnswerCitingTheMarkedPageParses() throws {
        let citation = try XCTUnwrap(CitationLineParser.parse("Source: Acme Service Manual A123, page 12, §Wiring").first)
        XCTAssertEqual(citation.page, 12)
        XCTAssertNil(citation.throughPage)
    }

    func testThePromptCarriesTheMarksAndTheRule() {
        let block = VaultRetriever.promptBlock(.sufficient([passage()]))
        XCTAssertTrue(block.contains("[page 12] Open the vent."), block)
        XCTAssertTrue(block.contains(VaultRetriever.pageMarkRule), block)
        let tool = VaultRetriever.toolResult(.sufficient([passage()]), query: "vent")
        XCTAssertTrue(tool.contains("[page 12] Open the vent."), tool)
        XCTAssertTrue(tool.contains(VaultRetriever.pageMarkRule), tool)
    }

    func testNoRuleWithoutAMark() {
        XCTAssertFalse(VaultRetriever.promptBlock(.sufficient([passage(breaks: [])])).contains(VaultRetriever.pageMarkRule))
    }

    func testTheBudgetAndTheOutcomeKeepTheStoredText() {
        let long = passage(String(repeating: "x", count: 300))
        let cost = long.text.utf8.count + long.citation.utf8.count + 256
        XCTAssertEqual(VaultRetriever.boundedOutcome(.sufficient([long]), characterLimit: cost).notice, "")
        XCTAssertFalse(VaultRetriever.boundedOutcome(.sufficient([long]), characterLimit: cost - 1).notice.isEmpty)
        XCTAssertEqual(VaultRetriever.boundedOutcome(.sufficient([long]), characterLimit: cost).outcome.passages.first?.text, long.text)
        XCTAssertFalse(passage().text.contains("[page"), "a mark is added on the way to the model, never stored")
    }

    func testTheAllowanceHoldsWhatTheMarksAdd() {
        let spanning = passage(printed: [11: "A-1234", 12: "A-1235"])
        let added = spanning.markedText.utf8.count - spanning.text.utf8.count
        XCTAssertLessThan(added, 256, "the passage's overhead in the budget covers its marks")
    }
}

// MARK: - A passage across pages, on the page

final class PassageAcrossPagesTests: XCTestCase {

    private let onEleven = "Close the valve before starting."
    private let onTwelve = "Open the vent and wait a full minute."
    private var text: String { onEleven + " " + onTwelve }

    private func anchor(page: Int = 11, breaks: [DocumentChunker.PageBreak]? = nil) -> PassageAnchor {
        PassageAnchor(documentId: "d", chunkIndex: 0, text: text, page: page, sentenceStarts: [0, onEleven.count + 1],
                      pageBreaks: breaks ?? [.init(offset: 0, page: 11), .init(offset: onEleven.count + 1, page: 12)])
    }

    func testAnAnchorCoversTheBreaksPagesOrItsOwn() {
        XCTAssertTrue(anchor().covers(12))
        XCTAssertFalse(anchor().covers(13))
        XCTAssertTrue(anchor(breaks: []).covers(11))
        XCTAssertFalse(anchor(breaks: []).covers(12))
    }

    func testItsSentencesAreReadAPageAtATime() {
        XCTAssertEqual(anchor().sentences(onPage: 11), [onEleven])
        XCTAssertEqual(anchor().sentences(onPage: 12), [onTwelve])
        XCTAssertEqual(anchor().sentences(onPage: 13), [])
    }

    func testASentenceOverTheBreakIsFoundOnBothSides() {
        let run = "Relay one closed Relay two open"
        let cut = PassageAnchor(documentId: "d", chunkIndex: 0, text: run, page: 1, sentenceStarts: [0],
                                pageBreaks: [.init(offset: 0, page: 1), .init(offset: 17, page: 2)])
        XCTAssertEqual(cut.sentences(onPage: 1), ["Relay one closed"])
        XCTAssertEqual(cut.sentences(onPage: 2), ["Relay two open"])
    }

    func testEachPageMarksItsOwnPart() {
        let cited = [CitedPassage(number: 1, anchor: anchor())]
        let first = PassageMarks(passages: cited, page: 11, pageText: "Header\n" + onEleven + "\nFooter")
        XCTAssertEqual(first.located.count, 1)
        XCTAssertNil(first.unmarkedLine, "the rest of it is on the next page, which is no failure")
        let second = PassageMarks(passages: cited, page: 12, pageText: onTwelve)
        XCTAssertEqual(second.located.count, 1)
        XCTAssertFalse(PassageMarks(passages: cited, page: 13, pageText: "Anything").hasPassages)
    }

    func testAHighlightIsNotStretchedOverAnotherPagesWords() {
        let cited = [CitedPassage(number: 1, anchor: anchor())]
        let marks = PassageMarks(passages: cited, page: 12, pageText: onEleven + " " + onTwelve)
        XCTAssertEqual(marks.located.first?.location.ranges.first?.location, onEleven.count + 1,
                       "only this page's part is looked for")
    }

    func testARowFromBeforeTheBreaksIsReadAsItWas() {
        let old = anchor(breaks: [])
        XCTAssertEqual(old.sentences(onPage: 11), [onEleven, onTwelve])
        XCTAssertEqual(PassageLocator.locate(old, onPage: 11, pageText: text).ranges.count,
                       PassageLocator.locate(old, onPageText: text).ranges.count)
    }

    // MARK: Which page of a range opens

    private func pages(_ dictionary: [Int: String]) -> (Int) -> String? { { dictionary[$0] } }

    func testARangeOpensAtThePageHoldingMostOfThePassage() {
        let place = CitedPagePlacement.place([CitedPassage(number: 1, anchor: anchor())], among: 11...12,
                                             pageText: pages([11: onEleven, 12: onTwelve]))
        XCTAssertEqual(place.page, 12, "the longer part")
    }

    func testAnEvenSplitOpensTheEarlier() {
        let even = PassageAnchor(documentId: "d", chunkIndex: 0, text: "Alpha sentence here. Bravo sentence here.",
                                 page: 11, sentenceStarts: [0, 21],
                                 pageBreaks: [.init(offset: 0, page: 11), .init(offset: 21, page: 12)])
        let place = CitedPagePlacement.place([CitedPassage(number: 1, anchor: even)], among: 11...12,
                                             pageText: pages([11: "Alpha sentence here.", 12: "Bravo sentence here."]))
        XCTAssertEqual(place.page, 11)
    }

    func testAPassageOnNoPageOfTheRangeOpensTheFirstAndSaysSo() {
        let place = CitedPagePlacement.place([CitedPassage(number: 1, anchor: anchor())], among: 11...12,
                                             pageText: pages([11: "Something else entirely.", 12: "And again."]))
        XCTAssertEqual(place.page, 11)
        let marks = PassageMarks(passages: place.passages, page: place.page, pageText: "Something else entirely.")
        XCTAssertEqual(marks.unmarkedLine, "The passage couldn't be marked on this page.")
    }

    func testAPassageOutsideARangeTheModelWroteStillSaysSo() {
        let outside = anchor(breaks: [])
        let place = CitedPagePlacement.place([CitedPassage(number: 1, anchor: outside)], among: 30...31,
                                             pageText: pages([30: "Nothing here.", 31: "Nor here."]))
        XCTAssertEqual(place.page, 30)
        let marks = PassageMarks(passages: place.passages, page: 30, pageText: "Nothing here.")
        XCTAssertNotNil(marks.unmarkedLine, "not the silent page it would be on an anchor for page 11")
    }

    func testARowWithNoBreaksIsFoundOnAnyPageOfTheRange() {
        let old = PassageAnchor(documentId: "d", chunkIndex: 0, text: onTwelve, page: 11, sentenceStarts: [0])
        let place = CitedPagePlacement.place([CitedPassage(number: 1, anchor: old)], among: 11...12,
                                             pageText: pages([11: onEleven, 12: onTwelve]))
        XCTAssertEqual(place.page, 12)
        XCTAssertEqual(PassageMarks(passages: place.passages, page: 12, pageText: onTwelve).located.count, 1)
    }

    func testARangeOfAWholeBookIsNotOpened() {
        var asked = 0
        _ = PassageLocator.page(holding: [anchor()], among: 1...500) { _ in asked += 1; return "x" }
        XCTAssertEqual(asked, PassageLocator.maximumRangePages)
    }

    @MainActor
    func testAPageCanBeMarkedWithoutItsPassageBeingStaged() {
        // `ShowSourceTool.check`: a passage across two pages found on the other one stays out of the
        // page's marks and is counted, as any passage found elsewhere would be.
        let cited = [CitedPassage(number: 1, anchor: anchor()),
                     CitedPassage(number: 2, anchor: PassageAnchor(documentId: "d", chunkIndex: 1, text: "Another line altogether is here.", page: 12))]
        let checked = ShowSourceTool.check(cited, page: 12, pageText: onTwelve)
        XCTAssertEqual(checked.state, .marked)
        XCTAssertEqual(checked.kept.map(\.number), [1])
        XCTAssertEqual(checked.unmarkedText, 1)
    }
}

// MARK: - What an answer cited

final class AnswerSourcesAcrossPagesTests: XCTestCase {

    private func retrieved(page: Int?, breaks: [DocumentChunker.PageBreak] = []) -> AnswerSourceMemory.Retrieved {
        .init(documentId: "d", documentName: "Acme Manual", chunkIndex: 0, page: page, section: nil, text: "x", pageBreaks: breaks)
    }

    private let across: [DocumentChunker.PageBreak] = [.init(offset: 0, page: 11), .init(offset: 5, page: 12)]

    func testAPageMarkedInsideAChunkFindsThatChunk() {
        var memory = AnswerSourceMemory()
        memory.noteRetrieved([retrieved(page: 11, breaks: across)], sessionId: "s")
        XCTAssertEqual(memory.retrieved(for: Citation(kind: .manual, title: "Acme Manual", page: 12)).count, 1,
                       "the model was told to cite page 12, and the chunk says page 11")
    }

    func testAPageOutsideItDoesNot() {
        var memory = AnswerSourceMemory()
        memory.noteRetrieved([retrieved(page: 11, breaks: across)], sessionId: "s")
        XCTAssertTrue(memory.retrieved(for: Citation(kind: .manual, title: "Acme Manual", page: 13)).isEmpty)
    }

    private func clausePassage(page: Int, breaks: [DocumentChunker.PageBreak]) -> AnswerSourceMemory.Retrieved {
        .init(documentId: "d", documentName: "Acme Manual", chunkIndex: 0, page: page, section: "3.9.4 Underground wiring",
              text: "Cover the cable with sand. The next clause follows.", pageBreaks: breaks)
    }

    private func memory(citing pages: [Int], passage: AnswerSourceMemory.Retrieved) -> AnswerSourceMemory {
        var memory = AnswerSourceMemory()
        memory.noteRetrieved([passage], sessionId: "s")
        memory.noteAnswer(pages.map { Citation(kind: .manual, title: "Acme Manual", page: $0) }, sessionId: "s")
        return memory
    }

    func testAClauseOpensAtTheChunksPageNotTheOneItRunsOnto() {
        let held = memory(citing: [11, 12], passage: clausePassage(page: 11, breaks: across))
        guard case .sources(let found) = ShowSourceResolver.resolve(which: "clause 3.9.4", document: nil, memory: held) else {
            return XCTFail("the clause was cited")
        }
        XCTAssertEqual(found.map(\.citation.page), [11])
    }

    func testTheOtherPageStandsInWhenItIsAllTheAnswerCited() {
        let held = memory(citing: [12], passage: clausePassage(page: 11, breaks: across))
        guard case .sources(let found) = ShowSourceResolver.resolve(which: "clause 3.9.4", document: nil, memory: held) else {
            return XCTFail("the model cited the mark inside the chunk")
        }
        XCTAssertEqual(found.map(\.citation.page), [12])
    }

    func testALookupStandsInWithTheRange() {
        var memory = AnswerSourceMemory()
        memory.noteLookup([retrieved(page: 12, breaks: across)], sessionId: "s")
        XCTAssertEqual(memory.citations.map(\.label), ["Acme Manual, pages 11\u{2013}12"])
    }
}

// MARK: - Pages add up

final class TurnPageStackTests: XCTestCase {

    private func figure(_ page: Int, _ document: String = "d") -> FieldSessionService.StagedFigure {
        .init(documentId: document, documentTitle: "Acme Manual", page: page)
    }

    func testPagesAddUpOldestFirst() {
        var stack = TurnPageStack()
        _ = stack.adding(figure(1), turn: "t")
        XCTAssertEqual(stack.adding(figure(2), turn: "t").map(\.page), [1, 2])
    }

    func testANewTurnStartsFresh() {
        var stack = TurnPageStack()
        _ = stack.adding(figure(1), turn: "t")
        XCTAssertEqual(stack.adding(figure(2), turn: "u").map(\.page), [2])
    }

    func testAPageAskedForAgainMovesToTheEnd() {
        var stack = TurnPageStack()
        _ = stack.adding(figure(1), turn: "t")
        _ = stack.adding(figure(2), turn: "t")
        XCTAssertEqual(stack.adding(figure(1), turn: "t").map(\.page), [2, 1])
    }

    func testTheSamePageOfAnotherBookIsAnotherPage() {
        var stack = TurnPageStack()
        _ = stack.adding(figure(1), turn: "t")
        XCTAssertEqual(stack.adding(figure(1, "e"), turn: "t").map(\.documentId), ["d", "e"])
    }

    func testTheOldestGoesPastWhatASheetHolds() {
        var stack = TurnPageStack()
        var pages: [FieldSessionService.StagedFigure] = []
        for page in 1...(ShowSourceResolver.maximumPages + 2) { pages = stack.adding(figure(page), turn: "t") }
        XCTAssertEqual(pages.count, ShowSourceResolver.maximumPages)
        XCTAssertEqual(pages.first?.page, 3)
        XCTAssertEqual(pages.last?.page, ShowSourceResolver.maximumPages + 2)
    }
}
