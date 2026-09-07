import XCTest
@testable import OpenGlasses

final class DocumentChunkerTests: XCTestCase {

    func testEmptyAndWhitespaceProduceNoChunks() {
        let chunker = DocumentChunker()
        XCTAssertTrue(chunker.chunk("").isEmpty)
        XCTAssertTrue(chunker.chunk("   \n\t  ").isEmpty)
    }

    func testShortTextIsASingleChunk() {
        let chunker = DocumentChunker()
        let chunks = chunker.chunk("Hello world. This is a short note.")
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].index, 0)
        XCTAssertTrue(chunks[0].text.contains("Hello world"))
        XCTAssertTrue(chunks[0].text.contains("short note"))
    }

    func testLongTextSplitsIntoContiguousIndexedChunks() {
        let chunker = DocumentChunker(targetChars: 120, maxChars: 160, overlapChars: 30)
        // 20 distinct sentences, each ~30 chars → must span several chunks.
        let text = (1...20).map { "This is sentence number \($0) here." }.joined(separator: " ")
        let chunks = chunker.chunk(text)

        XCTAssertGreaterThan(chunks.count, 1)
        // Indices are contiguous from 0.
        XCTAssertEqual(chunks.map(\.index), Array(0..<chunks.count))
        // No chunk wildly exceeds the cap (allow small slack for the join separator).
        for c in chunks {
            XCTAssertLessThanOrEqual(c.text.count, chunker.maxChars + 4, "Chunk too large: \(c.text.count)")
        }
    }

    func testOverlapRepeatsTrailingSentenceIntoNextChunk() {
        let chunker = DocumentChunker(targetChars: 100, maxChars: 140, overlapChars: 40)
        let text = (1...12).map { "Sentence \($0) text padding." }.joined(separator: " ")
        let chunks = chunker.chunk(text)
        XCTAssertGreaterThan(chunks.count, 1)

        // Each chunk after the first should share some leading content with the previous chunk's tail.
        for i in 1..<chunks.count {
            let prevWords = Set(chunks[i - 1].text.split(separator: " "))
            let curWords = chunks[i].text.split(separator: " ")
            let sharedAtStart = curWords.prefix(4).contains { prevWords.contains($0) }
            XCTAssertTrue(sharedAtStart, "Chunk \(i) should overlap previous chunk")
        }
    }

    func testGiantSingleSentenceIsHardSplit() {
        let chunker = DocumentChunker(targetChars: 200, maxChars: 250, overlapChars: 20)
        // One "sentence" with no terminal punctuation, far larger than maxChars.
        let giant = String(repeating: "word ", count: 200).trimmingCharacters(in: .whitespaces)
        let chunks = chunker.chunk(giant)

        XCTAssertGreaterThan(chunks.count, 1)
        for c in chunks {
            XCTAssertLessThanOrEqual(c.text.count, chunker.maxChars)
        }
    }

    func testDeterministic() {
        let chunker = DocumentChunker(targetChars: 150, maxChars: 200, overlapChars: 40)
        let text = (1...15).map { "Repeatable sentence \($0)." }.joined(separator: " ")
        XCTAssertEqual(chunker.chunk(text), chunker.chunk(text))
    }

    // MARK: - Heading & page detection

    func testDetectHeadingRecognisesSectionForms() {
        XCTAssertEqual(DocumentChunker.detectHeading("5.3 Safety Requirements"), "5.3 Safety Requirements")
        XCTAssertEqual(DocumentChunker.detectHeading("12.1.2 Procedures"), "12.1.2 Procedures")
        XCTAssertEqual(DocumentChunker.detectHeading("Chapter 12"), "Chapter 12")
        XCTAssertEqual(DocumentChunker.detectHeading("SAFETY PROCEDURES"), "SAFETY PROCEDURES")
        // A plain numbered heading survives the list-step screen: that rule keys on the separator
        // after the number, not on the number itself.
        XCTAssertEqual(DocumentChunker.detectHeading("1 Introduction"), "1 Introduction")
        XCTAssertEqual(DocumentChunker.detectHeading("4.2 Gas Piping"), "4.2 Gas Piping")
        // A multi-word all-letter title is a real place in a furnace manual, so it stays.
        XCTAssertEqual(DocumentChunker.detectHeading("BOTTOM RETURN AIR"), "BOTTOM RETURN AIR")
    }

    func testDetectHeadingRejectsOrdinaryAndTooShortLines() {
        XCTAssertNil(DocumentChunker.detectHeading("This is a normal sentence."))
        XCTAssertNil(DocumentChunker.detectHeading("abc"))                 // < 4 chars
        XCTAssertNil(DocumentChunker.detectHeading("the quick brown fox")) // lowercase, unnumbered
        // Mixed case and unnumbered: the ALL-CAPS rule does not reach it, so it is not a heading.
        XCTAssertNil(DocumentChunker.detectHeading("Heating Sequence of Operation"))
    }

    /// Every line an OEM furnace manual printed that the old detector mistook for a section, and
    /// that therefore appeared in a spoken citation as "§FIGURE 5" or "§7 - Inspect the condensate…".
    func testDetectHeadingRejectsManualFurniture() {
        let furniture = [
            "FIGURE 5",                                                 // caption
            "TABLE 22.",                                                // caption
            "WARNING",                                                  // safety banner
            "CAUTION",
            "IMPORTANT",
            "C 24VAXC COMMON",                                          // terminal designation
            "7 - Inspect the condensate drain and trap for leaks and",  // list step
            "16 - Mark and disconnect any remaining wiring to",         // list step
            "1) Remove the burner box cover",                           // list step
            "1 AFUE 98.1% 98.1% 98.2%",                                 // spec-table row
            "0.5 / 1.5 0.5 / 1.5 0.5 / 1.5",                            // spec-table row
            "3.5 / 10.0 3.5 / 10.0",                                    // spec-table row
            "2.6 or greater 2.5 or less 1.1",                           // spec-table row
            "1 hour soft lockout.",                                     // a sentence, numbered
            "090XV60C 20A26 20A88 20A89",                               // part-number columns
            "30 TABLE 30 on page 59 for allowable heating speeds."       // wrapped cross-reference
        ]
        for line in furniture {
            XCTAssertNil(DocumentChunker.detectHeading(line), "should not be a heading: \(line)")
        }
    }

    func testDetectHeadingCapsLengthSoACitationCanBeSpoken() {
        let long = "5.4 " + String(repeating: "Requirement ", count: 10)
        XCTAssertGreaterThan(long.count, 80)
        XCTAssertNil(DocumentChunker.detectHeading(long))
        XCTAssertNotNil(DocumentChunker.detectHeading("5.4 Requirement " + String(repeating: "x", count: 60)))
    }

    func testPageNumberDetection() {
        XCTAssertEqual(DocumentChunker.pageNumber(in: "Page 42"), 42)
        XCTAssertEqual(DocumentChunker.pageNumber(in: "- 7 -"), 7)
        XCTAssertNil(DocumentChunker.pageNumber(in: "Page of contents"))
        XCTAssertNil(DocumentChunker.pageNumber(in: "ordinary text"))
        // A marker is the whole line. A wrapped table-of-contents entry is not a page break.
        XCTAssertNil(DocumentChunker.pageNumber(in: "Page 62 VII Typical Operating Characteristics"))
        XCTAssertNil(DocumentChunker.pageNumber(in: "Page 34 TEST B Use an ohmmeter"))
    }

    func testMarkerLinesAreStrippedFromChunkText() {
        // The extractor writes its own "Page N"; the publisher prints one too. Neither belongs in
        // a passage the model quotes back.
        let chunks = DocumentChunker().chunk("Page 3\n\nPage 3\nSome sentence.")
        XCTAssertEqual(chunks.count, 1)
        XCTAssertFalse(chunks[0].text.contains("Page 3"), chunks[0].text)
        XCTAssertEqual(chunks[0].text, "Some sentence.")
        XCTAssertEqual(chunks[0].page, 3)
    }

    func testPrintedHeaderDoesNotOverrideTheExtractorsPage() {
        // Mismatched numbering: extraction says page 5, the publisher's running header says 3.
        // The physical page wins — it is the one the reader can turn to.
        let text = "Page 5\nPage 3\nThe inducer draws through the collector box."
        let chunks = DocumentChunker().chunk(text)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].page, 5)
        XCTAssertFalse(chunks[0].text.contains("Page 3"), chunks[0].text)
    }

    func testEveryMarkerAfterContentTurnsThePage() {
        // Small target so each sentence lands in its own chunk and carries its own page.
        let chunker = DocumentChunker(targetChars: 30, maxChars: 60, overlapChars: 0)
        let text = """
        Page 5
        First body sentence on five.
        Second body sentence on five.
        Third body sentence on five.
        Page 6
        First body sentence on six.
        """
        let chunks = chunker.chunk(text)
        XCTAssertTrue(chunks.contains { $0.page == 5 && $0.text.contains("on five") }, "\(chunks)")
        XCTAssertTrue(chunks.contains { $0.page == 6 && $0.text.contains("on six") }, "\(chunks)")
        XCTAssertNil(chunks.first { $0.text.contains("Page 5") || $0.text.contains("Page 6") })
    }

    func testAOneLinePageStillTurnsThePage() {
        // The running-header rule must not swallow a real page break on a sparse document: one
        // line of content is enough to make the next marker a page turn.
        let chunker = DocumentChunker(targetChars: 40, maxChars: 80, overlapChars: 0)
        let text = "Page 1\n\nFault code ZX9 means low charge.\n\nPage 2\n\nThe switch opens at 610 psig."
        let chunks = chunker.chunk(text)
        XCTAssertTrue(chunks.contains { $0.page == 1 && $0.text.contains("ZX9") }, "\(chunks)")
        XCTAssertTrue(chunks.contains { $0.page == 2 && $0.text.contains("610 psig") }, "\(chunks)")
    }

    func testUnpaginatedTextLeavesPageAndSectionNil() {
        let chunks = DocumentChunker().chunk("Just some plain text. No pages here at all.")
        XCTAssertEqual(chunks.count, 1)
        XCTAssertNil(chunks[0].page)
        XCTAssertNil(chunks[0].section)
    }

    func testFormFeedAdvancesPageNumber() {
        let chunker = DocumentChunker(targetChars: 50, maxChars: 90, overlapChars: 0)
        let p1 = (1...4).map { "Page one sentence \($0)." }.joined(separator: " ")
        let p2 = (1...4).map { "Page two sentence \($0)." }.joined(separator: " ")
        let chunks = chunker.chunk(p1 + "\u{0C}" + p2)

        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(chunks.first?.page, 1)
        XCTAssertTrue(chunks.contains { $0.page == 2 }, "A chunk from the second page should be tagged page 2")
        // Paginated document → every chunk gets a page number, none nil.
        XCTAssertNil(chunks.first { $0.page == nil })
    }

    // MARK: - The structured grammar (Plan EK)

    func testMarkdownHeadingSetsTheSectionAndKeepsItsTextWithoutTheHashes() {
        let chunker = DocumentChunker(targetChars: 80, maxChars: 140, overlapChars: 0)
        let chunks = chunker.chunk("""
        Page 4

        ## Turning Off Gas to Unit

        Close the manual gas valve upstream of the union. Wait five minutes.
        """)
        XCTAssertTrue(chunks.allSatisfy { $0.section == "Turning Off Gas to Unit" }, "\(chunks)")
        XCTAssertTrue(chunks.contains { $0.text.contains("Turning Off Gas to Unit") },
                      "the heading is content and stays: \(chunks)")
        XCTAssertNil(chunks.first { $0.text.contains("#") }, "the hashes are not: \(chunks)")
        XCTAssertEqual(chunks.first?.page, 4)
    }

    func testFigureCaptionTagsFollowingChunksOfThePageAndResetsOnTheNext() {
        let chunker = DocumentChunker(targetChars: 60, maxChars: 120, overlapChars: 0)
        let chunks = chunker.chunk("""
        Page 44

        ### Figure 58 — Integrated Control

        Terminal W1 is the low stage heat call.

        Page 45

        The blower door switch opens when the door is removed.
        """)
        XCTAssertTrue(chunks.contains { $0.page == 44 && $0.figure == "Figure 58" }, "\(chunks)")
        XCTAssertTrue(chunks.contains { $0.text.contains("Figure 58 — Integrated Control") },
                      "the caption is content and stays: \(chunks)")
        // A figure belongs to its page: the next page starts clean.
        XCTAssertTrue(chunks.contains { $0.page == 45 })
        XCTAssertNil(chunks.first { $0.page == 45 && $0.figure != nil }, "\(chunks)")
        // A caption is not a section.
        XCTAssertNil(chunks.first { $0.section != nil }, "\(chunks)")
    }

    func testDiagramCommentTagsThePageAndItsFirstCaptionNamesTheWholePage() {
        let chunker = DocumentChunker(targetChars: 60, maxChars: 120, overlapChars: 0)
        let chunks = chunker.chunk("""
        Page 44

        <!-- page: diagram -->
        ### Figure 58

        W1 LOW STAGE HEAT
        ### Table 18 — QUICK CONNECT TERMINALS
        C 24VAXC COMMON

        Page 45

        The blower door switch opens when the door is removed.
        """)
        let drawing = chunks.filter { $0.page == 44 }
        XCTAssertFalse(drawing.isEmpty)
        XCTAssertTrue(drawing.allSatisfy { $0.kind == .diagram }, "\(drawing)")
        // Later captions on a drawing do not override it: the page is one picture, and the citation
        // has to name what the reader sees when they turn to it.
        XCTAssertTrue(drawing.allSatisfy { $0.figure == "Figure 58" }, "\(drawing)")
        XCTAssertTrue(chunks.contains { $0.page == 45 && $0.kind == .prose }, "\(chunks)")
        XCTAssertNil(chunks.first { $0.text.contains("<!--") }, "\(chunks)")
    }

    func testCommentsAreStrippedAndOnlyTheDiagramOneMeansAnything() {
        let chunks = DocumentChunker().chunk("""
        Page 7

        <!-- extracted 2026-09-07; check the manifold figures -->
        ## Priming Condensate Trap

        Pour ten fluid ounces of water into the trap before starting the unit.
        """)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertFalse(chunks[0].text.contains("extracted 2026"), chunks[0].text)
        XCTAssertEqual(chunks[0].kind, .prose)
        XCTAssertEqual(chunks[0].section, "Priming Condensate Trap")
    }

    func testAStructuredDocumentTurnsTheLexicalDetectorOff() {
        // The residue EJ could not reach: an ALL-CAPS wiring fragment is shaped exactly like a real
        // ALL-CAPS heading. Once the type has said what the sections are, guessing beside it only
        // adds noise, so the lexical rules stand down for the whole document.
        let chunker = DocumentChunker(targetChars: 80, maxChars: 140, overlapChars: 0)
        let structured = chunker.chunk("""
        ## Pressure Switches (Two)

        The low pressure switch closes on a call for heat.

        BOTH SENSOR
        PRESS TO RESET
        The high pressure switch opens above the rated draft.
        """)
        XCTAssertTrue(structured.allSatisfy { $0.section == "Pressure Switches (Two)" }, "\(structured)")

        // The same text without a single `## ` line: the lexical rules apply exactly as before.
        let lexical = chunker.chunk("""
        The low pressure switch closes on a call for heat.

        BOTH SENSOR
        PRESS TO RESET
        The high pressure switch opens above the rated draft.
        """)
        XCTAssertTrue(lexical.contains { $0.section == "PRESS TO RESET" }, "\(lexical)")
    }

    func testGrammarLinesDoNotMakeThePublishersHeaderTurnThePage() {
        // The extractor writes its own marker, then the page's structure, and only then the page's
        // own printed header. The physical page still wins, and the figure it tagged survives.
        let chunks = DocumentChunker(targetChars: 80, maxChars: 140, overlapChars: 0).chunk("""
        Page 44

        <!-- page: diagram -->
        ### Figure 58
        Page 42
        C 24VAXC COMMON
        """)
        XCTAssertTrue(chunks.allSatisfy { $0.page == 44 && $0.figure == "Figure 58" && $0.kind == .diagram },
                      "\(chunks)")
        XCTAssertNil(chunks.first { $0.text.contains("Page 42") }, "\(chunks)")
    }

    func testProseChunkBoundariesAreUnchangedByTheGrammar() {
        // The grammar annotates; it must not repack. The same prose with and without the markers
        // around it produces the same chunks.
        let chunker = DocumentChunker(targetChars: 120, maxChars: 160, overlapChars: 30)
        let prose = (1...20).map { "This is sentence number \($0) here." }.joined(separator: " ")
        let plain = chunker.chunk(prose)
        let annotated = chunker.chunk("<!-- extracted on a Mac -->\n" + prose)
        XCTAssertEqual(plain.map(\.text), annotated.map(\.text))
    }

    func testSectionHeadingTagsFollowingChunks() {
        let chunker = DocumentChunker(targetChars: 60, maxChars: 100, overlapChars: 0)
        let text = "5.3 Safety Requirements\nAll staff must wear helmets at all times. Visitors must sign in."
        let chunks = chunker.chunk(text)
        XCTAssertTrue(chunks.contains { $0.section == "5.3 Safety Requirements" },
                      "Content under a heading should carry that section")
    }
}
