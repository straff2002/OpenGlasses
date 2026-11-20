import XCTest
@testable import OpenGlasses

/// Plan MO §6: a hint's two lens pages, and the few words of the question over it.
final class HintLensCardBuilderTests: XCTestCase {

    private let geometry = TeleprompterPaginator.Geometry(maxLines: 10, maxChars: 32)

    private func hint(question: String? = "What's the warranty on the compressor?", keyword: String? = nil,
                      line: String = "12 weeks from install",
                      full: String = "The compressor warranty is 12 weeks from the install date.",
                      general: Bool = false, source: LiveHint.Source = .model) -> LiveHint {
        LiveHint(id: 7, question: question, keyword: keyword, line: line, full: full, spoken: line,
                 source: source, general: general,
                 passage: PassageHint(text: "x", documentName: "Service terms", documentId: "d", chunkIndex: 0),
                 askedAt: Date())
    }

    func testTwoPagesQuestionDimmedOverTheHintThenFullAndSource() {
        let pages = HintLensCardBuilder.pages(for: hint(), geometry: geometry, suggestion: false) { _ in }
        XCTAssertEqual(pages.count, 2)
        XCTAssertEqual(pages[0].lines.first, HUDLine("Warranty on the compressor?", emphasis: .meta))
        XCTAssertEqual(pages[0].lines.last?.text, "12 weeks from install")
        XCTAssertEqual(pages[0].lines.last?.emphasis, .primary)
        XCTAssertEqual(pages[0].items.map(\.id), [HintLensCardBuilder.ItemID.next, HintLensCardBuilder.ItemID.close])
        XCTAssertEqual(pages[1].lines.map(\.text),
                       ["The compressor warranty is 12", "weeks from the install date.", "Service terms"])
        XCTAssertEqual(pages[1].lines.last?.emphasis, .meta)
        XCTAssertEqual(pages[1].items.map(\.id), [HintLensCardBuilder.ItemID.back, HintLensCardBuilder.ItemID.close])
    }

    func testEveryPageCarriesThePageSetUnderItsOwnCardNumber() {
        let pages = HintLensCardBuilder.pages(for: hint(), geometry: geometry, suggestion: false) { _ in }
        XCTAssertEqual(pages.map { $0.pageSet?.index }, [0, 1])
        XCTAssertEqual(pages.map { $0.pageSet?.pages.count }, [2, 2])
        XCTAssertEqual(pages[0].pageSet?.card, HintLensCardBuilder.cardSerialBase + 7)
    }

    func testAHintWithNothingMoreIsOnePageWithItsSource() {
        let one = hint(line: "Parts are covered for a year.", full: "", source: .passage)
        let pages = HintLensCardBuilder.pages(for: one, geometry: geometry, suggestion: false) { _ in }
        XCTAssertEqual(pages.count, 1)
        XCTAssertEqual(pages[0].lines.last, HUDLine("Service terms", emphasis: .meta))
        XCTAssertEqual(pages[0].items.map(\.id), [HintLensCardBuilder.ItemID.close])
    }

    func testGeneralKnowledgeIsMarked() {
        let pages = HintLensCardBuilder.pages(for: hint(general: true), geometry: geometry, suggestion: false) { _ in }
        XCTAssertEqual(pages[1].lines.last?.text, "General knowledge")
    }

    func testMedicalComplianceSaysSuggestionAboveTheHint() {
        let pages = HintLensCardBuilder.pages(for: hint(), geometry: geometry, suggestion: true) { _ in }
        let texts = pages[0].lines.map(\.text)
        XCTAssertEqual(texts.firstIndex(of: "Suggestion"), 1)
        XCTAssertEqual(texts.last, "12 weeks from install")
    }

    func testAKeywordCardNamesTheKeyword() {
        let pages = HintLensCardBuilder.pages(for: hint(question: nil, keyword: "compressor"), geometry: geometry,
                                              suggestion: false) { _ in }
        XCTAssertEqual(pages[0].lines.first, HUDLine("compressor", emphasis: .meta))
    }

    func testButtonsReportTheirAction() {
        var actions: [HintLensCardBuilder.Action] = []
        let pages = HintLensCardBuilder.pages(for: hint(), geometry: geometry, suggestion: false) { actions.append($0) }
        pages[0].items.forEach { $0.action() }
        pages[1].items.forEach { $0.action() }
        XCTAssertEqual(actions, [.next, .close, .back, .close])
    }

    func testLinesFitTheLens() {
        let long = hint(line: "Twelve weeks from the date of install", full: String(repeating: "word ", count: 40))
        let pages = HintLensCardBuilder.pages(for: long, geometry: geometry, suggestion: true, onAction: { _ in })
        for page in pages {
            for line in page.lines { XCTAssertLessThanOrEqual(line.text.count, 32, line.text) }
        }
    }

    // MARK: - The question's glance

    func testTheGlanceDropsTheOpeningAndKeepsFourWords() {
        XCTAssertEqual(HintQuestionGlance.glance("What's the warranty on the compressor?"), "Warranty on the compressor?")
        XCTAssertEqual(HintQuestionGlance.glance("Can you tell me about your biggest project?"), "Biggest project?")
        XCTAssertEqual(HintQuestionGlance.glance("So how long does the install of the rooftop unit take?"),
                       "Long does the install…?")
    }

    func testAQuestionOfOnlyQuestionWordsKeepsItsWords() {
        XCTAssertEqual(HintQuestionGlance.glance("And what about you?"), "And what about you?")
        XCTAssertEqual(HintQuestionGlance.glance(""), "")
    }
}
