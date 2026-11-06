#if !AVENKIN_PHONE_ONLY  // The phone-only (store) build has no glasses display, so no answer card.
import XCTest
@testable import OpenGlasses

/// Plan KP P2 — suggested follow-ups on the answer card: two beside Actions on the last page, a
/// third on the Actions screen, each press sending its text as the next turn; only the turn whose
/// reply carried them shows them, and a card replaced or cut short shows none.
///
/// Every check reads the screen the card last handed to the display (`screenOnLens`), which is
/// set as the card is drawn, so nothing waits on the render queue.
@MainActor
final class HUDAnswerFollowUpTests: XCTestCase {

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

    private let shortAnswer = "The breaker is on the left of the panel."

    private let longAnswer = """
    Turn the isolator off before you open the panel. Check the capacitor with a meter, \
    because it can hold a charge for minutes after the power is cut. If the reading is above \
    five volts, discharge it with an insulated resistor. Then swap the contactor, refit the \
    cover and restore the power.
    """

    private let questions = ["Which breaker is it?", "How do I reset it?", "Is it safe?"]

    private func makeCard() -> (GlassesDisplayService, HUDAnswerCard) {
        let display = GlassesDisplayService()
        display.testCapabilityOverride = true
        display.testRenderSink = { _ in }
        let card = HUDAnswerCard(display: display)
        card.geometry = { .raybanDisplay }
        card.scheduleIdleTimer = { _, _ in }
        return (display, card)
    }

    private func ids(_ screen: HUDScreen?) -> [String] { screen?.items.map(\.id) ?? [] }
    private func labels(_ screen: HUDScreen?) -> [String] { screen?.items.map(\.label) ?? [] }
    private typealias ID = HUDAnswerCardBuilder.ItemID

    // MARK: - Where they show

    func testAOnePageAnswerShowsTwoFollowUpsBesideActionsAndTheThirdUnderActions() {
        let (_, card) = makeCard()
        card.beginTurn()
        card.offerFollowUps(questions)
        card.absorb(shortAnswer, streamed: false)
        card.endTurn()

        XCTAssertEqual(ids(card.screenOnLens), [ID.followUp(0), ID.followUp(1), ID.actions])
        XCTAssertEqual(Array(labels(card.screenOnLens).prefix(2)), Array(questions.prefix(2)))

        card.press(.actions)
        XCTAssertTrue(card.isOnActions)
        XCTAssertEqual(ids(card.screenOnLens).first, ID.followUp(2))
        XCTAssertEqual(labels(card.screenOnLens).first, questions[2])
        XCTAssertTrue(ids(card.screenOnLens).contains(ID.more))
    }

    func testAPagedAnswerShowsThemOnTheLastPageOnly() {
        let (_, card) = makeCard()
        card.beginTurn()
        card.offerFollowUps(questions)
        card.absorb(longAnswer, streamed: false)
        card.endTurn()
        XCTAssertGreaterThan(card.pages.count, 1)

        XCTAssertFalse(ids(card.screenOnLens).contains(ID.followUp(0)), "not on page 1")
        for _ in 0..<10 where card.canTurn(.next) { card.press(.next) }
        XCTAssertEqual(card.pageIndex, card.pages.count - 1)
        XCTAssertEqual(Array(ids(card.screenOnLens).prefix(2)), [ID.followUp(0), ID.followUp(1)])
    }

    func testAStreamedAnswerGetsThemWhenTheReplyIsFinal() {
        let (_, card) = makeCard()
        card.beginTurn()
        let sentences = longAnswer.components(separatedBy: ". ")
        for sentence in sentences.dropLast() { card.absorb(sentence + ".", streamed: true) }
        XCTAssertTrue(card.isShowing, "page 1 shows once settled")
        // The reply returns (its tail already off), then `speak:` finishes the card.
        card.offerFollowUps(questions)
        XCTAssertTrue(card.followUps.isEmpty, "not until the reply is final on the card")
        card.finishTurn(reply: longAnswer)
        XCTAssertEqual(card.followUps, questions)
        card.endTurn()
    }

    func testFollowUpsOfferedAfterTheCardIsFinalRedrawIt() {
        let (_, card) = makeCard()
        card.beginTurn()
        card.absorb(shortAnswer, streamed: false)
        XCTAssertEqual(ids(card.screenOnLens), [ID.actions])
        card.offerFollowUps(Array(questions.prefix(1)))
        XCTAssertEqual(ids(card.screenOnLens), [ID.followUp(0), ID.actions])
        card.endTurn()
    }

    // MARK: - What a press does

    func testPressingAFollowUpSendsItsTextAsTheNextTurn() {
        let (_, card) = makeCard()
        var turns: [String] = []
        card.submitTurn = { turns.append($0) }
        card.beginTurn()
        card.offerFollowUps(questions)
        card.absorb(shortAnswer, streamed: false)
        card.endTurn()

        // A band press acts on the button as drawn.
        card.screenOnLens?.items.first { $0.id == ID.followUp(1) }?.action()
        XCTAssertEqual(turns, [questions[1]])

        // The third, from the Actions screen.
        card.press(.actions)
        card.screenOnLens?.items.first { $0.id == ID.followUp(2) }?.action()
        XCTAssertEqual(turns, [questions[1], questions[2]])
    }

    // MARK: - Only this answer's

    func testANewAnswerReplacesTheCardWithoutTheOldFollowUps() {
        let (_, card) = makeCard()
        card.beginTurn()
        card.offerFollowUps(questions)
        card.absorb(shortAnswer, streamed: false)
        card.endTurn()
        XCTAssertFalse(card.followUps.isEmpty)

        // The next turn's reply had no tail.
        card.beginTurn()
        card.offerFollowUps([])
        card.absorb("The panel is behind the door.", streamed: false)
        card.endTurn()
        XCTAssertEqual(card.followUps, [])
        XCTAssertEqual(ids(card.screenOnLens), [ID.actions])

        // A whole answer outside a turn (a photo answer) is a card of its own, with none.
        card.beginTurn()
        card.offerFollowUps(questions)
        card.absorb(shortAnswer, streamed: false)
        card.endTurn()
        card.absorb("It's a contactor.", streamed: false)
        XCTAssertEqual(card.followUps, [])
    }

    func testATurnCutShortShowsNone() {
        let (_, card) = makeCard()
        card.beginTurn()
        for sentence in longAnswer.components(separatedBy: ". ").prefix(2) {
            card.absorb(sentence + ".", streamed: true)
        }
        card.offerFollowUps(questions)
        card.endTurn()   // a barge-in: the reply never became final
        XCTAssertEqual(card.followUps, [])
    }

    func testClosingClearsThemAndAnOfferWithNoTurnIsIgnored() {
        let (_, card) = makeCard()
        card.beginTurn()
        card.offerFollowUps(questions)
        card.absorb(shortAnswer, streamed: false)
        card.endTurn()
        card.press(.close)
        XCTAssertEqual(card.followUps, [])
        XCTAssertFalse(card.isShowing)

        card.offerFollowUps(questions)   // no turn open
        card.absorb(shortAnswer, streamed: false)
        XCTAssertEqual(card.followUps, [])
    }
}
#endif
