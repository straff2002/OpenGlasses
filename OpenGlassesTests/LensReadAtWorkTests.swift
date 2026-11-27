import XCTest
@testable import OpenGlasses

/// Plan MU P2–P4, headless: fuller tiles (`HUDReadingRows`, 8 lines joined up to 9, no orphan),
/// sources on their own (`LensSourceTile` and the reading view's source tile), Earlier that says
/// what it is, a button row that fits (`LensButtonRowBudget` on every lens row), and the answer that
/// stays until it is put away. Every fixture is invented: the unit, the guide, the codes and the
/// readings.
@MainActor
final class LensReadAtWorkTests: XCTestCase {

    private let geometry = LensPageFrame.answerGeometry
    private var chars: Int { HUDReadingRows.maxChars(for: geometry) }

    private var savedDisplayEnabled = false
    private var savedBackend: String?

    override func setUp() async throws {
        try await super.setUp()
        savedDisplayEnabled = Config.glassesDisplayEnabled
        savedBackend = UserDefaults.standard.string(forKey: "displayBackend")
        Config.glassesDisplayEnabled = true
        Config.displayBackend = .metaRayBan
    }

    override func tearDown() async throws {
        Config.glassesDisplayEnabled = savedDisplayEnabled
        UserDefaults.standard.set(savedBackend, forKey: "displayBackend")
        try await super.tearDown()
    }

    /// The first photo's answer, invented: a long paragraph, its source on a line of its own.
    private let ownLineAnswer = """
        E7 on the Kwartz unit means the supply voltage at the control board is low. Check the incoming \
        supply at terminals L and N with the unit running; it should read between 216 and 253 V. If it is \
        lower, the fault is before the unit, so check the isolator and the supply cable first. If the supply \
        is good, check the plug at X3 on the board for a loose or burnt pin and reseat it. Reset the unit by \
        holding OFF for five seconds. If E7 comes back within the hour, replace the control board.
        Source: Invented Unit Guide, page 20
        """

    /// The second photo's answer, invented: the model ran its source onto the end of a sentence,
    /// and the old cut left a tile holding only "20.".
    private let runOnAnswer = """
        E9 means the outdoor fan has stopped. Turn the unit off at the isolator, then check that the fan \
        turns freely by hand. If it is stiff, the bearing has failed and the motor needs replacing. If it \
        turns freely, check the fan plug at X5 and measure the motor winding, which should read about \
        40 ohms. Replace the fan motor if the winding reads open. Restart the unit and check that E9 has \
        cleared. Source: Invented Unit Guide, page 20.
        """

    // MARK: - P2: fuller tiles

