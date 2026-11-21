import XCTest
@testable import OpenGlasses

/// Plan MG P2 — the reading view's core, headless: what the lens remembers of the conversation
/// (`LensConversationLog`), the rows an answer is cut into (`HUDReadingRows`), the view built from
/// them (`HUDReadingViewBuilder`), when it is sent (`ReadingRedrawPolicy`) and its words
/// (`HUDReadingCommand`).
@MainActor
final class LensReadingViewTests: XCTestCase {

    private let geometry = LensPageFrame.answerGeometry
    private var chars: Int { HUDReadingRows.maxChars(for: geometry) }

    private func turn(_ id: Int, question: String? = "You: question \(1)", answer: String = "An answer.",
                      followUps: [String] = []) -> LensConversationTurn {
        LensConversationTurn(id: id, question: question, answer: answer, followUps: followUps, stagedPage: false,
                             madeAt: Date(timeIntervalSince1970: TimeInterval(id)))
    }

    // MARK: - The log

    func testTheLogKeepsTheLastTenTurnsNewestFirst() {
        var log = LensConversationLog()
        for id in 1...13 { log.record(turn(id)) }
        XCTAssertEqual(log.count, LensConversationLog.capacity)
        XCTAssertEqual(log.newestFirst.map(\.id), Array((4...13).reversed()))
        XCTAssertEqual(log.latest?.id, 13)
    }

    func testRecordingTheSameTurnAgainKeepsItsPlace() {
        var log = LensConversationLog()
        log.record(turn(1))
        log.record(turn(2))
        log.record(turn(1, answer: "An answer, with its follow-ups now.", followUps: ["Why?"]))
        XCTAssertEqual(log.newestFirst.map(\.id), [2, 1])
        XCTAssertEqual(log.turn(id: 1)?.followUps, ["Why?"])
    }

    func testEarlierListsTheOlderTurnsNewestFirst() {
        var log = LensConversationLog()
        for id in 1...4 { log.record(turn(id)) }
        XCTAssertEqual(log.earlier(than: 4).map(\.id), [3, 2, 1])
        XCTAssertEqual(log.earlier(than: 2).map(\.id), [1])
        XCTAssertEqual(log.turn(before: 3)?.id, 2)
        XCTAssertNil(log.turn(before: 1))
        XCTAssertEqual(log.earlier(than: nil).map(\.id), [4, 3, 2, 1])
        XCTAssertTrue(log.earlier(than: 99).isEmpty, "a turn the log doesn't hold has nothing older in it")
        log.clear()
        XCTAssertTrue(log.isEmpty)
    }

    // MARK: - Rows

    func testEachParagraphIsARowAndALongOneIsSplitAtASentence() {
        // Plan MU §1: past eight lines (it was four), so twice as long as MG's fixture.
        let long = "The nameplate says MOCP 30 A. So use a 30 A double-pole breaker on the condenser circuit. "
            + "Wire it with 10 AWG copper. Check the disconnect is rated for it too. Torque the lugs to spec. "
            + "Then label the panel schedule. Restore power at the disconnect last. Check the unit starts and "
            + "the fan turns. Write the readings on the job sheet before you leave the roof."
        let text = "First, isolate the unit.\n\n\(long)\nDone."
        let rows = HUDReadingRows.rows(for: text, maxChars: chars)
        XCTAssertEqual(rows.first?.lines, ["First, isolate the unit."])
        XCTAssertEqual(rows.last?.lines, ["Done."])
        let middle = rows.filter { $0.paragraph == 1 }
        XCTAssertGreaterThan(middle.count, 1, "a paragraph past eight lines is split")
        XCTAssertTrue(middle.allSatisfy { $0.lines.count <= HUDReadingRows.rowMaxLines })
        XCTAssertTrue(middle[0].startsParagraph)
        XCTAssertFalse(middle[1].startsParagraph)
        XCTAssertTrue(HUDAnswerPager.endsSentence(String(middle[0].text.split(separator: " ").last ?? "")),
                      "the first row ends at a sentence: \(middle[0].text)")
        XCTAssertTrue(rows.allSatisfy { $0.lines.allSatisfy { $0.count <= chars } })
        XCTAssertEqual(rows.map(\.text).joined(separator: " ").split(separator: " ").count,
                       text.split(whereSeparator: { $0.isWhitespace }).count, "no word lost or added")
    }

