#if !AVENKIN_PHONE_ONLY  // The phone-only (store) build has no glasses display, so no answer card.
import XCTest
@testable import OpenGlasses

/// Plan KV P2 — the question above the answer: "You: <what the app heard>" over the first page
/// of the answer card only, in the meta style, cut to one display line; none for a turn the app
/// started; and the pager giving the first page one line fewer so the page count is right.
///
/// Fresh services, the card's screens read from `screenOnLens`, nothing waits on the render queue.
@MainActor
final class HUDAnswerQuestionTests: XCTestCase {

    private let rayban = TeleprompterPaginator.Geometry.raybanDisplay   // 4 × 32
    private var savedDisplayEnabled = false

    override func setUp() {
        super.setUp()
        savedDisplayEnabled = Config.glassesDisplayEnabled
        Config.setGlassesDisplayEnabled(true)
    }

    override func tearDown() {
        Config.setGlassesDisplayEnabled(savedDisplayEnabled)
        super.tearDown()
    }

    private let question = "what size breaker for the invented condenser"

    private let longAnswer = """
    Turn the isolator off before you open the panel. Check the capacitor with a meter, \
    because it can hold a charge for minutes after the power is cut. If the reading is above \
    five volts, discharge it with an insulated resistor. Then swap the contactor, refit the \
    cover and restore the power.
    """

    /// Four display lines at 32 characters and under 120 characters: one page with no question.
    private let fourLineAnswer = "Turn the isolator off before you open it. Check the capacitor with a meter. Then swap the contactor and refit it."

    private var prefix: String { String(localized: "You:") }

    private func makeCard() -> (GlassesDisplayService, HUDAnswerCard) {
        let display = GlassesDisplayService()
        display.testCapabilityOverride = true
        display.testRenderSink = { _ in }
        let card = HUDAnswerCard(display: display)
        card.geometry = { .raybanDisplay }
        card.scheduleIdleTimer = { _, _ in }
        return (display, card)
    }

    private func questionLines(_ screen: HUDScreen?) -> [HUDLine] {
        screen?.lines.filter { $0.text.hasPrefix(prefix) } ?? []
    }

    // MARK: - Where it shows

    func testTheQuestionShowsOnceOnTheFirstPageOnly() throws {
        let (_, card) = makeCard()
        card.beginTurn(question: question)
        card.absorb(longAnswer, streamed: false)
        card.endTurn()
        XCTAssertGreaterThan(card.pages.count, 1)

        let first = try XCTUnwrap(card.screenOnLens)
        let lines = questionLines(first)
        XCTAssertEqual(lines.count, 1, "once")
        XCTAssertEqual(first.lines.first, lines.first, "above the answer")
        XCTAssertEqual(lines.first?.emphasis, .meta)
        XCTAssertTrue(lines.first?.text.contains("invented") == true || lines.first?.text.hasSuffix("…") == true)

        // The web mirror's page set: the question is on its first page and no other.
        let set = try XCTUnwrap(first.pageSet)
        XCTAssertEqual(set.pages.map { questionLines($0).count }, [1] + Array(repeating: 0, count: set.pages.count - 1))

        card.press(.next)
        XCTAssertEqual(card.pageIndex, 1)
        XCTAssertTrue(questionLines(card.screenOnLens).isEmpty, "page 2 keeps all its room")
        card.press(.back)
        XCTAssertEqual(questionLines(card.screenOnLens).count, 1)

        card.press(.actions)
        XCTAssertTrue(questionLines(card.screenOnLens).isEmpty, "not on the Actions screen")
    }

    func testASinglePageAnswerHasTheQuestionAboveIt() throws {
        let (_, card) = makeCard()
        card.beginTurn(question: "where is the filter")
        card.absorb("The filter is behind the front grille.", streamed: false)
        card.endTurn()
        let screen = try XCTUnwrap(card.screenOnLens)
        XCTAssertEqual(screen.lines.map(\.text), ["\(prefix) where is the filter", "The filter is behind the front grille."])
        XCTAssertEqual(card.question, "\(prefix) where is the filter")
    }

    func testALongQuestionIsCondensedNeverWrapped() throws {
        let long = "so what I want to know is what size breaker and what size cable I need for the invented condenser on the roof"
        let line = try XCTUnwrap(HUDAnswerCardBuilder.questionLine(for: long, maxChars: rayban.maxChars))
        XCTAssertLessThanOrEqual(line.count, rayban.maxChars)
        XCTAssertTrue(line.hasPrefix(prefix + " so what"))
        XCTAssertTrue(line.hasSuffix("…"), "cut, and seen to be cut")
        XCTAssertEqual(HUDAnswerPager.displayLines(for: line, maxChars: rayban.maxChars).count, 1, "one line")
        XCTAssertFalse(line.contains("\n"))

        // Spread over lines as spoken, it is still one line.
        let spoken = HUDAnswerCardBuilder.questionLine(for: "  where\n  is   it ", maxChars: rayban.maxChars)
        XCTAssertEqual(spoken, "\(prefix) where is it")
        // Short enough already: untouched.
        XCTAssertEqual(HUDAnswerCardBuilder.questionLine(for: "where is it", maxChars: rayban.maxChars), "\(prefix) where is it")

        let (_, card) = makeCard()
        card.beginTurn(question: long)
        card.absorb(longAnswer, streamed: false)
        card.endTurn()
        XCTAssertEqual(questionLines(card.screenOnLens).first?.text, line)
    }

