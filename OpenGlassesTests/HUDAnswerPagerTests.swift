import XCTest
@testable import OpenGlasses

/// Plan KP P0 — the answer pager: whole answers cut into HUD pages.
final class HUDAnswerPagerTests: XCTestCase {

    private let rayban = TeleprompterPaginator.Geometry.raybanDisplay   // 4 × 32
    private let even = TeleprompterPaginator.Geometry.evenG2            // 3 × 40

    /// A ~400-character answer of ordinary sentences.
    private let longAnswer = """
    Turn the isolator off before you open the panel. Check the capacitor with a meter, \
    because it can hold a charge for minutes after the power is cut. If the reading is above \
    five volts, discharge it with an insulated resistor. Then swap the contactor, refit the \
    cover and restore the power. Run the unit for ten minutes and listen for short cycling \
    before you leave the site. Log the readings on the job sheet.
    """

    private func words(of text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private func pagedWords(_ pages: [HUDAnswerPage]) -> [String] {
        pages.flatMap { page in
            page.lines.filter { $0 != HUDAnswerPager.moreOnPhoneLine }
                .flatMap { $0.split(separator: " ").map(String.init) }
        }
    }

    // MARK: - One page

    func testAShortAnswerIsOnePageWithNoFooterAndTodaysText() {
        let text = "  The filter is\nbehind the   front grille. "
        for geometry in [rayban, even] {
            let pages = HUDAnswerPager.pages(for: text, geometry: geometry)
            XCTAssertEqual(pages.count, 1)
            let page = pages[0]
            XCTAssertEqual(page.body, HUDTextShaper.condense(text))
            XCTAssertEqual(page.index, 0)
            XCTAssertEqual(page.count, 1)
            XCTAssertNil(page.footer)
            XCTAssertFalse(page.isPaged)
            XCTAssertFalse(page.isCapped)
            XCTAssertTrue(page.isLast)
        }
    }

    func testEmptyAndBlankAnswersHaveNoPages() {
        XCTAssertTrue(HUDAnswerPager.pages(for: "", geometry: rayban).isEmpty)
        XCTAssertTrue(HUDAnswerPager.pages(for: " \n\n\t ", geometry: rayban).isEmpty)
    }

    func testAnAnswerOverTheBodyLimitIsPagedNotCut() {
        // Fits four lines of 32 on the Display but is longer than today's 120-character cut.
        let text = String(repeating: "abcdefg ", count: 16).trimmingCharacters(in: .whitespaces)  // 127 chars
        XCTAssertGreaterThan(text.count, HUDTextShaper.maxBodyLength)
        let pages = HUDAnswerPager.pages(for: text, geometry: rayban)
        XCTAssertGreaterThan(pages.count, 1)
        XCTAssertEqual(pagedWords(pages), words(of: text))
    }

    // MARK: - Paged

    func testALongAnswerPagesOnBothGeometries() {
        XCTAssertGreaterThanOrEqual(longAnswer.count, 400)
        for geometry in [rayban, even] {
            let pages = HUDAnswerPager.pages(for: longAnswer, geometry: geometry)
            XCTAssertGreaterThan(pages.count, 1, "geometry \(geometry.maxLines)×\(geometry.maxChars)")
            XCTAssertLessThanOrEqual(pages.count, HUDAnswerPager.defaultMaxPages)
            for (index, page) in pages.enumerated() {
                XCTAssertEqual(page.index, index)
                XCTAssertEqual(page.count, pages.count)
                XCTAssertEqual(page.footer, "\(index + 1)/\(pages.count)")
                // One line is reserved for the footer.
                XCTAssertLessThanOrEqual(page.lines.count, geometry.maxLines - 1)
                XCTAssertFalse(page.lines.isEmpty)
                for line in page.lines { XCTAssertLessThanOrEqual(line.count, geometry.maxChars) }
                XCTAssertEqual(page.body, page.lines.joined(separator: "\n"))
                XCTAssertFalse(page.isCapped)
            }
            // Nothing lost, nothing reordered.
            XCTAssertEqual(pagedWords(pages), words(of: longAnswer))
        }
    }

    func testFourHundredCharactersOnTheDisplayIsFiveOrSixPages() {
        let pages = HUDAnswerPager.pages(for: longAnswer, geometry: rayban)
        // 3 lines × 32 characters per page.
        XCTAssertTrue((4...7).contains(pages.count), "\(pages.count) pages")
        let evenPages = HUDAnswerPager.pages(for: longAnswer, geometry: even)
        XCTAssertTrue((5...8).contains(evenPages.count), "\(evenPages.count) pages")
    }

    func testAPageBreakNeverSplitsAWord() {
        let answerWords = Set(words(of: longAnswer))
        for geometry in [rayban, even] {
            for page in HUDAnswerPager.pages(for: longAnswer, geometry: geometry) {
                for word in page.lines.flatMap({ $0.split(separator: " ") }) {
                    XCTAssertTrue(answerWords.contains(String(word)), "split word: \(word)")
                }
            }
        }
    }

    func testAPagePrefersASentenceEndInItsLastLine() {
        // Display: 3 lines of 32 per page. Line 3 of page 1 holds "Short. Then the next" — the
        // page should end after "Short." and the rest of that line move to page 2.
        let text = "aaaa bbbb cccc dddd eeee ffff gg hhhh iiii jjjj kkkk llll mmmm nn "
            + "Short. Then the next sentence carries on for a while longer here."
        let pages = HUDAnswerPager.pages(for: text, geometry: rayban)
        XCTAssertGreaterThan(pages.count, 1)
        XCTAssertEqual(pages[0].lines.count, 3)
        XCTAssertEqual(pages[0].lines.last, "Short.")
        XCTAssertTrue(pages[1].lines[0].hasPrefix("Then the next"))
        XCTAssertEqual(pagedWords(pages), words(of: text))
    }

    func testNoSentenceEndInTheLastLineFillsThePage() {
        let text = String(repeating: "word ", count: 60)
        let pages = HUDAnswerPager.pages(for: text, geometry: rayban)
        // "word" × 6 = 29 characters per line; three full lines per page.
        XCTAssertEqual(pages[0].lines, Array(repeating: "word word word word word word", count: 3))
    }

    func testASentenceEndAtTheEndOfTheLineNeedsNoPullBack() {
        let text = "aaaa bbbb cccc dddd eeee ffff gg hhhh iiii jjjj kkkk llll mmmm nn "
            + "ooo ppp qqq rrr sss tttt end. Next page starts here and goes on."
        let pages = HUDAnswerPager.pages(for: text, geometry: rayban)
        XCTAssertEqual(pages[0].lines.last, "ooo ppp qqq rrr sss tttt end.")
    }

    func testTheEightPageCapEndsMoreOnPhone() {
        let text = (1...200).map { "Sentence number \($0) is here." }.joined(separator: " ")
        for geometry in [rayban, even] {
            let pages = HUDAnswerPager.pages(for: text, geometry: geometry)
            XCTAssertEqual(pages.count, 8)
            let last = pages[7]
            XCTAssertTrue(last.isCapped)
            XCTAssertEqual(last.lines.last, HUDAnswerPager.moreOnPhoneLine)
            XCTAssertEqual(last.footer, "8/8")
            XCTAssertLessThanOrEqual(last.lines.count, geometry.maxLines - 1)
            XCTAssertTrue(pages.dropLast().allSatisfy { !$0.isCapped })
            // What is shown is the start of the answer, in order.
            let shown = pagedWords(pages)
            XCTAssertEqual(Array(words(of: text).prefix(shown.count)), shown)
        }
    }

    func testACustomCapIsHonoured() {
        let pages = HUDAnswerPager.pages(for: longAnswer, geometry: rayban, maxPages: 2)
        XCTAssertEqual(pages.count, 2)
        XCTAssertTrue(pages[1].isCapped)
        XCTAssertEqual(pages[1].lines.last, HUDAnswerPager.moreOnPhoneLine)
    }

    func testTheMoreOnPhoneLineHasNoPlanLetter() {
        XCTAssertEqual(HUDAnswerPager.moreOnPhoneLine, "… more on phone")
    }

    func testBlankLinesAreSkippedAndParagraphsStartANewLine() {
        let text = "First paragraph is short.\n\n\n\nSecond paragraph.\n\nThird one here.\n"
            + String(repeating: "filler ", count: 30)
        let pages = HUDAnswerPager.pages(for: text, geometry: rayban)
        XCTAssertEqual(pages[0].lines, ["First paragraph is short.", "Second paragraph.", "Third one here."])
        for page in pages { XCTAssertFalse(page.lines.contains("")) }
    }

    func testWrappingIsTheTeleprompters() {
        let text = "One short line.\n\nA much longer paragraph that will need to wrap across several display lines.\n"
            + "Last line with a verylongunbrokenwordthatexceedsthewidthofaline in it."
        for geometry in [rayban, even] {
            let script = TeleprompterScript.parse(title: "t", text: text)
            let window = TeleprompterPaginator.window(
                script, cursor: 0,
                geometry: .init(maxLines: 1000, maxChars: geometry.maxChars))
            XCTAssertEqual(HUDAnswerPager.displayLines(for: text, maxChars: geometry.maxChars), window.lines)
        }
    }

    func testAWordLongerThanALineIsKeptWholeOnAPageWhenItFits() {
        let link = "https://example.com/" + String(repeating: "x", count: 40)   // 60 chars, two lines
        let text = "aaaa bbbb cccc dddd eeee ffff gg hhhh iiii jjjj kkkk llll mmmm nn " + link + " and after."
        let pages = HUDAnswerPager.pages(for: text, geometry: rayban)
        // Page 1 can't hold the link's two lines after two full lines, so the link moves whole.
        XCTAssertFalse(pages[0].lines.joined().contains("https"))
        XCTAssertTrue(pages[1].lines[0].hasPrefix("https://example.com/"))
        XCTAssertTrue(pages[1].lines.prefix(2).joined().hasPrefix(link))
    }

    func testAWordLongerThanAPageIsSplitAcrossPages() {
        let huge = String(repeating: "y", count: 200)
        let pages = HUDAnswerPager.pages(for: "Start " + huge + " end", geometry: rayban)
        let shown = pages.flatMap(\.lines).joined().replacingOccurrences(of: " ", with: "")
        XCTAssertEqual(shown, "Start" + huge + "end")
        for page in pages { for line in page.lines { XCTAssertLessThanOrEqual(line.count, 32) } }
    }

    // MARK: - Streaming

    func testPagesThatGrowWhileStreamingKeepTheirEarlierPages() {
        let sentences = (1...40).map { "This is streamed sentence \($0), with a few more words." }
        let full = sentences.joined(separator: " ")
        for geometry in [rayban, even] {
            let final = HUDAnswerPager.pages(for: full, geometry: geometry)
            var settledSoFar: [[String]] = []
            for k in 1...sentences.count {
                let prefix = sentences.prefix(k).joined(separator: " ")
                let pages = HUDAnswerPager.pages(for: prefix, geometry: geometry)
                let settled = HUDAnswerPager.settledPageCount(pages)
                // Settled pages match the final answer's pages exactly.
                for index in 0..<settled {
                    XCTAssertEqual(pages[index].lines, final[index].lines, "prefix \(k) page \(index)")
                    XCTAssertEqual(pages[index].body, final[index].body)
                }
                // And a page once settled never changes.
                for (index, lines) in settledSoFar.enumerated() where index < settled {
                    XCTAssertEqual(pages[index].lines, lines)
                }
                settledSoFar = pages.prefix(settled).map(\.lines)
                // The count only grows.
                XCTAssertLessThanOrEqual(pages.count, final.count)
            }
        }
    }

    func testStreamingStabilityHoldsWordByWordWithParagraphs() {
        let full = longAnswer + "\nA second paragraph follows here. " + longAnswer
        let tokens = full.components(separatedBy: " ")
        let final = HUDAnswerPager.pages(for: full, geometry: rayban)
        for k in 1...tokens.count {
            let prefix = tokens.prefix(k).joined(separator: " ")
            let pages = HUDAnswerPager.pages(for: prefix, geometry: rayban)
            for index in 0..<HUDAnswerPager.settledPageCount(pages) {
                XCTAssertEqual(pages[index].lines, final[index].lines, "prefix \(k) page \(index)")
            }
        }
    }

    func testSettledPageCount() {
        XCTAssertEqual(HUDAnswerPager.settledPageCount([]), 0)
        let single = HUDAnswerPager.pages(for: "Short.", geometry: rayban)
        XCTAssertEqual(HUDAnswerPager.settledPageCount(single), 0)
        let paged = HUDAnswerPager.pages(for: longAnswer, geometry: rayban)
        XCTAssertEqual(HUDAnswerPager.settledPageCount(paged), paged.count - 1)
        let capped = HUDAnswerPager.pages(for: longAnswer, geometry: rayban, maxPages: 2)
        XCTAssertEqual(HUDAnswerPager.settledPageCount(capped), 2)
    }

    func testACappedAnswerStaysTheSameAsItKeepsGrowing() {
        let base = (1...120).map { "Sentence \($0) goes here." }
        let short = HUDAnswerPager.pages(for: base.joined(separator: " "), geometry: rayban)
        let longer = HUDAnswerPager.pages(for: (base + base).joined(separator: " "), geometry: rayban)
        XCTAssertTrue(short.last?.isCapped ?? false)
        XCTAssertEqual(short, longer)
    }

    func testSentenceEndDetection() {
        XCTAssertTrue(HUDAnswerPager.endsSentence("done."))
        XCTAssertTrue(HUDAnswerPager.endsSentence("really?\""))
        XCTAssertTrue(HUDAnswerPager.endsSentence("(yes!)"))
        XCTAssertTrue(HUDAnswerPager.endsSentence("終わり。"))
        XCTAssertFalse(HUDAnswerPager.endsSentence("3.5"))
        XCTAssertFalse(HUDAnswerPager.endsSentence("word,"))
        XCTAssertFalse(HUDAnswerPager.endsSentence(")"))
    }
}
