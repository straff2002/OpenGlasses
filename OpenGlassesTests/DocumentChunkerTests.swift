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
    }

    func testDetectHeadingRejectsOrdinaryAndTooShortLines() {
        XCTAssertNil(DocumentChunker.detectHeading("This is a normal sentence."))
        XCTAssertNil(DocumentChunker.detectHeading("abc"))                 // < 4 chars
        XCTAssertNil(DocumentChunker.detectHeading("the quick brown fox")) // lowercase, unnumbered
    }

    func testPageNumberDetection() {
        XCTAssertEqual(DocumentChunker.pageNumber(in: "Page 42"), 42)
        XCTAssertEqual(DocumentChunker.pageNumber(in: "- 7 -"), 7)
        XCTAssertNil(DocumentChunker.pageNumber(in: "Page of contents"))
        XCTAssertNil(DocumentChunker.pageNumber(in: "ordinary text"))
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

    func testSectionHeadingTagsFollowingChunks() {
        let chunker = DocumentChunker(targetChars: 60, maxChars: 100, overlapChars: 0)
        let text = "5.3 Safety Requirements\nAll staff must wear helmets at all times. Visitors must sign in."
        let chunks = chunker.chunk(text)
        XCTAssertTrue(chunks.contains { $0.section == "5.3 Safety Requirements" },
                      "Content under a heading should carry that section")
    }
}