    func testATileHoldsEightLinesNowAndJoinsUpToNine() {
        XCTAssertEqual(HUDReadingRows.rowMaxLines, 8)
        XCTAssertEqual(HUDReadingRows.rowCeilingLines, 9)
        // Eight lines of one paragraph: one tile, where MG cut it in two.
        let eight = (1...8).map { _ in String(repeating: "a", count: chars - 1) }.joined(separator: " ")
        let rows = HUDReadingRows.rows(for: eight, maxChars: chars)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].lines.count, 8)
    }

    func testASentenceThatRunsOneWordOverJoinsTheTileBefore() {
        // Eight full lines with no sentence end, then one more word: MG's cut made "20." its own tile.
        let body = (1...8).map { "Line\($0) " + String(repeating: "x", count: chars - 7) }.joined(separator: " ")
        let text = body + " 20."
        let rows = HUDReadingRows.rows(for: text, maxChars: chars)
        XCTAssertEqual(rows.count, 1, "the one-word last piece joins: \(rows.map(\.lines))")
        XCTAssertEqual(rows[0].lines.count, 9)
        XCTAssertEqual(rows[0].lines.last, "20.")
    }

    /// Eight full lines in two sentences, then a short last sentence.
    private var eightLinesThenAnOrphan: String {
        let filler = String(repeating: "x", count: chars - 6)
        let first = (1...4).map { "Aaa\($0) " + filler }.joined(separator: " ") + "."
        let second = (1...4).map { "Bbb\($0) " + filler }.joined(separator: " ") + "."
        return first + " " + second + " Then reset."
    }

    func testAShortLastSentenceJoinsAndNeverStandsAlone() {
        let rows = HUDReadingRows.rows(for: eightLinesThenAnOrphan, maxChars: chars)
        XCTAssertEqual(rows.count, 1, "\(rows.map(\.lines))")
        XCTAssertEqual(rows[0].lines.count, 9)
        XCTAssertEqual(rows[0].lines.last, "Then reset.")
    }

    func testAnOrphanThatCannotJoinMovesTheCutBackASentence() {
        // With no room to join (a ceiling of eight), the cut moves back a sentence instead.
        let split = HUDReadingRows.split(eightLinesThenAnOrphan, maxChars: chars, rowMaxLines: 8, ceilingLines: 8)
        XCTAssertEqual(split.rows.count, 2)
        XCTAssertEqual(split.rows[0].count, 4, "the first sentence")
        XCTAssertEqual(split.rows[1].last, "Then reset.")
        XCTAssertGreaterThan(split.rows[1].count, 1, "the second sentence and the short one together")
        XCTAssertEqual(split.firstMovedRow, 0)
        XCTAssertEqual(split.settledRows, 0, "the moved tile can still change while the answer streams")
        let joined = split.rows.flatMap { $0 }.joined(separator: " ")
        XCTAssertEqual(joined, eightLinesThenAnOrphan, "no word lost or added")
    }

    func testNoTileOfEitherPhotoAnswerIsAnOrphanOrTallerThanNineLines() {
        for answer in [ownLineAnswer, runOnAnswer] {
            let prose = LensSourceTile.split(answer).prose
            let rows = HUDReadingRows.rows(for: prose, maxChars: chars)
            for row in rows {
                XCTAssertLessThanOrEqual(row.lines.count, HUDReadingRows.rowCeilingLines)
                XCTAssertTrue(row.lines.allSatisfy { $0.count <= chars })
            }
            for (index, row) in rows.enumerated() where index + 1 == rows.count || rows[index + 1].startsParagraph {
                XCTAssertFalse(row.text.count < HUDReadingRows.orphanCharacters && !row.startsParagraph,
                               "an orphan tile: \(row.text)")
            }
            XCTAssertFalse(rows.contains { $0.text == "20." || $0.text.hasPrefix("Source") })
        }
    }

    func testSettledTilesKeepTheirTextAsTheAnswerStreamsWordByWord() {
        for answer in [ownLineAnswer, runOnAnswer, String(repeating: "Check the plug at X3 for a burnt pin. ", count: 14)] {
            let words = answer.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            var previous: [HUDReadingRow] = []
            var previousSettled = 0
            for count in 1...words.count {
                let text = LensSourceTile.split(words.prefix(count).joined(separator: " ")).prose
                let rows = HUDReadingRows.rows(for: text, maxChars: chars)
                let settled = HUDReadingRows.settledRowCount(for: text, maxChars: chars, isComplete: false)
                XCTAssertLessThanOrEqual(settled, rows.count)
                XCTAssertEqual(Array(rows.prefix(previousSettled)), Array(previous.prefix(previousSettled)),
                               "settled tiles changed at word \(count)")
                XCTAssertGreaterThanOrEqual(settled, previousSettled)
                previous = rows
                previousSettled = settled
            }
        }
    }

    // MARK: - P2: sources on their own

    func testASourceOnItsOwnLineLeavesTheProse() {
        let tile = LensSourceTile.split(ownLineAnswer)
        XCTAssertEqual(tile.sources, ["Invented Unit Guide, page 20"])
        XCTAssertFalse(tile.prose.contains("Source"))
        XCTAssertTrue(tile.prose.hasSuffix("replace the control board."))
        XCTAssertEqual(tile.text, "Source: Invented Unit Guide, page 20")
    }

    func testASentenceEndingInASourceKeepsItsWordsUpToTheMarker() {
        let tile = LensSourceTile.split(runOnAnswer)
        XCTAssertEqual(tile.sources, ["Invented Unit Guide, page 20"])
        XCTAssertTrue(tile.prose.hasSuffix("check that E9 has cleared."), tile.prose)
        XCTAssertFalse(tile.prose.contains("Source"))
        XCTAssertFalse(tile.prose.contains("page 20"))
    }

    func testASourceInMidSentenceAndProseAfterIt() {
        let midSentence = LensSourceTile.split("Check the supply voltage Source: Invented Unit Guide, page 20. Then restart it.")
        XCTAssertEqual(midSentence.prose, "Check the supply voltage. Then restart it.")
        XCTAssertEqual(midSentence.sources, ["Invented Unit Guide, page 20"])
        let bracketed = LensSourceTile.split("Free the fan (Source: Invented Unit Guide, page 21) and restart the unit.")
        XCTAssertEqual(bracketed.prose, "Free the fan and restart the unit.")
        XCTAssertEqual(bracketed.sources, ["Invented Unit Guide, page 21"])
        let closedBracket = LensSourceTile.split("Free the fan (Source: Invented Unit Guide, page 21).")
        XCTAssertEqual(closedBracket.prose, "Free the fan.")
        let dash = LensSourceTile.split("Reseat the plug at X3 — Source: Invented Unit Guide, page 20")
        XCTAssertEqual(dash.prose, "Reseat the plug at X3.")
    }

    func testTwoSourcesAreJoinedWithASemicolonAndASourceWithNoPageIsKept() {
        let text = "E6 is a stalled fan. Source: Invented Unit Guide, page 18\nE7 is low voltage. Source: Invented Wiring Card"
            + "\nSource: Invented Unit Guide, page 18"
        let tile = LensSourceTile.split(text)
        XCTAssertEqual(tile.sources, ["Invented Unit Guide, page 18", "Invented Wiring Card"], "each once, in order")
        XCTAssertEqual(tile.text, "Sources: Invented Unit Guide, page 18; Invented Wiring Card")
        XCTAssertEqual(tile.prose, "E6 is a stalled fan.\nE7 is low voltage.")
        XCTAssertTrue(LensSourceTile.split("Answer. Source: none").sources.isEmpty, "not a document")
        XCTAssertTrue(LensSourceTile.split("Resources: two vans on site.").sources.isEmpty, "not a marker")
        XCTAssertEqual(LensSourceTile.split("Resources: two vans on site.").prose, "Resources: two vans on site.")
    }

    func testTheSourceTileIsAtMostThreeLinesCutWithAnEllipsis() {
        let many = (1...9).map { "Source: Invented Service Bulletin number \($0), page \($0 * 3)" }.joined(separator: "\n")
        let tile = LensSourceTile.split("Check it.\n" + many)
        let lines = tile.lines(maxChars: chars)
        XCTAssertEqual(lines.count, LensSourceTile.maxLines)
        XCTAssertTrue(lines.last?.hasSuffix("…") ?? false)
        XCTAssertTrue(lines.allSatisfy { $0.count <= chars })
        XCTAssertEqual(LensSourceTile.split("Check it.\nSource: Invented Guide, p. 2").lines(maxChars: chars).count, 1)
        XCTAssertTrue(LensSourceTile.split("Check it.").lines(maxChars: chars).isEmpty)
    }

    private func state(text: String, question: String? = "You: what does E7 mean", complete: Bool = true,
                       followUps: [String] = [], hasPage: Bool = false,
                       earlier: [LensConversationTurn] = []) -> HUDReadingViewState {
        HUDReadingViewState(top: .init(id: 4, question: question, text: text, isComplete: complete,
                                       followUps: followUps, hasPage: hasPage),
                            topIsLatest: true, earlier: earlier)
    }

    private func build(_ state: HUDReadingViewState, _ onAction: @escaping (HUDAnswerAction) -> Void = { _ in }) -> HUDScreen {
        HUDReadingViewBuilder.screen(state, geometry: geometry, onAction: onAction)
    }

    func testTheSourceTileFollowsTheTilesBeforeTheButtonsAndOpensThePage() throws {
        var pressed: [HUDAnswerAction] = []
        let screen = build(state(text: runOnAnswer, hasPage: true)) { pressed.append($0) }
        let blocks = screen.flow.flatMap(\.blocks)
        let tile = try XCTUnwrap(blocks.last)
        XCTAssertEqual(tile.id, HUDReadingViewBuilder.ItemID.sources(turn: 4))
        XCTAssertEqual(tile.style, .card, "focus can rest on it")
        XCTAssertTrue(tile.lines.allSatisfy { $0.emphasis == .meta })
        XCTAssertEqual(tile.lines.map(\.text).joined(separator: " "), "Source: Invented Unit Guide, page 20")
        XCTAssertFalse(blocks.dropLast().contains { $0.lines.contains { $0.text.contains("Source") } },
                       "no tile of prose carries the source")
        tile.action?()
        XCTAssertEqual(pressed, [.page], "the same as Page")
        let noPage = build(state(text: runOnAnswer)).flow.flatMap(\.blocks).last
        XCTAssertNil(noPage?.action, "nothing to open: the tile only takes focus")
        XCTAssertNotNil(noPage?.lines.first { $0.text.hasPrefix("Source:") })
    }

    func testAnAnswerWithNoSourceHasNoSourceTile() {
        let screen = build(state(text: "Isolate it.\nMeasure TP1."))
        XCTAssertFalse(screen.flow.flatMap(\.blocks).contains { $0.id.hasPrefix("mu.sources") })
    }

    func testTheCapsHoldWithTallerTilesAndTheSourceTile() {
        let long = (1...80).map { "Step \($0): check the reading at the X3 plug and write it down. Source: Invented Unit Guide, page \($0)" }
            .joined(separator: "\n")
        let earlier = (1...10).reversed().map {
            LensConversationTurn(id: $0, question: "You: earlier \($0)", answer: String(repeating: "Earlier answer text. ", count: 20),
                                 followUps: [], stagedPage: false, madeAt: Date(timeIntervalSince1970: TimeInterval($0)))
        }
        let screen = build(state(text: long, earlier: earlier))
        XCTAssertLessThanOrEqual(screen.allBlocks.count, HUDReadingViewBuilder.maxRows)
        XCTAssertLessThanOrEqual(HUDReadingViewBuilder.characters(in: screen), HUDReadingViewBuilder.maxCharacters)
        XCTAssertTrue(screen.flow.flatMap(\.blocks).last?.id.hasPrefix("mu.sources") ?? false, "the source tile is kept")
        XCTAssertTrue(screen.flow.contains {
            if case .line(let line) = $0 { return line.text == HUDAnswerPager.moreOnPhoneLine }
            return false
        })
    }

    // MARK: - P2: Earlier

    func testEarlierSaysPressToOpenAndShowsThreeLines() throws {
        XCTAssertEqual(HUDReadingViewBuilder.earlierHeading, "Earlier — press to open")
        let previous = LensConversationTurn(id: 2, question: "You: what is E9", answer: runOnAnswer, followUps: [],
                                            stagedPage: false, madeAt: Date())
        let screen = build(state(text: "Check the supply.", earlier: [previous]))
        guard case .line(let heading) = screen.trailingFlow.first else { return XCTFail("no heading") }
        XCTAssertEqual(heading.text, "Earlier — press to open")
        XCTAssertEqual(heading.emphasis, .meta)
        let folded = try XCTUnwrap(screen.trailingFlow.flatMap(\.blocks).first)
        XCTAssertEqual(folded.lines.count, 4, "the question and three lines")
        XCTAssertTrue(folded.lines.last?.text.hasSuffix("…") ?? false)
        XCTAssertFalse(folded.lines.contains { $0.text.contains("Source") })
    }

    // MARK: - P3: the budget

    private func item(_ id: String, _ label: String) -> HUDItem {
        HUDItem(id: id, label: label, style: .secondary) {}
    }

    func testTheWidthIsTheLabelsAdvancePaddingAndGaps() {
        let budget = LensButtonRowBudget.self
        XCTAssertEqual(budget.width(of: item("a", "Close")), 5 * budget.advancePixels + budget.buttonPaddingPixels)
        XCTAssertEqual(budget.width(of: [item("a", "Page"), item("b", "Close")]),
                       9 * budget.advancePixels + 2 * budget.buttonPaddingPixels + budget.gapPixels)
        XCTAssertGreaterThan(budget.labelWidth("閉じる"), budget.labelWidth("abc"), "a full-width character is wider")
        XCTAssertEqual(budget.columnPixels, 576)
        // P5: a one-character label still makes a button of the lens's minimum width.
        XCTAssertEqual(budget.width(of: item("a", "‹")), budget.minimumButtonPixels)
        XCTAssertEqual(budget.minimumButtonPixels, 88)
        // The photos. Four short zoom buttons all showed: the simulator lays them out at 557 px with
        // the widest focused, and the measured budget errs a little wide of that (594 px), never
        // narrow. Two follow-ups beside Actions and Close did not fit.
        let zoomRow = budget.width(of: [item("1", "Zoom in"), item("2", "Whole page"), item("3", "Move"), item("4", "Close")])
        XCTAssertGreaterThanOrEqual(zoomRow, 557)
        XCTAssertLessThanOrEqual(zoomRow, 557 * 1.1)
        XCTAssertFalse(budget.fits([item("kp.followup.0", "What should the supply read at L and N?"),
                                    item("kp.followup.1", "How do I reseat the X3 plug?"),
                                    item("kp.actions", "Actions"), item("kp.close", "Close")]))
    }

    func testATooWideRowTakesShortFormsThenCutsAFollowUpThenMovesTheLeastImportant() {
        // Too wide with "Next page ›", wide enough with "Next ›".
        let row = [item(HUDPageScreenBuilder.ItemID.rows, String(repeating: "R", count: 10)),
                   item(HUDPageScreenBuilder.ItemID.nextPage, "Next page ›"),
                   item(HUDPageScreenBuilder.ItemID.close, String(repeating: "C", count: 12))]
        XCTAssertFalse(LensButtonRowBudget.fits(row))
        let fitted = LensButtonRowBudget.fit(row, givingWay: [HUDPageScreenBuilder.ItemID.nextPage])
        XCTAssertEqual(fitted.row.first { $0.id == HUDPageScreenBuilder.ItemID.nextPage }?.label, "Next ›")
        XCTAssertTrue(fitted.moved.isEmpty)
        XCTAssertTrue(LensButtonRowBudget.fits(fitted.row))

        let question = "What should the supply read between terminals L and N with the unit running?"
        let follow = LensButtonRowBudget.fit([item("kp.followup.0", question), item("kp.actions", "Actions"),
                                              item("kp.close", "Close")], givingWay: ["kp.followup.0"])
        XCTAssertEqual(follow.ids, ["kp.followup.0", "kp.actions", "kp.close"])
        XCTAssertTrue(follow.row[0].label.hasSuffix("…"), "cut at a word, with an ellipsis")
        XCTAssertTrue(LensButtonRowBudget.fits(follow.row))

        let crowded = LensButtonRowBudget.fit((0..<6).map { item("b\($0)", "Button \($0)") } + [item("kp.close", "Close")],
                                              givingWay: ["b2"])
        XCTAssertTrue(LensButtonRowBudget.fits(crowded.row))
        XCTAssertEqual(crowded.moved.first?.id, "b2", "the named one goes first")
        XCTAssertEqual(crowded.row.last?.id, "kp.close")
    }

    func testCloseIsNeverDropped() {
        let huge = String(repeating: "W", count: 60)
        let fitted = LensButtonRowBudget.fit([item("x", huge), item("y", huge), item("kv.page.close", "Close")])
        XCTAssertEqual(fitted.ids, ["kv.page.close"])
        XCTAssertEqual(fitted.moved.map(\.id), ["x", "y"])
    }

    // MARK: - P3: the reading view's row

    func testTheReadingViewIsAtMostThreeButtonsAndFits() {
        typealias ID = HUDAnswerCardBuilder.ItemID
        let longQuestion = "What should the supply read between terminals L and N with the unit running?"
        let withPage = build(state(text: "Done.", followUps: [longQuestion, "Why?"], hasPage: true))
        XCTAssertEqual(withPage.items.map(\.id), [ID.page, ID.actions, ID.close])
        let noPage = build(state(text: "Done.", followUps: [longQuestion, "Why?"]))
        XCTAssertEqual(noPage.items.map(\.id), [ID.followUp(0), ID.actions, ID.close])
        XCTAssertTrue(noPage.items[0].label.hasSuffix("…"), "the follow-up is cut to fit")
        for screen in [withPage, noPage, build(state(text: "Done.", complete: false, followUps: ["Why?"]))] {
            XCTAssertLessThanOrEqual(screen.items.count, HUDReadingViewBuilder.maxButtons)
            XCTAssertTrue(LensButtonRowBudget.fits(screen.items))
            XCTAssertEqual(screen.items.last?.id, ID.close)
        }
    }

    // MARK: - Through the card

    @MainActor
    private final class Timers {
        var armed: [(delay: TimeInterval, fire: @MainActor () -> Void)] = []
    }

    private func makeCard(reading: Bool = true, lifetime: LensAnswerLifetime = .untilClosed)
        -> (GlassesDisplayService, HUDAnswerCard, Timers) {
        let display = GlassesDisplayService()
        display.testCapabilityOverride = true
        display.testDrawsPicturesOverride = true
        display.testRenderSink = { _ in }
        display.updateGlassesLink(connected: true, worn: true)
        display.applySessionReading(.init(state: .started))
        let card = HUDAnswerCard(display: display)
        card.geometry = { LensPageFrame.answerGeometry }
        card.usesReadingView = { reading }
        card.fitsLensRow = { true }
        card.readingIdleLifetime = { lifetime.idleLifetime }
        let timers = Timers()
        card.scheduleIdleTimer = { delay, fire in timers.armed.append((delay, fire)) }
        return (display, card, timers)
    }

    private func answer(_ card: HUDAnswerCard, _ text: String, followUps: [String] = []) {
        card.beginTurn(question: "what does E7 mean")
        card.finishTurn(reply: text)
        card.offerFollowUps(followUps)
        card.endTurn()
    }

    private let followUps = ["What should the supply read at L and N?", "How do I reseat the X3 plug?",
                             "When should I replace the board?"]

    func testTheReadingViewsActionsScreenListsEveryFollowUp() throws {
        let (_, card, _) = makeCard()
        answer(card, ownLineAnswer, followUps: followUps)
        let view = try XCTUnwrap(card.screenOnLens)
        XCTAssertEqual(view.items.map(\.id).filter { $0.hasPrefix("kp.followup") }, ["kp.followup.0"])
        card.press(.actions)
        let actions = try XCTUnwrap(card.screenOnLens)
        // Every follow-up, the one in the row too, as cards in the column; the row fits.
        let cards = actions.flow.flatMap(\.blocks).map(\.id)
        XCTAssertEqual(cards.filter { $0.hasPrefix("kp.followup") }, ["kp.followup.0", "kp.followup.1", "kp.followup.2"])
        XCTAssertTrue(LensButtonRowBudget.fits(actions.items))
        XCTAssertEqual(actions.items.last?.id, HUDAnswerCardBuilder.ItemID.close)
        XCTAssertTrue(actions.items.contains { $0.id == HUDAnswerCardBuilder.ItemID.answer }, "the way back stays")
    }

    func testAnActionsCardIsPressedAsItsButtonWouldBe() throws {
        let (_, card, _) = makeCard()
        var submitted: [String] = []
        card.submitTurn = { submitted.append($0) }
        answer(card, "Check the supply.", followUps: followUps)
        card.press(.actions)
        let actions = try XCTUnwrap(card.screenOnLens)
        let second = try XCTUnwrap(actions.block(id: HUDAnswerCardBuilder.ItemID.followUp(1)))
        second.action?()
        XCTAssertEqual(submitted, [followUps[1]])
    }

    func testThePagedCardsRowFitsOnTheMetaDisplayAndActionsTakesWhatItLost() throws {
        let (_, card, _) = makeCard(reading: false)
        answer(card, "Check the supply at L and N.", followUps: [
            "What should the supply read between terminals L and N?",
            "How do I reseat the X3 plug on the control board?",
        ])
        let page = try XCTUnwrap(card.screenOnLens)
        XCTAssertTrue(LensButtonRowBudget.fits(page.items))
        let onRow = page.items.filter { $0.id.hasPrefix("kp.followup") }.count
        XCTAssertLessThan(onRow, 2, "both long follow-ups can't sit beside Actions")
        card.press(.actions)
        let actions = try XCTUnwrap(card.screenOnLens)
        let listed = actions.flow.flatMap(\.blocks).map(\.id).filter { $0.hasPrefix("kp.followup") }
        XCTAssertEqual(listed.count, 2 - onRow, "every follow-up the row lost is on Actions")
    }

    func testEvenKeepsItsRowsAsTheyWere() throws {
        let (_, card, _) = makeCard(reading: false)
        card.fitsLensRow = { false }
        answer(card, "Check the supply at L and N.", followUps: [
            "What should the supply read between terminals L and N?",
            "How do I reseat the X3 plug on the control board?",
        ])
        let page = try XCTUnwrap(card.screenOnLens)
        XCTAssertEqual(page.items.map(\.id), [HUDAnswerCardBuilder.ItemID.followUp(0), HUDAnswerCardBuilder.ItemID.followUp(1),
                                              HUDAnswerCardBuilder.ItemID.actions])
    }

    func testTheSpokenAnswerKeepsItsSourceAndOnlyTheLensMovesIt() throws {
        let (_, card, _) = makeCard()
        var spoken: [String] = []
        card.speakAgain = { spoken.append($0) }
        answer(card, runOnAnswer)
        XCTAssertTrue(card.answer.contains("Source: Invented Unit Guide, page 20"), "the answer itself is unchanged")
        card.press(.repeatAnswer)
        XCTAssertEqual(spoken.last, card.answer)
        let screen = try XCTUnwrap(card.screenOnLens)
        XCTAssertTrue(screen.flow.flatMap(\.blocks).last?.id.hasPrefix("mu.sources") ?? false)
    }

    // MARK: - P4: the answer stays

    func testTheReadingViewHasNoIdleTimerUntilClosed() {
        XCTAssertEqual(LensAnswerLifetime.stored(UserDefaults(suiteName: "mu.p4.\(UUID().uuidString)")!), .untilClosed,
                       "Until closed by default")
        XCTAssertNil(LensAnswerLifetime.untilClosed.idleLifetime)
        XCTAssertEqual(LensAnswerLifetime.threeMinutes.idleLifetime, 180)
        let (display, card, timers) = makeCard()
        answer(card, ownLineAnswer)
        XCTAssertTrue(timers.armed.isEmpty)
        card.press(.actions)
        card.press(.answer)
        XCTAssertTrue(timers.armed.isEmpty, "a press arms nothing either")
        XCTAssertTrue(display.showsAnswerCard)
    }

    func testThreeMinutesWhenChosenClearsTheView() {
        let (display, card, timers) = makeCard(lifetime: .threeMinutes)
        answer(card, ownLineAnswer)
        XCTAssertEqual(timers.armed.last?.delay, 180)
        timers.armed.last?.fire()
        XCTAssertFalse(display.showsAnswerCard)
        XCTAssertTrue(card.reopen(), "and it can be brought back")
    }

    func testThePagedCardKeepsItsSixtySeconds() {
        for lifetime in LensAnswerLifetime.allCases {
            let (display, card, timers) = makeCard(reading: false, lifetime: lifetime)
            answer(card, "Check the supply at L and N.")
            XCTAssertEqual(timers.armed.last?.delay, 60, "\(lifetime)")
            XCTAssertEqual(HUDAnswerCard.defaultIdleLifetime, 60)
            timers.armed.last?.fire()
            XCTAssertFalse(display.showsAnswerCard)
        }
    }

    func testTheDisplayComingBackLongAfterKeepsAViewHeldUntilClosed() {
        let (display, card, _) = makeCard()
        var clock = Date(timeIntervalSince1970: 2_000_000)
        card.now = { clock }
        answer(card, ownLineAnswer)
        clock += 45 * 60
        card.displayReturned()
        XCTAssertTrue(display.showsAnswerCard)
        XCTAssertTrue(card.isReadingView)
    }

    func testShowThatAgainWorksForTheConversationsLifeAndGoesWithIt() {
        let (_, card, _) = makeCard()
        var clock = Date(timeIntervalSince1970: 3_000_000)
        card.now = { clock }
        answer(card, ownLineAnswer)
        card.close()
        clock += 2 * 60 * 60
        XCTAssertTrue(card.reopen())
        card.close()
        card.hudTurnedOff()
        XCTAssertFalse(card.canReopen, "the HUD turning off clears it, as it clears the log")
        answer(card, runOnAnswer)
        card.close()
        card.forgetForReopen()
        XCTAssertFalse(card.canReopen, "a private conversation's end clears it")
    }

    func testHideThatAndPutItAwayClose() {
        for phrase in ["hide that", "Hide that.", "ok hide it", "put it away", "put that away", "please put it away"] {
            XCTAssertEqual(HUDAnswerVoiceCommand.parse(phrase), .close, phrase)
            XCTAssertEqual(HUDPageCommand.parse(phrase), .close, phrase)
        }
        for sentence in ["hide that from the customer", "put it away in the van", "hide", "put away the ladder"] {
            XCTAssertNil(HUDAnswerVoiceCommand.parse(sentence), sentence)
        }
    }

    func testTheHideWordsBelongToNoOtherLensCommand() {
        for phrase in ["hide that", "hide it", "put it away", "put that away"] {
            XCTAssertFalse(HUDReopenCommand.matches(phrase), "\(phrase) brings the answer back")
            XCTAssertNil(HUDReadingCommand.parse(phrase), "\(phrase) is a reading word")
            XCTAssertNil(HUDVoiceCommand.parse(phrase), "\(phrase) is a task word")
            XCTAssertFalse(HUDLauncher.isOpenCommand(phrase), "\(phrase) opens the launcher")
            XCTAssertNil(LiveHintsVoiceCommand.parse(phrase), "\(phrase) is a live hints word")
            XCTAssertFalse(HUDRouter.isStopClipCommand(phrase), "\(phrase) stops a clip")
        }
    }
}