    func testRowsFitInsideTheCardOnTheLens() {
        XCTAssertLessThan(chars, geometry.maxChars, "the card's padding takes a little of the line")
        XCTAssertGreaterThan(chars, geometry.maxChars - 4)
    }

    func testSettledRowsKeepTheirTextAsTheAnswerStreams() {
        let sentences = (1...24).map { "Sentence number \($0) about the fault is here." }
        var previous: [HUDReadingRow] = []
        var previousSettled = 0
        for count in 1...sentences.count {
            let text = sentences.prefix(count).joined(separator: " ")
            let rows = HUDReadingRows.rows(for: text, maxChars: chars)
            let settled = HUDReadingRows.settledRowCount(for: text, maxChars: chars, isComplete: false)
            XCTAssertLessThanOrEqual(settled, rows.count)
            XCTAssertEqual(Array(rows.prefix(previousSettled)), Array(previous.prefix(previousSettled)),
                           "settled rows changed at \(count) sentences")
            XCTAssertGreaterThanOrEqual(settled, previousSettled)
            previous = rows
            previousSettled = settled
        }
        let whole = sentences.joined(separator: " ")
        XCTAssertEqual(HUDReadingRows.settledRowCount(for: whole, maxChars: chars, isComplete: true),
                       HUDReadingRows.rows(for: whole, maxChars: chars).count, "a final answer is all settled")
    }

    func testAParagraphIsSettledOnceTheNextHasBegun() {
        XCTAssertEqual(HUDReadingRows.settledParagraphCount(for: "One.\nTwo.\nThr", isComplete: false), 2)
        XCTAssertEqual(HUDReadingRows.settledParagraphCount(for: "One.\nTwo.", isComplete: true), 2)
        XCTAssertEqual(HUDReadingRows.settledRowCount(for: "One.\nTwo", maxChars: chars, isComplete: false), 1)
    }

    func testARowSaysTheAnswerAgainFromThereToTheEnd() {
        let rows = HUDReadingRows.rows(for: "Isolate it.\nMeasure TP1.\nThen TP2.", maxChars: chars)
        XCTAssertEqual(HUDReadingRows.spokenText(from: 1, in: rows), "Measure TP1.\nThen TP2.")
        XCTAssertEqual(HUDReadingRows.spokenText(from: 0, in: rows), "Isolate it.\nMeasure TP1.\nThen TP2.")
        XCTAssertEqual(HUDReadingRows.spokenText(from: 9, in: rows), "")
    }

    // MARK: - The view

    private func state(text: String, question: String? = "You: what size breaker", complete: Bool = true,
                       followUps: [String] = [], hasPage: Bool = false,
                       earlier: [LensConversationTurn] = []) -> HUDReadingViewState {
        HUDReadingViewState(top: .init(id: 7, question: question, text: text, isComplete: complete,
                                       followUps: followUps, hasPage: hasPage),
                            topIsLatest: true, earlier: earlier)
    }

    private func build(_ state: HUDReadingViewState, actions: ((HUDAnswerAction) -> Void)? = nil) -> HUDScreen {
        HUDReadingViewBuilder.screen(state, geometry: geometry, onAction: actions ?? { _ in })
    }

    func testTheViewIsTheQuestionTheRowsTheButtonsAndEarlierUnderThem() {
        let screen = build(state(text: "Isolate it.\nMeasure TP1.", earlier: [turn(5), turn(3)]))
        XCTAssertEqual(screen.lines.map(\.text), ["You: what size breaker"])
        XCTAssertEqual(screen.lines.first?.emphasis, .meta)
        let rowIDs = screen.flow.flatMap(\.blocks).map(\.id)
        XCTAssertEqual(rowIDs, [HUDReadingViewBuilder.ItemID.row(turn: 7, index: 0),
                                HUDReadingViewBuilder.ItemID.row(turn: 7, index: 1)])
        XCTAssertTrue(screen.flow.flatMap(\.blocks).allSatisfy { $0.style == .card })
        guard case .line(let heading) = screen.trailingFlow.first else { return XCTFail("no Earlier heading") }
        XCTAssertEqual(heading.text, HUDReadingViewBuilder.earlierHeading)
        XCTAssertEqual(screen.trailingFlow.flatMap(\.blocks).map(\.id),
                       [HUDReadingViewBuilder.ItemID.turn(5), HUDReadingViewBuilder.ItemID.turn(3)],
                       "earlier turns, newest first")
        XCTAssertTrue(screen.focusesFirstBlock)
        XCTAssertNil(screen.resolvedFocusItemID, "no button takes focus, so the lens opens at the top")
    }

