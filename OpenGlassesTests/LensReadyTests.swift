#if !AVENKIN_PHONE_ONLY
import Combine
import XCTest
@testable import OpenGlasses

/// Plan KX P2–P3: the approval card, the Listening → Thinking states, and the Today glance as the
/// launcher's root. Headless: the builders directly, the service through `testRenderSink`, timers
/// through the controllers' scheduling seams, the band by firing the rendered buttons.
@MainActor
final class LensReadyTests: XCTestCase {

    private var savedDisplayEnabled = false
    private var savedBackend: String?
    /// The controllers a test made. The coordinator's subscription and the display's handlers hold
    /// them weakly (as AppState's lazy properties are the real owners), so a test that never names
    /// its card again would otherwise lose it at once.
    private var retained: [AnyObject] = []

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
        LensMicPolicy.metaDisplayPresent = false
        retained = []
        try await super.tearDown()
    }

    // MARK: - Rig

    private final class Frames {
        var frames: [GlassesDisplayService.HUDFrame] = []
    }

    /// Timers a controller asked for, fired by the test.
    private final class Timers {
        var fires: [(delay: TimeInterval, fire: @MainActor () -> Void)] = []
        /// The short ones: the throttle's trailing sends (the lifetimes and the timeout are longer).
        var trailing: [(delay: TimeInterval, fire: @MainActor () -> Void)] { fires.filter { $0.delay < 1 } }
    }

    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_000)
    }

    private func makeDisplay() -> (GlassesDisplayService, Frames) {
        let display = GlassesDisplayService()
        display.testCapabilityOverride = true
        let frames = Frames()
        display.testRenderSink = { frames.frames.append($0) }
        display.updateGlassesLink(connected: true, worn: true)
        display.applySessionReading(.init(state: .started))
        return (display, frames)
    }

    /// Let the render queue's task run.
    private func drain() async {
        for _ in 0..<8 { await Task.yield() }
    }

    private func item(_ id: String, _ style: HUDButtonStyle) -> HUDItem {
        HUDItem(id: id, label: id, style: style) {}
    }

    private func taskCard(_ title: String) -> HUDScreen {
        HUDScreen(title: title, items: [item("done", .primary), item("back", .outline)])
    }

    /// Fire the rendered button `id` on `screen`, as the band would, and let the selection arrive:
    /// the Meta button's `onClick` hops to the main actor in a `Task`, so it lands a turn later.
    private func press(_ id: String, on screen: HUDScreen?, _ display: GlassesDisplayService) async {
        guard let screen, let index = screen.items.firstIndex(where: { $0.id == id }) else {
            return XCTFail("no item '\(id)' on the screen")
        }
        display.testInteractiveButtonActions(for: screen)[index]()
        await drain()
    }

    // MARK: - P2: the approval card's screens

    func testTheCardNamesTheActionAsAQuestionWithOnePreviewLine() {
        let screen = HUDApprovalCardBuilder.card(summary: "Send a message to Sam: “meet at 8”",
                                                 source: .assistant, onAction: { _ in })
        XCTAssertEqual(screen.title, "Send a message to Sam?")
        XCTAssertEqual(screen.lines.count, 2)
        XCTAssertEqual(screen.lines[0].icon, .warning)
        XCTAssertEqual(screen.lines[0].emphasis, .meta)
        XCTAssertEqual(screen.lines[0].text, HUDApprovalCardBuilder.sourceLine(.assistant))
        XCTAssertEqual(screen.lines[1].text, "“meet at 8”")
        XCTAssertEqual(screen.items.map(\.id), [HUDApprovalCardBuilder.ItemID.approve,
                                                HUDApprovalCardBuilder.ItemID.deny],
                       "nothing more on the phone, so no Details")
        XCTAssertEqual(screen.items.first?.style, .primary)
        XCTAssertEqual(screen.resolvedFocusItemID, HUDApprovalCardBuilder.ItemID.approve)
        XCTAssertTrue(HUDExit.hasExit(screen), "Deny is the way out")
    }

    func testAShortAskIsAllHeading() {
        let parts = HUDApprovalCardBuilder.parts(of: "Call Sam")
        XCTAssertEqual(parts, .init(heading: "Call Sam?", preview: nil, hasMore: false))
        XCTAssertEqual(HUDApprovalCardBuilder.parts(of: "Send a message to Dr. Smith").heading,
                       "Send a message to Dr. Smith?", "a full stop inside the action does not split it")
    }

    func testAQuestionFirstSentenceIsTheHeading() {
        let parts = HUDApprovalCardBuilder.parts(of: "Remember this face as Sam? They won't be told.")
        XCTAssertEqual(parts.heading, "Remember this face as Sam?")
        XCTAssertEqual(parts.preview, "They won't be told.")
        XCTAssertFalse(parts.hasMore)
    }

    func testAnActionTooLongForAHeadingGetsTheGenericOneAndDetailsWhenCut() {
        let long = "Ask the OpenClaw gateway on the office machine to reorganise every folder"
        let parts = HUDApprovalCardBuilder.parts(of: long)
        XCTAssertEqual(parts.heading, HUDApprovalCardBuilder.genericHeading)
        XCTAssertEqual(parts.preview, long)
        XCTAssertFalse(parts.hasMore)

        let body = String(repeating: "word ", count: 60)
        let screen = HUDApprovalCardBuilder.card(summary: "Send a message to Sam: \(body)", source: .gateway,
                                                 onAction: { _ in })
        XCTAssertEqual(screen.title, "Send a message to Sam?")
        XCTAssertLessThanOrEqual(screen.lines[1].text.count, HUDTextShaper.maxBodyLength + 1)
        XCTAssertEqual(screen.items.map(\.id).last, HUDApprovalCardBuilder.ItemID.details)
        XCTAssertEqual(screen.lines[0].text, HUDApprovalCardBuilder.sourceLine(.gateway))
    }

    func testDetailsShowsTheAskFocusesBackAndSaysWhenThePhoneHasTheRest() {
        let body = String(repeating: "word ", count: 200)
        let screen = HUDApprovalCardBuilder.details(summary: "Send a message to Sam: \(body)",
                                                    source: .assistant, onAction: { _ in })
        XCTAssertEqual(screen.items.map(\.id), [HUDApprovalCardBuilder.ItemID.approve,
                                                HUDApprovalCardBuilder.ItemID.deny,
                                                HUDApprovalCardBuilder.ItemID.back])
        XCTAssertEqual(screen.resolvedFocusItemID, HUDApprovalCardBuilder.ItemID.back)
        XCTAssertEqual(screen.lines.count, 1 + HUDApprovalCardBuilder.maxDetailLines + 1)
        XCTAssertEqual(screen.lines.last?.emphasis, .meta, "the rest is on the phone")
        XCTAssertTrue(HUDExit.hasExit(screen))

        let short = HUDApprovalCardBuilder.details(summary: "Call Sam", source: .assistant, onAction: { _ in })
        XCTAssertEqual(short.lines.map(\.text).dropFirst(), ["Call Sam"])
    }

    func testTheWrapKeepsWholeWordsAndSaysWhenItCut() {
        let wrapped = HUDApprovalCardBuilder.wrap("one two three four five", width: 9, maxLines: 2)
        XCTAssertEqual(wrapped.lines, ["one two", "three"])
        XCTAssertTrue(wrapped.cut)
        let all = HUDApprovalCardBuilder.wrap("one two", width: 9, maxLines: 2)
        XCTAssertEqual(all.lines, ["one two"])
        XCTAssertFalse(all.cut)
    }

    // MARK: - P2: the approval card on the lens

    private func makeApproval(_ display: GlassesDisplayService)
        -> (ToolConfirmationCoordinator, HUDApprovalCard, Timers) {
        let coordinator = ToolConfirmationCoordinator()
        let card = HUDApprovalCard(display: display, coordinator: coordinator)
        let timers = Timers()
        card.scheduleTimeout = { delay, fire in timers.fires.append((delay, fire)) }
        card.start()
        retained.append(card)
        return (coordinator, card, timers)
    }

    /// Ask, and wait for the ask to be pending.
    private func ask(_ coordinator: ToolConfirmationCoordinator,
                     _ summary: String = "Send a message to Sam: “hi”") async -> Task<Bool, Never> {
        let task = Task { await coordinator.requestConfirmation(toolName: "send_message", summary: summary) }
        for _ in 0..<50 where coordinator.pending == nil { await Task.yield() }
        XCTAssertNotNil(coordinator.pending)
        return task
    }

    func testAnApprovalIsAHeldCardThatApproveAnswers() async {
        let (display, frames) = makeDisplay()
        let (coordinator, card, _) = makeApproval(display)
        let asked = await ask(coordinator)
        XCTAssertTrue(display.showsApprovalCard)
        XCTAssertTrue(card.isShowing)
        await drain()
        XCTAssertEqual(frames.frames.last, .screen(renderKey: card.screenOnLens?.renderKey ?? ""))

        await press(HUDApprovalCardBuilder.ItemID.approve, on: card.screenOnLens, display)
        let approved = await asked.value
        XCTAssertTrue(approved)
        XCTAssertFalse(display.showsApprovalCard)
        XCTAssertFalse(display.isInteractive)
        await drain()
        XCTAssertEqual(frames.frames.last, .clear, "nothing was held under it")
    }

    func testDenyAnswersNo() async {
        let (display, _) = makeDisplay()
        let (coordinator, card, _) = makeApproval(display)
        let asked = await ask(coordinator)
        await press(HUDApprovalCardBuilder.ItemID.deny, on: card.screenOnLens, display)
        let approved = await asked.value
        XCTAssertFalse(approved)
        XCTAssertFalse(display.showsApprovalCard)
    }

    func testTheTimeoutDenies() async {
        let (display, _) = makeDisplay()
        let (coordinator, _, timers) = makeApproval(display)
        let asked = await ask(coordinator)
        XCTAssertEqual(timers.fires.count, 1)
        XCTAssertEqual(timers.fires[0].delay, HUDApprovalCard.defaultTimeout)
        timers.fires[0].fire()
        let approved = await asked.value
        XCTAssertFalse(approved, "decision 4: an unanswered card denies")
        XCTAssertFalse(display.showsApprovalCard)
    }

    func testATimerFromAnEarlierAskDoesNothing() async {
        let (display, _) = makeDisplay()
        let (coordinator, _, timers) = makeApproval(display)
        let first = await ask(coordinator)
        coordinator.resolve(true)
        _ = await first.value
        let second = await ask(coordinator)
        timers.fires[0].fire()          // the first ask's timer
        XCTAssertNotNil(coordinator.pending, "the second ask still waits")
        coordinator.resolve(true)
        let approved = await second.value
        XCTAssertTrue(approved)
    }

    func testAVoiceYesAnswersAndClosesTheCard() async {
        let (display, _) = makeDisplay()
        let (coordinator, card, _) = makeApproval(display)
        let asked = await ask(coordinator)
        XCTAssertTrue(coordinator.resolveByVoice("yes"))
        let approved = await asked.value
        XCTAssertTrue(approved)
        XCTAssertFalse(card.isShowing)
        XCTAssertFalse(display.showsApprovalCard)
    }

    func testDetailsAndBackStayOnTheCard() async {
        let (display, _) = makeDisplay()
        let (coordinator, card, _) = makeApproval(display)
        let body = String(repeating: "word ", count: 60)
        let asked = await ask(coordinator, "Send a message to Sam: \(body)")
        await press(HUDApprovalCardBuilder.ItemID.details, on: card.screenOnLens, display)
        XCTAssertTrue(card.isOnDetails)
        XCTAssertEqual(display.heldScreenRenderKey, card.screenOnLens?.renderKey)
        await press(HUDApprovalCardBuilder.ItemID.back, on: card.screenOnLens, display)
        XCTAssertFalse(card.isOnDetails)
        XCTAssertNotNil(coordinator.pending, "reading more answers nothing")
        coordinator.resolve(false)
        _ = await asked.value
    }

    func testAPressUnderANotificationIsStale() async {
        let (display, _) = makeDisplay()
        let (coordinator, card, _) = makeApproval(display)
        let asked = await ask(coordinator)
        let screen = card.screenOnLens
        display.showNotification(title: "Reminder", body: "Call Sam")
        await press(HUDApprovalCardBuilder.ItemID.approve, on: screen, display)
        XCTAssertNotNil(coordinator.pending, "a press made under the notification is dropped")
        coordinator.resolve(false)
        _ = await asked.value
    }

    func testTheTaskCardUnderTheApprovalComesBackAsItNowIs() async {
        let (display, frames) = makeDisplay()
        display.present(screen: taskCard("Step 1"), onSelect: { _ in })
        let (coordinator, card, _) = makeApproval(display)
        let asked = await ask(coordinator)
        XCTAssertEqual(display.heldScreenRenderKey, card.screenOnLens?.renderKey)

        let step2 = taskCard("Step 2")
        display.present(screen: step2, onSelect: { _ in })
        XCTAssertEqual(display.heldScreenRenderKey, card.screenOnLens?.renderKey,
                       "a step that changed goes under the card, never over it")

        coordinator.resolve(true)
        _ = await asked.value
        XCTAssertTrue(display.isInteractive)
        XCTAssertEqual(display.heldScreenRenderKey, step2.renderKey)
        await drain()
        XCTAssertEqual(frames.frames.last, .screen(renderKey: step2.renderKey))
    }

    func testATaskThatEndsUnderTheCardDoesNotComeBack() async {
        let (display, _) = makeDisplay()
        display.present(screen: taskCard("Step 1"), onSelect: { _ in })
        let (coordinator, card, _) = makeApproval(display)
        let asked = await ask(coordinator)
        display.endInteractive()        // the task finished under the card
        XCTAssertTrue(card.isShowing, "the approval stays")
        coordinator.resolve(false)
        _ = await asked.value
        XCTAssertFalse(display.isInteractive)
    }

    func testATextAskKeepsTheLine() async {
        let (display, frames) = makeDisplay()
        let (coordinator, card, timers) = makeApproval(display)
        let task = Task { await coordinator.requestTextAnswer(toolName: "code_agent", summary: "Which files?",
                                                             prefill: "") }
        for _ in 0..<50 where coordinator.pending == nil { await Task.yield() }
        XCTAssertFalse(card.isShowing)
        XCTAssertFalse(display.showsApprovalCard)
        XCTAssertTrue(timers.fires.isEmpty, "only the card times out")
        await drain()
        guard case .content(_, let title, _) = frames.frames.last else { return XCTFail("\(frames.frames)") }
        XCTAssertEqual(title, HUDApprovalCardBuilder.genericHeading)
        coordinator.resolveText("all of them")
        _ = await task.value
    }

    func testADismissedLensGetsTheLineNotTheCard() async {
        let (display, _) = makeDisplay()
        display.lensEndedByDevice()
        let (coordinator, card, timers) = makeApproval(display)
        let asked = await ask(coordinator)
        XCTAssertFalse(card.isShowing)
        XCTAssertTrue(display.lensDismissed, "an approval is not wearer-led")
        XCTAssertTrue(timers.fires.isEmpty)
        coordinator.resolve(false)
        _ = await asked.value
    }

    func testAPageViewDoesNotOpenOverTheCard() async {
        let (display, _) = makeDisplay()
        let (coordinator, card, _) = makeApproval(display)
        let asked = await ask(coordinator)
        XCTAssertFalse(display.presentPageView(HUDScreen(title: "Page", items: [item("close", .outline)]),
                                               kind: .view, onSelect: { _ in }))
        XCTAssertEqual(display.heldScreenRenderKey, card.screenOnLens?.renderKey)
        coordinator.resolve(false)
        _ = await asked.value
    }

    // MARK: - P3: the Listening and Thinking screens

    func testTheListeningCardShowsTheNewestWordsWithStop() {
        let empty = HUDTurnStateBuilder.listening(partial: nil, onStop: {})
        XCTAssertEqual(empty.title, HUDTurnStateBuilder.listeningTitle)
        XCTAssertTrue(empty.lines.isEmpty)
        XCTAssertEqual(empty.items.map(\.id), [HUDTurnStateBuilder.ItemID.stop])
        XCTAssertEqual(empty.resolvedFocusItemID, HUDTurnStateBuilder.ItemID.stop)
        XCTAssertTrue(HUDExit.hasExit(empty))

        let card = HUDTurnStateBuilder.listening(partial: "what size breaker", onStop: {})
        XCTAssertEqual(card.lines.map(\.text), ["what size breaker"])
        XCTAssertEqual(card.lines.first?.emphasis, .primary, "body style")

        let long = (1...60).map { "w\($0)" }.joined(separator: " ")
        let tail = HUDTurnStateBuilder.tail(long, max: 40)
        XCTAssertLessThanOrEqual(tail.count, 40)
        XCTAssertTrue(tail.hasPrefix("…"))
        XCTAssertTrue(tail.hasSuffix("w60"), "the newest words stay")
        XCTAssertFalse(tail.contains(" w1 "))
    }

    func testTheThinkingCardShowsWhatWasHeard() {
        let card = HUDTurnStateBuilder.thinking(question: "what size breaker", lineChars: 32, onStop: {})
        XCTAssertEqual(card.title, HUDTurnStateBuilder.thinkingTitle)
        XCTAssertEqual(card.lines.count, 1)
        XCTAssertEqual(card.lines.first?.text,
                       HUDAnswerCardBuilder.questionLine(for: "what size breaker", maxChars: 32))
        XCTAssertEqual(card.lines.first?.emphasis, .meta)
        XCTAssertTrue(HUDExit.hasExit(card))
        XCTAssertTrue(HUDTurnStateBuilder.thinking(question: nil, lineChars: 32, onStop: {}).lines.isEmpty)
    }

    func testTheThrottleAllowsOnePartialPerGapAndTheFinalAlways() {
        var throttle = HUDPartialThrottle()
        let t0 = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(throttle.decision(at: t0, isFinal: false), .sendNow, "the first goes at once")
        throttle.sent(at: t0)
        guard case .wait(let delay) = throttle.decision(at: t0.addingTimeInterval(0.1), isFinal: false) else {
            return XCTFail("inside the gap")
        }
        XCTAssertEqual(delay, 0.3, accuracy: 0.001)
        XCTAssertEqual(throttle.decision(at: t0.addingTimeInterval(0.1), isFinal: true), .sendNow)
        XCTAssertEqual(throttle.decision(at: t0.addingTimeInterval(0.4), isFinal: false), .sendNow)
        XCTAssertEqual(throttle.decision(at: t0.addingTimeInterval(-5), isFinal: false), .sendNow,
                       "a clock that went backwards waits for nothing")
        throttle.reset()
        XCTAssertNil(throttle.lastSentAt)
        XCTAssertEqual(HUDPartialThrottle.gap, HUDSendPacer.textGap)
    }

    // MARK: - P3: the turn on the lens

    private func makeTurn(_ display: GlassesDisplayService) -> (HUDTurnState, Clock, Timers) {
        let turn = HUDTurnState(display: display)
        let clock = Clock()
        let timers = Timers()
        turn.now = { clock.now }
        turn.schedule = { delay, fire in timers.fires.append((delay, fire)) }
        turn.geometry = { .raybanDisplay }
        retained.append(turn)
        return (turn, clock, timers)
    }

    func testPartialsArePacedAndTheFinalAlwaysGoes() {
        let (display, _) = makeDisplay()
        let (turn, clock, timers) = makeTurn(display)
        turn.beginListening()
        XCTAssertEqual(turn.phase, .listening)
        XCTAssertTrue(display.showsTurnState)

        clock.now += 0.1
        turn.partial("what")
        XCTAssertEqual(turn.shownPartial, "", "inside the gap it waits")
        turn.partial("what size")
        XCTAssertEqual(timers.trailing.count, 1, "one trailing send per gap")
        XCTAssertEqual(timers.trailing[0].delay, 0.3, accuracy: 0.001)

        clock.now += 0.3
        timers.trailing[0].fire()
        XCTAssertEqual(turn.shownPartial, "what size", "the newest partial goes when the gap ends")

        clock.now += 0.1
        turn.heard("what size breaker")
        XCTAssertEqual(turn.shownPartial, "what size breaker", "the final is never held back")
        XCTAssertEqual(turn.screenOnLens?.lines.first?.text, "what size breaker")
        XCTAssertEqual(display.heldScreenRenderKey, turn.screenOnLens?.renderKey)
    }

    func testThinkingThenTheAnswerCardReplacesIt() {
        let (display, _) = makeDisplay()
        let (turn, _, _) = makeTurn(display)
        turn.beginListening()
        turn.heard("what size breaker")
        turn.thinking(question: "what size breaker")
        XCTAssertEqual(turn.phase, .thinking)
        XCTAssertEqual(turn.screenOnLens?.title, HUDTurnStateBuilder.thinkingTitle)
        XCTAssertTrue(display.acceptsAnswerCard, "the turn's card waits for its answer")

        var answer = HUDScreen(lines: [HUDLine("A 20 amp breaker.")],
                               items: [item(HUDAnswerCardBuilder.ItemID.actions, .secondary)])
        answer.pageSet = HUDPageSet(pages: [answer], index: 0, card: 1)
        XCTAssertTrue(display.presentAnswerCard(answer, onSelect: { _ in }))
        XCTAssertFalse(display.showsTurnState)
        turn.processingEnded()
        XCTAssertTrue(display.showsAnswerCard, "the turn ending leaves the answer card")
        XCTAssertEqual(display.heldScreenRenderKey, answer.renderKey)
    }

    func testNeverOverATaskCardOrAPageView() {
        let (display, frames) = makeDisplay()
        let (turn, _, _) = makeTurn(display)
        let task = taskCard("Torque the bolts")
        display.present(screen: task, onSelect: { _ in })
        turn.beginListening()
        XCTAssertEqual(turn.phase, .idle)
        XCTAssertFalse(display.showsTurnState)
        XCTAssertEqual(display.heldScreenRenderKey, task.renderKey)
        _ = frames

        display.endInteractive()
        XCTAssertTrue(display.presentPageView(HUDScreen(title: "Page", items: [item("close", .outline)]),
                                              kind: .view, onSelect: { _ in }))
        turn.beginListening()
        XCTAssertEqual(turn.phase, .idle)
        XCTAssertFalse(display.showsTurnState)
    }

    func testListeningReplacesAnAnswerCardTheWearerAsksOver() {
        let (display, _) = makeDisplay()
        let (turn, _, _) = makeTurn(display)
        var answer = HUDScreen(lines: [HUDLine("Earlier answer.")], items: [item("kp.close", .outline)])
        answer.pageSet = HUDPageSet(pages: [answer], index: 0, card: 3)
        XCTAssertTrue(display.presentAnswerCard(answer, onSelect: { _ in }))
        turn.beginListening()
        XCTAssertTrue(display.showsTurnState)
        XCTAssertFalse(display.showsAnswerCard)
    }

    func testAnEmptyFinalClearsTheCard() async {
        let (display, frames) = makeDisplay()
        let (turn, _, _) = makeTurn(display)
        turn.beginListening()
        await drain()
        turn.heard("   ")
        XCTAssertEqual(turn.phase, .idle)
        XCTAssertFalse(display.isInteractive)
        await drain()
        XCTAssertEqual(frames.frames.last, .clear)
    }

    func testAFailedTurnClearsWhenProcessingStopsAndALateLifetimeDoesNothing() async {
        let (display, frames) = makeDisplay()
        let (turn, _, timers) = makeTurn(display)
        turn.beginListening()
        turn.heard("what size breaker")
        turn.thinking()
        turn.processingEnded()
        XCTAssertFalse(display.showsTurnState)
        await drain()
        XCTAssertEqual(frames.frames.last, .clear)
        let count = frames.frames.count
        for timer in timers.fires { timer.fire() }   // every lifetime is from an older generation
        await drain()
        XCTAssertEqual(frames.frames.count, count)
    }

    func testTheLifetimeClearsAStuckThinkingCard() {
        let (display, _) = makeDisplay()
        let (turn, _, timers) = makeTurn(display)
        turn.beginListening()
        turn.thinking(question: "what size breaker")
        let lifetime = timers.fires.last
        XCTAssertEqual(lifetime?.delay, HUDTurnState.thinkingLifetime)
        lifetime?.fire()
        XCTAssertEqual(turn.phase, .idle)
        XCTAssertFalse(display.showsTurnState)
    }

    func testAWearerStartedTurnReopensADismissedLensButAPartialDoesNot() {
        let (display, _) = makeDisplay()
        let (turn, _, _) = makeTurn(display)
        display.lensEndedByDevice()
        turn.beginListening()
        XCTAssertFalse(display.lensDismissed, "the wearer started this turn")
        XCTAssertTrue(display.showsTurnState)

        display.lensEndedByDevice()
        turn.partial("hello")
        XCTAssertTrue(display.lensDismissed, "a partial is not wearer-led")
        XCTAssertEqual(turn.phase, .idle)
    }

    func testGuidanceTakesTheLensFromTheTurnCard() async {
        let (display, frames) = makeDisplay()
        let (turn, _, _) = makeTurn(display)
        turn.beginListening()
        display.showNavigation("Turn left")
        XCTAssertFalse(display.showsTurnState)
        await drain()
        XCTAssertEqual(frames.frames.last, .content(body: "Turn left", title: nil, icon: .navigation))
        turn.partial("what")
        XCTAssertEqual(turn.phase, .idle, "the turn's card is gone; nothing redraws it")
    }

    func testStopOnListeningStopsCaptureAndOnThinkingCancels() async {
        let (display, _) = makeDisplay()
        let (turn, _, _) = makeTurn(display)
        var stopped = 0
        var cancelled = 0
        turn.onStopListening = { stopped += 1 }
        turn.onCancelTurn = { cancelled += 1 }
        turn.beginListening()
        await press(HUDTurnStateBuilder.ItemID.stop, on: turn.screenOnLens, display)
        XCTAssertEqual(stopped, 1)
        turn.thinking(question: "what size breaker")
        await press(HUDTurnStateBuilder.ItemID.stop, on: turn.screenOnLens, display)
        XCTAssertEqual(cancelled, 1)
        XCTAssertFalse(display.showsTurnState)
    }

    func testAnApprovalOverThinkingGivesThinkingBack() async {
        let (display, _) = makeDisplay()
        let (turn, _, _) = makeTurn(display)
        turn.beginListening()
        turn.thinking(question: "send it to Sam")
        let thinking = turn.screenOnLens
        let (coordinator, _, _) = makeApproval(display)
        let asked = await ask(coordinator)
        XCTAssertFalse(display.showsTurnState)
        XCTAssertFalse(display.acceptsTurnState, "nothing of the turn's over an approval")
        coordinator.resolve(true)
        _ = await asked.value
        XCTAssertTrue(display.showsTurnState)
        XCTAssertEqual(display.heldScreenRenderKey, thinking?.renderKey)
    }

    func testATurnThatEndsUnderAnApprovalDoesNotComeBack() async {
        let (display, _) = makeDisplay()
        let (turn, _, _) = makeTurn(display)
        turn.beginListening()
        turn.thinking(question: "send it to Sam")
        let (coordinator, _, _) = makeApproval(display)
        let asked = await ask(coordinator)
        turn.processingEnded()
        coordinator.resolve(false)
        _ = await asked.value
        XCTAssertFalse(display.showsTurnState)
        XCTAssertFalse(display.isInteractive)
    }

    // MARK: - P3: the Today glance

    private func fullGlance() -> HUDTodayGlance {
        HUDTodayGlance(time: "09:41", batteryPercent: 80,
                       event: HUDTodayGlance.Event(time: "10:30", title: "Standup", isNow: false, isAllDay: false),
                       weather: HUDTodayGlance.Weather(temperature: 18, condition: "Partly Cloudy", high: 21,
                                                       low: 12, credit: "Apple Weather"),
                       route: "Turn left on Queen St", digestTop: "[Calendar] Standup in 49 min")
    }

    func testTodayHasEveryRowAndItemWithWhatsNewFocused() {
        var pressed: [String] = []
        let actions = HUDTodayBuilder.Actions(whatsNew: { pressed.append("new") },
                                              resume: { pressed.append("resume") },
                                              navigate: { pressed.append("navigate") },
                                              menu: { pressed.append("menu") },
                                              close: { pressed.append("close") })
        let screen = HUDTodayBuilder.screen(fullGlance(), actions: actions)
        XCTAssertEqual(screen.title, HUDTodayBuilder.title)
        XCTAssertEqual(screen.lines.map(\.icon), [.clock, .calendar, .weather, .navigation, .info])
        XCTAssertEqual(screen.lines[0].emphasis, .meta)
        XCTAssertTrue(screen.lines[0].text.hasPrefix("09:41 · "))
        XCTAssertTrue(screen.lines[0].text.contains("80%"))
        XCTAssertEqual(screen.lines[1].text, "10:30 Standup")
        XCTAssertTrue(screen.lines[2].text.hasPrefix("18° Partly Cloudy · "))
        XCTAssertTrue(screen.lines[2].text.hasSuffix("Apple Weather"), "the weather carries its credit")
        XCTAssertEqual(screen.lines[3].text, "Turn left on Queen St")
        XCTAssertEqual(screen.items.map(\.id), [HUDTodayBuilder.ItemID.whatsNew, HUDTodayBuilder.ItemID.resume,
                                                HUDTodayBuilder.ItemID.navigate, HUDTodayBuilder.ItemID.menu,
                                                HUDTodayBuilder.ItemID.close])
        XCTAssertEqual(screen.items.filter { $0.style == .primary }.map(\.id), [HUDTodayBuilder.ItemID.whatsNew])
        XCTAssertEqual(screen.resolvedFocusItemID, HUDTodayBuilder.ItemID.whatsNew)
        XCTAssertTrue(HUDExit.hasExit(screen))
        screen.items.forEach { $0.action() }
        XCTAssertEqual(pressed, ["new", "resume", "navigate", "menu", "close"])
    }

    func testRowsAndItemsWithNothingToShowAreLeftOff() {
        let screen = HUDTodayBuilder.screen(HUDTodayGlance(time: "09:41"),
                                            actions: .init(close: {}))
        XCTAssertEqual(screen.lines.map(\.text), ["09:41"], "the time alone, no battery while disconnected")
        XCTAssertEqual(screen.items.map(\.id), [HUDTodayBuilder.ItemID.close])
        XCTAssertNil(HUDTodayBuilder.focus(.init(close: {})))

        let menuOnly = HUDTodayBuilder.Actions(menu: {}, close: {})
        XCTAssertEqual(HUDTodayBuilder.focus(menuOnly), HUDTodayBuilder.ItemID.menu)
        let resumeAndMenu = HUDTodayBuilder.Actions(resume: {}, menu: {}, close: {})
        XCTAssertEqual(HUDTodayBuilder.focus(resumeAndMenu), HUDTodayBuilder.ItemID.resume)
    }

    func testTheEventLineSaysNowAllDayOrTheTime() {
        XCTAssertTrue(HUDTodayBuilder.eventLine(.init(time: "10:30", title: "Standup", isNow: true, isAllDay: false))
            .hasSuffix("Standup"))
        XCTAssertNotEqual(HUDTodayBuilder.eventLine(.init(time: "10:30", title: "Standup", isNow: true, isAllDay: false)),
                          "10:30 Standup")
        XCTAssertTrue(HUDTodayBuilder.eventLine(.init(time: nil, title: "Holiday", isNow: false, isAllDay: true))
            .hasSuffix("Holiday"))
        let withheld = HUDTodayBuilder.eventLine(.init(time: "10:30", title: nil, isNow: false, isAllDay: false))
        XCTAssertTrue(withheld.hasPrefix("10:30 "), "a withheld title still shows the time")
    }

    // MARK: - P3: the glance from the Watch's Today value

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func payload(day: Date, events: [WatchTodayEvent], weather: WatchTodayWeather?,
                         weatherStatus: WatchTodaySectionStatus = .shown) -> WatchTodayPayload {
        WatchTodayPayload(day: WatchTodayDay(day, calendar: utc), generatedAt: day, calendarStatus: .shown,
                          events: events, moreEvents: 0, redacted: false,
                          weatherStatus: weatherStatus, weather: weather,
                          attribution: weather == nil ? nil
                              : WatchTodayAttribution(serviceName: "Apple Weather", legalPageURL: "https://example.com"))
    }

    func testTheGlancePicksTheNextEventAndTheWeather() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)   // 22:13 UTC
        let past = WatchTodayEvent(id: "a", start: now.addingTimeInterval(-7_200), end: now.addingTimeInterval(-3_600),
                                   isAllDay: false, title: "Over", location: nil)
        let next = WatchTodayEvent(id: "b", start: now.addingTimeInterval(600), end: now.addingTimeInterval(1_200),
                                   isAllDay: false, title: "Call", location: nil)
        let weather = WatchTodayWeather(symbolName: "cloud.fill", temperature: 18, high: 21, low: 12,
                                        precipitationChance: 10, condition: "Cloudy", unit: .celsius)
        let locale = Locale(identifier: "en_GB")
        let glance = HUDTodayGlance.make(now: now, calendar: utc, locale: locale, batteryPercent: 64,
                                         today: payload(day: now, events: [past, next], weather: weather),
                                         route: "  ", digestTop: nil)
        XCTAssertEqual(glance.time, HUDTodayGlance.timeText(now, calendar: utc, locale: locale))
        XCTAssertEqual(glance.batteryPercent, 64)
        XCTAssertEqual(glance.event, HUDTodayGlance.Event(
            time: HUDTodayGlance.timeText(next.start, calendar: utc, locale: locale),
            title: "Call", isNow: false, isAllDay: false))
        XCTAssertEqual(glance.weather, HUDTodayGlance.Weather(temperature: 18, condition: "Cloudy", high: 21,
                                                              low: 12, credit: "Apple Weather"))
        XCTAssertNil(glance.route, "an empty route line is no row")
        XCTAssertNil(glance.digestTop)
    }

    func testYesterdaysValueAndAWithheldSectionAddNothing() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let yesterday = now.addingTimeInterval(-86_400)
        let event = WatchTodayEvent(id: "b", start: now.addingTimeInterval(600), end: now.addingTimeInterval(1_200),
                                    isAllDay: false, title: "Call", location: nil)
        let stale = HUDTodayGlance.make(now: now, calendar: utc, locale: Locale(identifier: "en_GB"),
                                        batteryPercent: nil,
                                        today: payload(day: yesterday, events: [event], weather: nil),
                                        route: nil, digestTop: nil)
        XCTAssertNil(stale.event)
        XCTAssertNil(stale.weather)

        let medical = HUDTodayGlance.make(now: now, calendar: utc, locale: Locale(identifier: "en_GB"),
                                          batteryPercent: nil,
                                          today: payload(day: now, events: [event], weather: nil,
                                                         weatherStatus: .medicalOff),
                                          route: nil, digestTop: nil)
        XCTAssertNil(medical.weather, "Local Only withholds the weather")
        XCTAssertNotNil(medical.event)
        XCTAssertNil(HUDTodayGlance.make(now: now, calendar: utc, locale: Locale(identifier: "en_GB"),
                                         batteryPercent: nil, today: nil, route: nil, digestTop: nil).event)
    }

    func testTheDigestsTopLineIsDeterministicAndMarksNothingSeen() throws {
        let saved = Config.digestEnabled
        defer { Config.digestEnabled = saved }
        Config.digestEnabled = true
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kx-digest-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let digest = NotificationDigestService(storageURL: url)
        XCTAssertNil(digest.topLine())
        digest.ingest(id: "a", source: .agent, title: "Pump 3 is back online", priority: .high)
        let line = try XCTUnwrap(digest.topLine())
        XCTAssertTrue(line.contains("Pump 3 is back online"))
        XCTAssertEqual(digest.items.first?.seenCount, 0, "Today never marks the digest seen")
        Config.digestEnabled = false
        XCTAssertNil(digest.topLine())
    }

    // MARK: - P3: Today as the launcher's root

    private func makeLauncher(_ display: GlassesDisplayService) -> (HUDRouter, HUDLauncher) {
        let router = HUDRouter(display: display)
        let launcher = HUDLauncher(router: router)
        launcher.availablePlaybooks = { [Playbook(name: "Site Walkthrough", steps: [PlaybookStep(title: "Step 1")])] }
        launcher.availableProcedures = { [] }
        launcher.fieldAssistActive = { false }
        launcher.today = { HUDTodayGlance(time: "09:41") }
        return (router, launcher)
    }

    func testTheLauncherOpensAtTodayAndMenuOpensTheBranchList() async {
        let (display, _) = makeDisplay()
        let (router, launcher) = makeLauncher(display)
        launcher.open()
        XCTAssertEqual(router.currentScreen?.title, HUDTodayBuilder.title)
        XCTAssertEqual(router.menuDepth, 1)
        XCTAssertEqual(router.currentScreen?.resolvedFocusItemID, HUDTodayBuilder.ItemID.menu,
                       "no digest and no task: Menu takes focus")
        let todayIDs = router.currentScreen?.items.map(\.id) ?? []
        XCTAssertFalse(todayIDs.contains(HUDTodayBuilder.ItemID.whatsNew))

        await press(HUDTodayBuilder.ItemID.menu, on: router.currentScreen, display)
        XCTAssertEqual(router.menuDepth, 2)
        XCTAssertEqual(router.currentScreen?.title, "Menu")
        XCTAssertTrue((router.currentScreen?.items.map(\.id) ?? []).contains("branch:workflows"))

        XCTAssertTrue(launcher.handleVoiceSelection("back"))
        XCTAssertEqual(router.menuDepth, 1)
        XCTAssertEqual(router.currentScreen?.title, HUDTodayBuilder.title)
    }

    func testTodayOffersWhatsNewAndResumeWhenTheyHaveSomethingToDo() async {
        let (display, _) = makeDisplay()
        let (router, launcher) = makeLauncher(display)
        var opened = 0
        launcher.digestHasContent = { true }
        launcher.openDigest = { opened += 1 }
        router.startTask(TodayStubTaskSource())
        launcher.open()
        let ids = router.currentScreen?.items.map(\.id) ?? []
        XCTAssertEqual(Array(ids.prefix(2)), [HUDTodayBuilder.ItemID.whatsNew, HUDTodayBuilder.ItemID.resume])
        XCTAssertEqual(router.currentScreen?.resolvedFocusItemID, HUDTodayBuilder.ItemID.whatsNew)
        await press(HUDTodayBuilder.ItemID.resume, on: router.currentScreen, display)
        XCTAssertFalse(router.isPresentingMenu)
        XCTAssertEqual(router.currentScreen?.title, "Now")
        XCTAssertEqual(opened, 0)
    }

    func testWithoutATodaySourceTheLauncherOpensAtTheBranchList() {
        let (display, _) = makeDisplay()
        let (router, launcher) = makeLauncher(display)
        launcher.today = nil
        launcher.open()
        XCTAssertEqual(router.currentScreen?.title, "Menu")
    }

    func testTheTodayCommandIsWholePhraseOnly() {
        XCTAssertTrue(HUDLauncher.isTodayCommand("Show my day."))
        XCTAssertTrue(HUDLauncher.isTodayCommand("show today"))
        XCTAssertFalse(HUDLauncher.isTodayCommand("what's on my day tomorrow"))
        XCTAssertFalse(HUDLauncher.isTodayCommand("menu"))
    }
}

/// Minimal `HUDTaskSource` for the Today tests' Resume item.
@MainActor
private final class TodayStubTaskSource: HUDTaskSource {
    var title = "Stub"
    var current: HUDStep? = HUDStep(index: 0, total: 1, title: "Now")
    var next: HUDStep?
    private let subject = PassthroughSubject<Void, Never>()
    var changes: AnyPublisher<Void, Never> { subject.eraseToAnyPublisher() }
    func complete() async {}
    func skip() async {}
    func back() async {}
}
#endif