/// Plan MU P3: every lens button row fits the 576 px column in each of the 14 complete catalog
/// languages (`LocalizationCatalogGuardTests.completeLanguages`), the languages with the longest
/// labels first. The rows are the builders' own, before the budget, relabelled from
/// `Localizable.xcstrings` (a label the catalog doesn't translate yet stays English, as the app
/// would show it), and fitted with the builders' own giving-way order and the short forms in that
/// language.
@MainActor
final class LensButtonRowLanguageTests: XCTestCase {

    private static var catalogURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("OpenGlasses/Sources/Resources/Localizable.xcstrings")
    }

    private static func loadStrings() throws -> [String: [String: Any]] {
        let data = try Data(contentsOf: catalogURL)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(root["strings"] as? [String: [String: Any]])
    }

    private static func value(_ key: String, in language: String, _ strings: [String: [String: Any]]) -> String {
        let localizations = strings[key]?["localizations"] as? [String: Any]
        let unit = (localizations?[language] as? [String: Any])?["stringUnit"] as? [String: Any]
        return unit?["value"] as? String ?? key
    }

    private struct Row {
        let name: String
        let items: [HUDItem]
        let givingWay: [String]
        var protected: Set<String> = []
        /// Buttons the row must keep in every language (it asks for no more than fits).
        var mustKeep: [String] = []
    }

    private let question = "What should the supply read between terminals L and N with the unit running?"

    private func rows() -> [Row] {
        typealias Card = HUDAnswerCardBuilder
        typealias Page = HUDPageScreenBuilder
        let reading = { (hasPage: Bool, followUps: [String], latest: Bool) -> [HUDItem] in
            HUDReadingViewBuilder.rowItems(HUDReadingViewState(
                top: .init(id: 1, question: nil, text: "Done.", isComplete: true, followUps: followUps, hasPage: hasPage),
                topIsLatest: !latest), { _ in })
        }
        let pages = HUDAnswerPager.pages(for: String(repeating: "word ", count: 160), geometry: LensPageFrame.answerGeometry)
        XCTAssertGreaterThanOrEqual(pages.count, 3)
        let pageRow = { (index: Int) in
            Card.rowItems(pages[index], followUps: [self.question, self.question], hasPage: true, onAction: { _ in })
        }
        let actions = Card.actions(pages, followUps: [], hasPage: true, followUpsOnRow: 0, offersPage: true) { _ in }.items
        var readingMode = HUDPageViewState(viewport: LensPageViewport(wholePage: CGSize(width: 612, height: 792)),
                                           legibility: LensLegibility(), hasNextPage: true)
        readingMode.readingPages = HUDAnswerPager.pages(for: String(repeating: "step ", count: 400),
                                                        geometry: LensPageFrame.readingGeometry, maxPages: 3)
        readingMode.isReading = true
        readingMode.readingIndex = 1
        var lastReading = readingMode
        lastReading.readingIndex = readingMode.readingPages.count - 1
        var whole = HUDPageViewState(viewport: LensPageViewport(wholePage: CGSize(width: 612, height: 792)),
                                     legibility: LensLegibility(), hasNextPage: true)
        whole.readingPages = readingMode.readingPages
        whole.rows = LensPageRows(title: "Table 3 (Invented codes)", rows: [
            .init(label: "E7", text: "E7 · Low supply voltage · Check the supply", headings: "Code · Fault · Action",
                  spoken: "E7. Fault: Low supply voltage."),
        ], highlighted: 0)
        var closeUp = whole
        closeUp.showsRows = true
        return [
            Row(name: "reading view, Page", items: reading(true, [], false),
                givingWay: HUDReadingViewBuilder.rowGivingWay, mustKeep: [Card.ItemID.page, Card.ItemID.actions]),
            Row(name: "reading view, a follow-up", items: reading(false, [question], false),
                givingWay: HUDReadingViewBuilder.rowGivingWay, mustKeep: [Card.ItemID.actions]),
            Row(name: "reading view, an earlier answer", items: reading(false, [], true),
                givingWay: HUDReadingViewBuilder.rowGivingWay, mustKeep: [HUDReadingViewBuilder.ItemID.latest]),
            Row(name: "paged card, first page", items: pageRow(0), givingWay: Card.rowGivingWay,
                mustKeep: [Card.ItemID.next, Card.ItemID.actions]),
            Row(name: "paged card, middle page", items: pageRow(1), givingWay: Card.rowGivingWay,
                mustKeep: [Card.ItemID.next, Card.ItemID.actions]),
            Row(name: "paged card, last page", items: pageRow(pages.count - 1), givingWay: Card.rowGivingWay,
                mustKeep: [Card.ItemID.actions]),
            Row(name: "Actions", items: actions, givingWay: Card.actionsGivingWay, protected: [Card.ItemID.answer],
                mustKeep: [Card.ItemID.answer]),
            Row(name: "page view, whole page", items: Page.rowItems(whole, { _ in }), givingWay: Page.givingWay(for: whole)),
            Row(name: "page view, rows", items: Page.rowItems(closeUp, { _ in }), givingWay: Page.givingWay(for: closeUp),
                mustKeep: [Page.ItemID.back]),
            Row(name: "reading mode, a middle page", items: Page.rowItems(readingMode, { _ in }),
                givingWay: Page.givingWay(for: readingMode), mustKeep: [Page.ItemID.nextText]),
            Row(name: "reading mode, the last page", items: Page.rowItems(lastReading, { _ in }),
                givingWay: Page.givingWay(for: lastReading), mustKeep: [Page.ItemID.showPicture]),
        ]
    }

    func testThereAreFourteenCompleteLanguages() {
        XCTAssertEqual(LocalizationCatalogGuardTests.completeLanguages.count, 14)
    }

    func testEveryLensButtonRowFitsInEveryCompleteLanguageLongestFirst() throws {
        let strings = try Self.loadStrings()
        let rows = rows()
        XCTAssertTrue(rows.allSatisfy { !$0.items.isEmpty })
        let languages = LocalizationCatalogGuardTests.completeLanguages.keys.sorted()
        func relabelled(_ row: Row, _ language: String) -> [HUDItem] {
            row.items.map { item in
                HUDItem(id: item.id, label: Self.value(item.label, in: language, strings), icon: item.icon,
                        style: item.style, action: item.action)
            }
        }
        // Longest labels first: the languages whose rows are widest before fitting.
        let ordered = languages.sorted { a, b in
            let width = { (language: String) in
                rows.reduce(CGFloat(0)) { $0 + LensButtonRowBudget.width(of: relabelled($1, language)) }
            }
            return width(a) > width(b)
        }
        for language in ordered {
            let short = { (id: String) -> String? in
                LensButtonRowBudget.shortLabelKey(for: id).map { Self.value($0, in: language, strings) }
            }
            for row in rows {
                let items = relabelled(row, language)
                let fitted = LensButtonRowBudget.fit(items, givingWay: row.givingWay, protected: row.protected,
                                                     shortLabel: short)
                let where_ = "\(language), \(row.name): \(fitted.row.map(\.label))"
                XCTAssertTrue(LensButtonRowBudget.fits(fitted.row), "too wide: \(where_)")
                XCTAssertTrue(fitted.row.contains { LensButtonRowBudget.isClose($0.id) } || !items.contains { LensButtonRowBudget.isClose($0.id) },
                              "Close dropped: \(where_)")
                for id in row.mustKeep {
                    XCTAssertTrue(fitted.ids.contains(id), "\(id) left the row: \(where_)")
                }
                XCTAssertLessThanOrEqual(fitted.row.count, 7, where_)
            }
        }
    }
}