    // MARK: - Turns the app started

    func testATurnTheAppStartedHasNoQuestion() {
        let (_, card) = makeCard()
        // A proactive alert's or a watcher's answer: spoken outside a Direct-mode turn.
        card.absorb("Your next job starts in fifteen minutes.", streamed: false)
        XCTAssertTrue(card.isShowing)
        XCTAssertNil(card.question)
        XCTAssertTrue(questionLines(card.screenOnLens).isEmpty)

        // A turn opened with no words, or blank ones.
        for words in [nil, "   \n "] as [String?] {
            card.beginTurn(question: words)
            card.absorb(longAnswer, streamed: false)
            card.endTurn()
            XCTAssertNil(card.question)
            XCTAssertTrue(questionLines(card.screenOnLens).isEmpty)
        }
        XCTAssertNil(HUDAnswerTurn(question: "  ").question)
        XCTAssertNil(HUDAnswerCardBuilder.questionLine(for: nil, maxChars: 32))
    }

    func testANewAnswerOutsideATurnDropsTheLastTurnsQuestion() {
        let (_, card) = makeCard()
        card.beginTurn(question: question)
        card.absorb("The breaker is on the left of the panel.", streamed: false)
        card.endTurn()
        XCTAssertNotNil(card.question)
        card.absorb("The invented watcher says the unit is running again.", streamed: false)
        XCTAssertNil(card.question, "the app's own answer is not an answer to the question")
        XCTAssertTrue(questionLines(card.screenOnLens).isEmpty)
    }

    // MARK: - Page counts

    func testThePagerBudgetsTheFirstPageOneLineShorter() {
        let plain = HUDAnswerPager.pages(for: longAnswer, geometry: rayban)
        let asked = HUDAnswerPager.pages(for: longAnswer, geometry: rayban, firstPageReservedLines: 1)
        XCTAssertLessThanOrEqual(plain[0].lines.count, rayban.maxLines - 1)
        XCTAssertLessThanOrEqual(asked[0].lines.count, rayban.maxLines - 2, "question + page + footer fit")
        for page in asked.dropFirst() { XCTAssertLessThanOrEqual(page.lines.count, rayban.maxLines - 1) }
        XCTAssertGreaterThanOrEqual(asked.count, plain.count)
        XCTAssertTrue(asked.allSatisfy { $0.count == asked.count }, "every page knows the count")
        // No word lost or doubled.
        let words = { (pages: [HUDAnswerPage]) in pages.flatMap { $0.lines.flatMap { $0.split(separator: " ") } } }
        XCTAssertEqual(words(asked), words(plain))
    }

    func testAFourLineAnswerIsOnePageWithoutTheQuestionAndTwoWithIt() {
        XCTAssertEqual(HUDAnswerPager.displayLines(for: fourLineAnswer, maxChars: rayban.maxChars).count, 4)
        XCTAssertEqual(HUDAnswerPager.pages(for: fourLineAnswer, geometry: rayban).count, 1)
        let asked = HUDAnswerPager.pages(for: fourLineAnswer, geometry: rayban, firstPageReservedLines: 1)
        XCTAssertEqual(asked.count, 2)

        let (_, card) = makeCard()
        card.beginTurn(question: question)
        card.absorb(fourLineAnswer, streamed: false)
        card.endTurn()
        XCTAssertEqual(card.pages.count, 2)
        // On the lens: the question, the page, the footer — inside the lens's four lines.
        XCTAssertLessThanOrEqual(card.screenOnLens?.lines.count ?? 0, rayban.maxLines)
        XCTAssertEqual(card.screenOnLens?.lines.last?.text, "1/2")

        let (_, plainCard) = makeCard()
        plainCard.beginTurn()
        plainCard.absorb(fourLineAnswer, streamed: false)
        plainCard.endTurn()
        XCTAssertEqual(plainCard.pages.count, 1)
    }

    func testAStreamedAnswerKeepsItsQuestionAndItsPages() {
        let (_, card) = makeCard()
        card.beginTurn(question: question)
        let sentences = longAnswer.components(separatedBy: ". ")
        for sentence in sentences.dropLast() { card.absorb(sentence + ".", streamed: true) }
        card.finishTurn(reply: longAnswer)
        card.endTurn()
        XCTAssertEqual(questionLines(card.screenOnLens).count, 1)
        XCTAssertEqual(card.pages, HUDAnswerPager.pages(for: card.answer, geometry: rayban, firstPageReservedLines: 1))
    }
}
#endif