    // Plan MU §5 changed MG's two lines to three.
    func testAnEarlierTurnIsItsQuestionAndFirstThreeLines() {
        let answer = String(repeating: "word ", count: 40).trimmingCharacters(in: .whitespaces)
        let lines = HUDReadingViewBuilder.collapsedLines(for: turn(2, question: "You: refrigerant charge", answer: answer),
                                                         maxChars: chars)
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines[0].text, "You: refrigerant charge")
        XCTAssertEqual(lines[0].emphasis, .meta)
        XCTAssertTrue(lines[3].text.hasSuffix("…"), "more follows")
        XCTAssertFalse(lines[2].text.hasSuffix("…"))
        XCTAssertTrue(lines.allSatisfy { $0.text.count <= chars })
        let short = HUDReadingViewBuilder.collapsedLines(for: turn(2, question: nil, answer: "R-410A, 7 lb."), maxChars: chars)
        XCTAssertEqual(short.map(\.text), ["R-410A, 7 lb."])
    }

    // Plan MU §3 (decision 4) changed MG's row: no follow-ups beside Page, one with no page.
    func testTheButtonsArePageOrOneFollowUpThenActionsAndClose() {
        typealias ID = HUDAnswerCardBuilder.ItemID
        let plain = build(state(text: "Done.", followUps: ["Why?", "What next?", "And then?"]))
        XCTAssertEqual(plain.items.map(\.id), [ID.followUp(0), ID.actions, ID.close])
        let paged = build(state(text: "Done.", followUps: ["Why?", "What next?"], hasPage: true))
        XCTAssertEqual(paged.items.map(\.id), [ID.page, ID.actions, ID.close])
        let streaming = build(state(text: "Done.", complete: false, followUps: ["Why?"]))
        XCTAssertEqual(streaming.items.map(\.id), [ID.actions, ID.close], "no follow-ups until the answer is final")
        for screen in [plain, paged, streaming] {
            XCTAssertLessThanOrEqual(screen.items.count, HUDReadingViewBuilder.maxButtons)
            XCTAssertTrue(HUDExit.hasExit(screen))
        }
    }

    func testAnOpenedEarlierTurnShowsWholeWithLatestAndClose() {
        var opened = state(text: "R-410A, 7 lb 4 oz factory charge.\nCheck the subcooling.", earlier: [turn(1)])
        opened.topIsLatest = false
        let screen = build(opened)
        XCTAssertEqual(screen.items.map(\.id), [HUDReadingViewBuilder.ItemID.latest, HUDAnswerCardBuilder.ItemID.close])
        XCTAssertEqual(screen.flow.flatMap(\.blocks).count, 2, "the whole answer, row by row")
        XCTAssertEqual(screen.trailingFlow.flatMap(\.blocks).map(\.id), [HUDReadingViewBuilder.ItemID.turn(1)])
    }

    func testPressesReportRepeatFromARowAndOpenAnEarlierTurn() {
        var reported: [HUDAnswerAction] = []
        let screen = build(state(text: "Isolate it.\nMeasure TP1.", earlier: [turn(4)]), actions: { reported.append($0) })
        screen.flow.flatMap(\.blocks)[1].action?()
        screen.trailingFlow.flatMap(\.blocks)[0].action?()
        XCTAssertEqual(reported, [.repeatFrom(row: 1, text: "Measure TP1."), .openTurn(id: 4)])
    }

    func testTheCapsDropTheOldestEarlierTurnsFirst() {
        let earlier = (1...10).reversed().map { turn($0, answer: String(repeating: "x", count: 300)) }
        let top = (1...35).map { "Paragraph \($0)." }.joined(separator: "\n")
        let screen = build(state(text: top, earlier: earlier))
        let earlierIDs = screen.trailingFlow.flatMap(\.blocks).map(\.id)
        XCTAssertEqual(screen.allBlocks.count, HUDReadingViewBuilder.maxRows)
        XCTAssertEqual(earlierIDs, (6...10).reversed().map { HUDReadingViewBuilder.ItemID.turn($0) },
                       "the newest five earlier turns stay")
        XCTAssertEqual(screen.flow.flatMap(\.blocks).count, 35, "the answer is whole")
        XCTAssertLessThanOrEqual(HUDReadingViewBuilder.characters(in: screen), HUDReadingViewBuilder.maxCharacters)
    }

    func testPastTheCapsTheAnswerEndsInMoreOnPhone() {
        let long = (1...80).map { "Step \($0): check the reading at this point and write it down." }.joined(separator: "\n")
        let screen = build(state(text: long, earlier: [turn(1)]))
        XCTAssertTrue(screen.trailingFlow.isEmpty, "earlier turns go before the answer is cut")
        guard case .line(let last) = screen.flow.last else { return XCTFail("no closing line") }
        XCTAssertEqual(last.text, HUDAnswerPager.moreOnPhoneLine)
        XCTAssertLessThanOrEqual(screen.allBlocks.count, HUDReadingViewBuilder.maxRows)
        XCTAssertLessThanOrEqual(HUDReadingViewBuilder.characters(in: screen), HUDReadingViewBuilder.maxCharacters)
    }

    func testTheRenderKeyFollowsTheRowsAndTheEarlierTurns() {
        let one = build(state(text: "Isolate it."))
        let two = build(state(text: "Isolate it.\nMeasure TP1."))
        let three = build(state(text: "Isolate it.", earlier: [turn(1)]))
        XCTAssertNotEqual(one.renderKey, two.renderKey)
        XCTAssertNotEqual(one.renderKey, three.renderKey)
        XCTAssertEqual(one.renderKey, build(state(text: "Isolate it.")).renderKey)
    }

    // MARK: - When it is sent

    func testTheViewIsSentAtSettlePointsAndOnceComplete() {
        var policy = ReadingRedrawPolicy()
        typealias P = ReadingRedrawPolicy.Progress
        XCTAssertFalse(policy.textChanged(P(settledRows: 0, settledParagraphs: 0, isComplete: false)),
                       "nothing settled yet")
        XCTAssertTrue(policy.textChanged(P(settledRows: 1, settledParagraphs: 0, isComplete: false)), "the first draw")
        XCTAssertFalse(policy.textChanged(P(settledRows: 3, settledParagraphs: 0, isComplete: false)),
                       "more rows of the same paragraph wait")
        XCTAssertTrue(policy.textChanged(P(settledRows: 4, settledParagraphs: 1, isComplete: false)),
                      "a paragraph settled")
        XCTAssertTrue(policy.textChanged(P(settledRows: 6, settledParagraphs: 2, isComplete: true)), "the final draw")
        XCTAssertTrue(policy.drewComplete)
        XCTAssertFalse(policy.textChanged(P(settledRows: 6, settledParagraphs: 2, isComplete: true)),
                       "never again for the text")
        policy.reset()
        XCTAssertTrue(policy.textChanged(P(settledRows: 0, settledParagraphs: 0, isComplete: true)),
                      "a short answer that came whole draws at once")
    }

    // MARK: - The words

    func testTheReadingWordsAreWholeUtterancesOnly() {
        XCTAssertEqual(HUDReadingCommand.parse("earlier"), .earlier)
        XCTAssertEqual(HUDReadingCommand.parse("OK, previous answer please"), .earlier)
        XCTAssertEqual(HUDReadingCommand.parse("Latest."), .latest)
        XCTAssertEqual(HUDReadingCommand.parse("back to the latest answer"), .latest)
        XCTAssertEqual(HUDReadingCommand.parse("say that again"), .sayAgain)
        for sentence in ["what was the earlier reading", "previous", "the latest firmware", "say that again slower",
                         "show the conversation", "show that again", "repeat", "earlier today I checked TP1"] {
            XCTAssertNil(HUDReadingCommand.parse(sentence), sentence)
        }
    }

    func testTheReadingWordsBelongToNoOtherLensCommand() {
        for phrase in HUDReadingCommand.phrases.keys {
            XCTAssertFalse(HUDReopenCommand.matches(phrase), "\(phrase) brings the answer back")
            XCTAssertNil(HUDPageCommand.parse(phrase), "\(phrase) belongs to the page view")
            XCTAssertNil(HUDAnswerVoiceCommand.parse(phrase), "\(phrase) is a paging word")
            XCTAssertNil(HUDVoiceCommand.parse(phrase), "\(phrase) is a task word")
            XCTAssertFalse(HUDLauncher.isOpenCommand(phrase), "\(phrase) opens the launcher")
        }
        for phrase in HUDReopenCommand.phrases {
            XCTAssertNil(HUDReadingCommand.parse(phrase), "\(phrase) is the reopen word")
        }
    }
}
