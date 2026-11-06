import XCTest
import Combine
@testable import OpenGlasses

/// Tests for the interactive HUD foundation (Display Phase 3 / Plan X): the Playbook
/// task-source adapter, the Now/Next card layout, and screen render-key dedup. All
/// headless — no device or SDK needed.
@MainActor
final class HUDInteractionTests: XCTestCase {

    // MARK: - PlaybookHUDTaskSource

    private func makeStartedSource(id: String) -> (PlaybookStore, PlaybookHUDTaskSource) {
        let store = PlaybookStore()
        let pb = Playbook(id: id, name: "HUD Test", steps: [
            PlaybookStep(title: "Step A", detail: "Do A"),
            PlaybookStep(title: "Step B", detail: "Do B"),
            PlaybookStep(title: "Step C", detail: "Do C"),
        ])
        store.add(pb)
        _ = store.startPlaybook(pb.id)
        return (store, PlaybookHUDTaskSource(store: store))
    }

    func testSourceReportsCurrentAndNext() {
        let (store, source) = makeStartedSource(id: "hud-cn")
        defer { _ = store.finishPlaybook() }

        XCTAssertEqual(source.title, "HUD Test")
        XCTAssertEqual(source.current?.index, 0)
        XCTAssertEqual(source.current?.total, 3)
        XCTAssertEqual(source.current?.title, "Step A")
        XCTAssertEqual(source.current?.instruction, "Do A")
        XCTAssertNil(source.current?.safetyNote)            // Playbooks carry no safety notes
        XCTAssertEqual(source.next?.index, 1)
        XCTAssertEqual(source.next?.title, "Step B")
        XCTAssertNil(source.next?.instruction)              // next is a preview — title only
    }

    func testCompleteAdvancesAndBackReturns() async {
        let (store, source) = makeStartedSource(id: "hud-cb")
        defer { _ = store.finishPlaybook() }

        await source.complete()
        XCTAssertEqual(source.current?.index, 1)
        XCTAssertEqual(source.current?.title, "Step B")

        await source.back()
        XCTAssertEqual(source.current?.index, 0)
    }

    func testSkipAdvances() async {
        let (store, source) = makeStartedSource(id: "hud-skip")
        defer { _ = store.finishPlaybook() }

        await source.skip()
        XCTAssertEqual(source.current?.index, 1)
    }

    func testCompletingLastStepEndsWorkflow() async {
        let (store, source) = makeStartedSource(id: "hud-end")
        defer { _ = store.finishPlaybook() }

        await source.complete()   // → B
        await source.complete()   // → C
        await source.complete()   // → finished
        XCTAssertNil(source.current)
        XCTAssertNil(store.activeSession)
    }

    // MARK: - Card layout

    func testTaskCardLayout() {
        let source = FakeTaskSource()
        let current = HUDStep(index: 0, total: 3, title: "Torque bolts", instruction: "45 Nm, 2 passes")
        let next = HUDStep(index: 1, total: 3, title: "Reconnect sensor")
        let screen = HUDRouter.taskCard(source: source, current: current, next: next)

        XCTAssertEqual(screen.title, "Torque bolts")
        XCTAssertTrue(screen.lines.contains { $0.text == "Step 1 of 3" })
        XCTAssertTrue(screen.lines.contains { $0.text == "45 Nm, 2 passes" })
        XCTAssertTrue(screen.lines.contains { $0.text == "Next: Reconnect sensor" })
        XCTAssertEqual(screen.items.map(\.id), ["done", "skip", "back"])
    }

    func testTaskCardShowsSafetyNoteWithHazardIcon() {
        let source = FakeTaskSource()
        let current = HUDStep(index: 2, total: 7, title: "Contact terminals",
                              instruction: "Check continuity", safetyNote: "De-energize first")
        let screen = HUDRouter.taskCard(source: source, current: current, next: nil)

        let safety = screen.lines.first { $0.text == "De-energize first" }
        XCTAssertNotNil(safety)
        XCTAssertEqual(safety?.icon, .hazard)
        XCTAssertFalse(screen.lines.contains { $0.text.hasPrefix("Next:") })  // no next on last step
    }

    func testTaskCardButtonsInvokeSource() async {
        let source = FakeTaskSource()
        let screen = HUDRouter.taskCard(
            source: source,
            current: HUDStep(index: 0, total: 1, title: "Only step"),
            next: nil
        )
        screen.items.first { $0.id == "done" }?.action()
        screen.items.first { $0.id == "skip" }?.action()
        screen.items.first { $0.id == "back" }?.action()
        // Actions launch detached tasks; let them run.
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(source.completeCount, 1)
        XCTAssertEqual(source.skipCount, 1)
        XCTAssertEqual(source.backCount, 1)
    }

    // MARK: - Router lifecycle (with the real GlassesDisplayService via its test seam)

    private func makeDisplay() -> (GlassesDisplayService, () -> [GlassesDisplayService.HUDFrame]) {
        let svc = GlassesDisplayService()
        svc.testCapabilityOverride = true
        var frames: [GlassesDisplayService.HUDFrame] = []
        svc.testRenderSink = { frames.append($0) }
        return (svc, { frames })
    }

    func testRouterPresentsCardOnStart() async {
        let saved = Config.glassesDisplayEnabled
        Config.setGlassesDisplayEnabled(true)
        defer { Config.setGlassesDisplayEnabled(saved) }

        let (display, frames) = makeDisplay()
        let router = HUDRouter(display: display)
        let source = FakeTaskSource()
        source.current = HUDStep(index: 0, total: 2, title: "First")
        source.next = HUDStep(index: 1, total: 2, title: "Second")

        router.startTask(source)
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertTrue(router.isPresentingTask)
        XCTAssertEqual(frames().count, 1)
        guard case .screen? = frames().first else { return XCTFail("expected a screen frame") }
    }

    func testRouterFlashesCompleteAndStopsWhenSourceFinishes() async {
        let saved = Config.glassesDisplayEnabled
        Config.setGlassesDisplayEnabled(true)
        defer { Config.setGlassesDisplayEnabled(saved) }

        let (display, frames) = makeDisplay()
        let router = HUDRouter(display: display)
        let source = FakeTaskSource()
        source.current = HUDStep(index: 0, total: 1, title: "Only")
        router.startTask(source)
        try? await Task.sleep(nanoseconds: 50_000_000)

        source.current = nil          // workflow done
        source.emitChange()
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertFalse(router.isPresentingTask)
        XCTAssertTrue(frames().contains {
            if case .content(let body, _, _) = $0 { return body.contains("complete") }
            return false
        })
    }

    // MARK: - Branching procedures (choices)

    func testBranchStepRendersChoiceButtonsNotDoneSkip() {
        let source = FakeTaskSource()
        source.stubChoices = [HUDChoice(id: "low", label: "Pressure is low"),
                              HUDChoice(id: "ok", label: "Pressure is normal")]
        let screen = HUDRouter.taskCard(
            source: source,
            current: HUDStep(index: 0, total: nil, title: "Check pressure"),
            next: nil
        )
        XCTAssertEqual(screen.items.map(\.id), ["choice:low", "choice:ok", "back"])
        XCTAssertFalse(screen.items.contains { $0.id == "done" || $0.id == "skip" })
    }

    func testChoiceButtonInvokesChoose() async {
        let source = FakeTaskSource()
        source.stubChoices = [HUDChoice(id: "low", label: "Low")]
        let screen = HUDRouter.taskCard(source: source,
                                        current: HUDStep(index: 0, total: nil, title: "X"),
                                        next: nil)
        screen.items.first { $0.id == "choice:low" }?.action()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(source.chooseCount, 1)
        XCTAssertEqual(source.lastChoice, "low")
    }

    // MARK: - ProcedureHUDTaskSource (Field Assist adapter)

    func testProcedureSourceMapsStepAndBranches() {
        let host = FakeProcedureHost()
        host.activeProcedureTitle = "Diagnose No Cooling"
        host.activeProcedureStep = Procedure.Step(
            id: "s1", title: "Check suction pressure",
            instruction: "Read the gauge", safetyNote: "Wear gloves",
            branches: [Procedure.Branch(id: "low", condition: "Below 20 psi", next: "s2"),
                       Procedure.Branch(id: "ok", condition: "20 psi or above", next: "s3")]
        )
        let source = ProcedureHUDTaskSource(host: host)
        XCTAssertEqual(source.title, "Diagnose No Cooling")
        XCTAssertEqual(source.current?.title, "Check suction pressure")
        XCTAssertEqual(source.current?.instruction, "Read the gauge")
        XCTAssertEqual(source.current?.safetyNote, "Wear gloves")
        XCTAssertNil(source.next)
        XCTAssertEqual(source.choices.map(\.id), ["low", "ok"])
        XCTAssertEqual(source.choices.map(\.label), ["Below 20 psi", "20 psi or above"])
    }

    func testProcedureSourceDelegatesActions() async {
        let host = FakeProcedureHost()
        host.activeProcedureStep = Procedure.Step(id: "s1", title: "S", instruction: "i")
        let source = ProcedureHUDTaskSource(host: host)
        await source.choose("low")
        await source.complete()
        await source.back()
        XCTAssertEqual(host.advanceChoices, ["low", nil])   // choose(low), then complete(nil)
        XCTAssertEqual(host.backCount, 1)
    }

    func testProcedureSourceNilWhenNoStep() {
        let source = ProcedureHUDTaskSource(host: FakeProcedureHost())
        XCTAssertNil(source.current)
        XCTAssertEqual(source.title, "Procedure")
        XCTAssertTrue(source.choices.isEmpty)
    }

    // MARK: - Voice bridge

    func testVoiceParserMatchesStrictly() {
        XCTAssertEqual(HUDVoiceCommand.parse("done"), .complete)
        XCTAssertEqual(HUDVoiceCommand.parse("Done."), .complete)
        XCTAssertEqual(HUDVoiceCommand.parse("next"), .complete)
        XCTAssertEqual(HUDVoiceCommand.parse("okay next"), .complete)
        XCTAssertEqual(HUDVoiceCommand.parse("next step"), .complete)
        XCTAssertEqual(HUDVoiceCommand.parse("skip"), .skip)
        XCTAssertEqual(HUDVoiceCommand.parse("skip this step"), .skip)
        XCTAssertEqual(HUDVoiceCommand.parse("back"), .back)
        XCTAssertEqual(HUDVoiceCommand.parse("go back"), .back)
        XCTAssertEqual(HUDVoiceCommand.parse("previous"), .back)
    }

    func testVoiceParserRejectsNonCommands() {
        XCTAssertNil(HUDVoiceCommand.parse("what's the weather"))
        XCTAssertNil(HUDVoiceCommand.parse("next time we meet"))
        XCTAssertNil(HUDVoiceCommand.parse("back to the office"))
        XCTAssertNil(HUDVoiceCommand.parse("I'm done with the weather"))
        XCTAssertNil(HUDVoiceCommand.parse(""))
    }

    func testRouterHandlesVoiceOnlyWhenTaskActive() async {
        let saved = Config.glassesDisplayEnabled
        Config.setGlassesDisplayEnabled(true)
        defer { Config.setGlassesDisplayEnabled(saved) }

        let (display, _) = makeDisplay()
        let router = HUDRouter(display: display)
        let source = FakeTaskSource()
        source.current = HUDStep(index: 0, total: 2, title: "First")

        // No active task → not consumed, source untouched.
        var consumed = await router.handleVoiceCommand("done")
        XCTAssertFalse(consumed)
        XCTAssertEqual(source.completeCount, 0)

        router.startTask(source)
        try? await Task.sleep(nanoseconds: 40_000_000)

        consumed = await router.handleVoiceCommand("next")
        XCTAssertTrue(consumed); XCTAssertEqual(source.completeCount, 1)
        consumed = await router.handleVoiceCommand("skip")
        XCTAssertTrue(consumed); XCTAssertEqual(source.skipCount, 1)
        consumed = await router.handleVoiceCommand("go back")
        XCTAssertTrue(consumed); XCTAssertEqual(source.backCount, 1)

        // Non-command while active → not consumed (falls through to the LLM).
        consumed = await router.handleVoiceCommand("tell me a joke")
        XCTAssertFalse(consumed)
    }

    // MARK: - Answer card (Plan KP P1)

    private let longAnswer = """
    Turn the isolator off before you open the panel. Check the capacitor with a meter, \
    because it can hold a charge for minutes after the power is cut. If the reading is above \
    five volts, discharge it with an insulated resistor. Then swap the contactor, refit the \
    cover and restore the power.
    """

    /// The display on, a capable test display recording its frames, and a card on it.
    private func makeCard() -> (GlassesDisplayService, HUDAnswerCard, () -> [GlassesDisplayService.HUDFrame]) {
        let (display, frames) = makeDisplay()
        let card = HUDAnswerCard(display: display)
        card.geometry = { .raybanDisplay }
        return (display, card, frames)
    }

    private func withDisplayOn(_ body: () async throws -> Void) async rethrows {
        let saved = Config.glassesDisplayEnabled
        Config.setGlassesDisplayEnabled(true)
        defer { Config.setGlassesDisplayEnabled(saved) }
        try await body()
    }

    private func settle(_ ms: UInt64 = 60) async {
        try? await Task.sleep(nanoseconds: ms * 1_000_000)
    }

    /// Polls `condition` on the main actor until it holds or `timeout` passes — for the frames a
    /// timer draws, without betting on how long the timer takes on a loaded machine.
    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }

    private func lastScreenKey(_ frames: [GlassesDisplayService.HUDFrame]) -> String? {
        for frame in frames.reversed() {
            if case .screen(let key) = frame { return key }
        }
        return nil
    }

    func testOnlyAnswersBecomeCards() {
        let answers = SpeechSource.allCases.filter(HUDAnswerCard.takesAnswers(from:))
        XCTAssertEqual(Set(answers), [.reply, .phoneAnswer])
        for source in [SpeechSource.alert, .confirmation, .statusNotice, .progress, .agent,
                       .translation, .navigation, .narration, .job, .errorLine, .switchNotice,
                       .disclosure, .acknowledgement, .readAloud] {
            XCTAssertFalse(HUDAnswerCard.takesAnswers(from: source), "\(source)")
        }
    }

    func testAWholeAnswerBecomesOnePagedCard() async {
        await withDisplayOn {
            let (display, card, frames) = makeCard()
            XCTAssertTrue(card.absorb(longAnswer, streamed: false))
            await settle()
            XCTAssertTrue(display.showsAnswerCard)
            XCTAssertTrue(display.isInteractive)
            XCTAssertGreaterThan(card.pages.count, 2)
            XCTAssertEqual(card.visiblePageCount, card.pages.count)
            XCTAssertEqual(card.pageIndex, 0)
            guard case .screen? = frames().last else { return XCTFail("expected the card's screen") }
            // The card replaced today's 120-character cut: page 1 carries its footer.
            XCTAssertEqual(display.mirrorScreen?.lines.last?.text, "1/\(card.pages.count)")
            XCTAssertFalse(frames().contains {
                if case .content = $0 { return true }
                return false
            }, "no sentence-at-a-time line")
        }
    }

    func testAShortAnswerIsTodaysTextOnACard() async {
        await withDisplayOn {
            let (display, card, _) = makeCard()
            card.absorb("The filter is behind the front grille.", streamed: false)
            await settle()
            XCTAssertTrue(display.showsAnswerCard)
            XCTAssertEqual(display.mirrorScreen?.lines.map(\.text), ["The filter is behind the front grille."])
            XCTAssertEqual(display.mirrorScreen?.items.map(\.id), [HUDAnswerCardBuilder.ItemID.actions])
        }
    }

    func testNextAndBackMovePages() async {
        await withDisplayOn {
            let (display, card, frames) = makeCard()
            card.absorb(longAnswer, streamed: false)
            await settle()
            let first = lastScreenKey(frames())

            card.press(.next)
            await settle()
            XCTAssertEqual(card.pageIndex, 1)
            let second = lastScreenKey(frames())
            XCTAssertNotEqual(first, second)
            XCTAssertEqual(display.mirrorScreen?.lines.last?.text, "2/\(card.pages.count)")

            card.press(.back)
            await settle()
            XCTAssertEqual(card.pageIndex, 0)
            XCTAssertEqual(lastScreenKey(frames()), first)

            // Back on the first page and Next past the last do nothing.
            card.press(.back)
            XCTAssertEqual(card.pageIndex, 0)
            for _ in 0..<20 { card.press(.next) }
            XCTAssertEqual(card.pageIndex, card.pages.count - 1)
        }
    }

    func testABandPressTurnsThePage() async throws {
        await withDisplayOn {
            let (display, card, _) = makeCard()
            card.absorb(longAnswer, streamed: false)
            await settle()
            guard let screen = display.mirrorScreen else { return XCTFail("no card") }
            // The first button is Next ›; firing it is exactly what the band's press does.
            display.testInteractiveButtonActions(for: screen).first?()
            await settle()
            XCTAssertEqual(card.pageIndex, 1)
        }
    }

    func testANotificationBetweenIssueAndRenderMakesATurnStale() async {
        await withDisplayOn {
            let (display, card, frames) = makeCard()
            card.absorb(longAnswer, streamed: false)
            await settle()

            let issued = display.frameRevision          // "next" is said against this frame
            display.showNotification(title: "Calendar", body: "Meeting in five minutes", duration: 5)
            card.handle(.next, issuedAgainst: issued)   // ...and reaches the queue after it
            await settle()

            XCTAssertEqual(card.pageIndex, 0, "the stale turn is dropped")
            guard case .content(let body, let title, _)? = frames().last else {
                return XCTFail("the notification should be what is on the glasses")
            }
            XCTAssertEqual(body, "Meeting in five minutes")
            XCTAssertEqual(title, "Calendar")
            XCTAssertTrue(display.showsAnswerCard, "the card is still held under the notification")
            XCTAssertTrue(PageTurnGate.accept(turnRevision: display.frameRevision,
                                              currentRevision: display.frameRevision))
        }
    }

    func testEveryEnqueuedFrameBumpsTheRevision() async {
        await withDisplayOn {
            let (display, card, _) = makeCard()
            let start = display.frameRevision
            display.showText("one")
            XCTAssertEqual(display.frameRevision, start + 1)
            card.absorb(longAnswer, streamed: false)
            XCTAssertEqual(display.frameRevision, start + 2)
            card.press(.next)
            XCTAssertEqual(display.frameRevision, start + 3)
            display.flash("Saved", duration: 5)
            XCTAssertEqual(display.frameRevision, start + 4)
        }
    }

    func testANotificationOverACardComesBack() async {
        await withDisplayOn {
            let (display, card, frames) = makeCard()
            card.absorb(longAnswer, streamed: false)
            await settle()
            card.press(.next)
            await settle()
            let page = lastScreenKey(frames())

            display.showNotification(title: nil, body: "Battery low", duration: 0.3)
            let flashed = await waitUntil {
                if case .content(let body, _, _)? = frames().last { return body == "Battery low" }
                return false
            }
            XCTAssertTrue(flashed, "the notification flashes over the card")
            let restored = await waitUntil {
                if case .screen? = frames().last { return true }
                return false
            }
            XCTAssertTrue(restored, "the card comes back")
            XCTAssertEqual(lastScreenKey(frames()), page, "on the page the wearer was reading")
            XCTAssertEqual(card.pageIndex, 1)
        }
    }

    func testNavigationLinesNeverPage() async {
        await withDisplayOn {
            let (display, card, frames) = makeCard()
            display.showNavigation(longAnswer)
            await settle()
            guard case .content(let body, _, let icon)? = frames().last else {
                return XCTFail("guidance is a plain line")
            }
            XCTAssertEqual(body, HUDTextShaper.condense(longAnswer))
            XCTAssertEqual(icon, .navigation)
            XCTAssertFalse(display.showsAnswerCard)

            // Over a card, guidance takes the HUD rather than waiting behind it, still unpaged.
            card.absorb(longAnswer, streamed: false)
            await settle()
            XCTAssertTrue(display.showsAnswerCard)
            display.showNavigation("Hazard ahead: steps", icon: .hazard)
            await settle()
            XCTAssertFalse(display.showsAnswerCard)
            XCTAssertFalse(display.isInteractive)
            guard case .content(let line, _, .hazard)? = frames().last else {
                return XCTFail("the hazard line shows")
            }
            XCTAssertEqual(line, "Hazard ahead: steps")
        }
    }

    func testATaskCardStillGetsTheFiveSecondFlash() async {
        await withDisplayOn {
            let (display, card, frames) = makeCard()
            let router = HUDRouter(display: display)
            router.answerCard = card
            let source = FakeTaskSource()
            source.current = HUDStep(index: 0, total: 2, title: "First")
            router.startTask(source)
            await settle()

            // The card does not take an answer over a task card: the speech service then mirrors it
            // as today, which flashes over the card.
            XCTAssertFalse(card.absorb(longAnswer, streamed: false))
            XCTAssertFalse(card.absorb("A sentence.", streamed: true))
            display.showText(longAnswer, flashWhileInteractive: true)
            await settle()
            XCTAssertFalse(display.showsAnswerCard)
            XCTAssertTrue(router.isPresentingTask)
            XCTAssertTrue(display.isInteractive)
            guard case .content(let body, _, _)? = frames().last else { return XCTFail("the answer flashes") }
            XCTAssertEqual(body, HUDTextShaper.condense(longAnswer), "unpaged, as today")

            // And "next" there still means the step is done.
            let consumed = await router.handleVoiceCommand("next")
            XCTAssertTrue(consumed)
            XCTAssertEqual(source.completeCount, 1)
        }
    }

    func testAnAnswerOverAChoiceListStillFlashes() async {
        await withDisplayOn {
            let (display, card, _) = makeCard()
            display.present(screen: HUDScreen(title: "Choose", items: [HUDItem(id: "choice-0", label: "A") {}])) { _ in }
            XCTAssertFalse(card.absorb(longAnswer, streamed: false))
            XCTAssertFalse(display.showsAnswerCard)
        }
    }

    func testSendNeverSendsWithoutConfirmation() async {
        await withDisplayOn {
            let (_, card, _) = makeCard()
            var turns: [String] = []
            var saved = 0
            var spoken = 0
            card.submitTurn = { turns.append($0) }
            card.saveNote = { _, _ in saved += 1; return true }
            card.speakAgain = { _ in spoken += 1 }
            card.absorb(longAnswer, streamed: false)
            await settle()

            card.press(.actions)
            card.press(.send)
            await settle()
            // The press only asks the assistant, as the wearer's next turn, to send the answer; it
            // runs no tool. The assistant asks who to, and `send_via` is a messaging tool, so its
            // bound approval holds the send until the wearer confirms.
            XCTAssertEqual(turns, [HUDAnswerCard.sendRequest])
            XCTAssertEqual(saved, 0)
            XCTAssertEqual(spoken, 0)
            let sendClass = ToolEffectClassifier.nativeClass(
                name: "send_via", args: [:], semantics: .external(.bestEffort))
            XCTAssertEqual(sendClass, .messaging)
            XCTAssertTrue(sendClass.requiresBoundApproval(on: .native))
        }
    }

    func testMoreRepeatAndSave() async {
        await withDisplayOn {
            let (display, card, frames) = makeCard()
            var turns: [String] = []
            var repeated: [String] = []
            var notes: [(String, String)] = []
            card.submitTurn = { turns.append($0) }
            card.speakAgain = { repeated.append($0) }
            card.saveNote = { title, content in notes.append((title, content)); return true }
            card.absorb(longAnswer, streamed: false)
            await settle()

            card.press(.actions)
            await settle()
            XCTAssertTrue(card.isOnActions)
            XCTAssertEqual(display.mirrorScreen?.items.map(\.id).contains(HUDAnswerCardBuilder.ItemID.more), true)

            card.press(.more)
            XCTAssertEqual(turns, [HUDAnswerCard.moreRequest])

            card.press(.repeatAnswer)
            XCTAssertEqual(repeated, [card.answer])

            card.press(.save)
            await settle(120)
            XCTAssertEqual(notes.count, 1)
            XCTAssertEqual(notes.first?.1, card.answer)
            XCTAssertEqual(notes.first?.0, HUDAnswerCard.noteTitle(for: card.answer))
            XCTAssertTrue(frames().contains {
                if case .content(let body, _, _) = $0 { return body == String(localized: "Saved") }
                return false
            })

            // While "Saved" is over the card a press is stale, like one over a notification...
            card.press(.answer)
            XCTAssertTrue(card.isOnActions)
            // ...and once the flash gives the card back, ‹ Answer goes back to the page the wearer
            // was on.
            let restored = await waitUntil {
                if case .screen? = frames().last { return true }
                return false
            }
            XCTAssertTrue(restored, "the card comes back after \"Saved\"")
            card.press(.answer)
            XCTAssertFalse(card.isOnActions)
            XCTAssertEqual(card.pageIndex, 0)
        }
    }

    func testCloseClearsTheCardAndCaptionsResume() async {
        await withDisplayOn {
            let (display, card, frames) = makeCard()
            card.absorb(longAnswer, streamed: false)
            await settle()
            let count = frames().count

            // A caption line (showText without flashing) is suppressed while the card is up and
            // never becomes a card, and a producer clearing its own line leaves the card alone.
            display.showText("Caption while the card is up")
            display.clear()
            await settle()
            XCTAssertEqual(frames().count, count)
            XCTAssertTrue(display.showsAnswerCard)

            card.press(.close)
            await settle()
            XCTAssertFalse(display.showsAnswerCard)
            XCTAssertFalse(display.isInteractive)
            XCTAssertEqual(frames().last, .clear)

            display.showText("Caption after")
            await settle()
            XCTAssertEqual(frames().last, .content(body: "Caption after", title: nil, icon: .none))
            XCTAssertFalse(display.showsAnswerCard, "a caption is a line, not a card")
        }
    }

    func testTheCardClearsAfterItsLifetimeWithoutAPress() async {
        await withDisplayOn {
            let (display, card, frames) = makeCard()
            XCTAssertEqual(HUDAnswerCard.defaultIdleLifetime, 60)
            // The timers are captured and fired by hand, so the rule is checked without racing
            // the clock.
            var timers: [(delay: TimeInterval, fire: @MainActor () -> Void)] = []
            card.scheduleIdleTimer = { timers.append(($0, $1)) }
            card.absorb(longAnswer, streamed: false)
            await settle()
            XCTAssertEqual(timers.count, 1)
            XCTAssertEqual(timers.first?.delay, 60)

            card.press(.next)              // a press restarts the clock
            await settle()
            XCTAssertEqual(timers.count, 2)
            timers[0].fire()               // the first lifetime ends: superseded, nothing happens
            await settle()
            XCTAssertTrue(display.showsAnswerCard)

            timers[1].fire()               // a minute with no press
            await settle()
            XCTAssertFalse(display.showsAnswerCard)
            XCTAssertEqual(frames().last, .clear)
        }
    }

    func testAnOldCardsLifetimeNeverClearsANewerCard() async {
        await withDisplayOn {
            let (display, card, _) = makeCard()
            var timers: [@MainActor () -> Void] = []
            card.scheduleIdleTimer = { timers.append($1) }
            card.absorb(longAnswer, streamed: false)
            card.absorb("It takes about ten minutes.", streamed: false)
            await settle()
            XCTAssertEqual(timers.count, 2)
            timers[0]()
            await settle()
            XCTAssertTrue(display.showsAnswerCard, "the first answer's timer leaves the second card")
            XCTAssertEqual(card.answer, "It takes about ten minutes.")

            // Nor does it clear a task card that took the HUD from the card.
            display.present(screen: HUDScreen(title: "Task", items: [HUDItem(id: "t", label: "Done") {}])) { _ in }
            timers[1]()
            await settle()
            XCTAssertTrue(display.isInteractive, "the task card stays")
        }
    }

    func testTheLifetimeCountsFromTheEndOfTheTurn() async {
        await withDisplayOn {
            let (_, card, _) = makeCard()
            var timers = 0
            card.scheduleIdleTimer = { _, _ in timers += 1 }
            card.beginTurn()
            card.absorb("Turn the isolator off before you open the panel.", streamed: true)
            card.absorb("Check the capacitor with a meter, because it can hold a charge.", streamed: true)
            card.absorb("If the reading is above five volts, discharge it with a resistor.", streamed: true)
            card.absorb("Then swap the contactor and refit the cover.", streamed: true)
            let whileSpeaking = timers
            XCTAssertGreaterThan(whileSpeaking, 0, "the card is up and its clock running")
            card.endTurn()
            XCTAssertGreaterThan(timers, whileSpeaking, "the clock restarts once the answer has been said")
        }
    }

    func testABandPressOverANotificationIsStale() async {
        await withDisplayOn {
            let (display, card, frames) = makeCard()
            card.absorb(longAnswer, streamed: false)
            await settle()
            guard let screen = display.mirrorScreen else { return XCTFail("no card") }
            let next = display.testInteractiveButtonActions(for: screen).first

            // A notification is drawn over the card; a band press on the card's old buttons
            // arrives while it is up.
            display.showNotification(title: nil, body: "Battery low", duration: 5)
            next?()
            card.press(.next)              // a spoken "next" too
            await settle()
            XCTAssertEqual(card.pageIndex, 0, "both are dropped")
            guard case .content(let body, _, _)? = frames().last else {
                return XCTFail("the notification stays on the glasses")
            }
            XCTAssertEqual(body, "Battery low")
        }
    }

    func testANewAnswerReplacesTheCard() async {
        await withDisplayOn {
            let (display, card, _) = makeCard()
            card.absorb(longAnswer, streamed: false)
            await settle()
            card.press(.next)
            card.absorb("It takes about ten minutes.", streamed: false)
            await settle()
            XCTAssertTrue(display.showsAnswerCard)
            XCTAssertEqual(card.pageIndex, 0)
            XCTAssertEqual(display.mirrorScreen?.lines.first?.text, "It takes about ten minutes.")
        }
    }

    func testAStreamedTurnShowsPageOneOnceSettledAndNeverChangesIt() async {
        await withDisplayOn {
            let (display, card, frames) = makeCard()
            let sentences = [
                "Turn the isolator off before you open the panel.",
                "Check the capacitor with a meter.",
                "It can hold a charge for minutes after the power is cut.",
                "If the reading is above five volts, discharge it.",
                "Then swap the contactor and refit the cover.",
            ]
            card.beginTurn()
            XCTAssertTrue(card.absorb(sentences[0], streamed: true))
            await settle()
            XCTAssertFalse(display.showsAnswerCard, "one unsettled page waits")
            XCTAssertTrue(frames().isEmpty, "and nothing a sentence at a time")

            var firstPage: [String]?
            for sentence in sentences.dropFirst() {
                card.absorb(sentence, streamed: true)
                await settle(20)
                if display.showsAnswerCard, firstPage == nil { firstPage = card.pages.first?.lines }
                if let firstPage { XCTAssertEqual(card.pages.first?.lines, firstPage) }
            }
            XCTAssertNotNil(firstPage, "page 1 shows once it is settled")
            XCTAssertLessThan(card.visiblePageCount, card.pages.count, "the unsettled last page waits")

            // The reply is final: every page can be read, and the remainder said later is not
            // added twice.
            card.finishTurn(reply: sentences.joined(separator: " "))
            XCTAssertEqual(card.visiblePageCount, card.pages.count)
            let answer = card.answer
            XCTAssertTrue(card.absorb(sentences[4], streamed: true))
            card.endTurn()
            XCTAssertEqual(card.answer, answer)
            XCTAssertEqual(card.pages.first?.lines, firstPage)
        }
    }

    func testAStreamedLineOutsideATurnKeepsTodaysPath() async {
        await withDisplayOn {
            let (display, card, _) = makeCard()
            XCTAssertFalse(card.absorb("A gateway sentence.", streamed: true))
            XCTAssertFalse(display.showsAnswerCard)
        }
    }

    func testATurnEndingEarlyShowsWhatWasSaid() async {
        await withDisplayOn {
            let (display, card, _) = makeCard()
            card.beginTurn()
            card.absorb("The first thing to check is the fuse.", streamed: true)
            card.endTurn()                     // a barge-in: no final reply
            await settle()
            XCTAssertTrue(display.showsAnswerCard)
            XCTAssertEqual(card.answer, "The first thing to check is the fuse.")
            XCTAssertFalse(card.isTurnOpen)
        }
    }

    func testVoicePagingOnlyWhileACardIsUp() async {
        await withDisplayOn {
            let (display, card, _) = makeCard()
            let router = HUDRouter(display: display)
            router.answerCard = card

            var consumed = await router.handleVoiceCommand("next")
            XCTAssertFalse(consumed, "no card: the words go to the model as before")

            card.absorb(longAnswer, streamed: false)
            await settle()
            consumed = await router.handleVoiceCommand("next page")
            XCTAssertTrue(consumed)
            XCTAssertEqual(card.pageIndex, 1)
            consumed = await router.handleVoiceCommand("previous")
            XCTAssertTrue(consumed)
            XCTAssertEqual(card.pageIndex, 0)
            consumed = await router.handleVoiceCommand("what's next on my list")
            XCTAssertFalse(consumed, "only whole short utterances")
            consumed = await router.handleVoiceCommand("back")
            XCTAssertFalse(consumed, "nothing to go back to: left to the model")

            // "next" on the last page has nothing to turn to, so it is not swallowed (it may mean
            // the next track).
            for _ in 0..<card.pages.count { card.press(.next) }
            XCTAssertEqual(card.pageIndex, card.pages.count - 1)
            consumed = await router.handleVoiceCommand("next")
            XCTAssertFalse(consumed)

            consumed = await router.handleVoiceCommand("clear")
            XCTAssertTrue(consumed)
            await settle()
            XCTAssertFalse(display.showsAnswerCard)
        }
    }

    func testAnswerVoiceParse() {
        XCTAssertEqual(HUDAnswerVoiceCommand.parse("next"), .next)
        XCTAssertEqual(HUDAnswerVoiceCommand.parse("Next page."), .next)
        XCTAssertEqual(HUDAnswerVoiceCommand.parse("okay back"), .back)
        XCTAssertEqual(HUDAnswerVoiceCommand.parse("previous"), .back)
        XCTAssertEqual(HUDAnswerVoiceCommand.parse("close"), .close)
        XCTAssertEqual(HUDAnswerVoiceCommand.parse("clear"), .close)
        XCTAssertNil(HUDAnswerVoiceCommand.parse("next time we meet"))
        XCTAssertNil(HUDAnswerVoiceCommand.parse("close the garage door"))
        XCTAssertNil(HUDAnswerVoiceCommand.parse("repeat"))
        XCTAssertNil(HUDAnswerVoiceCommand.parse("save that"))
        XCTAssertNil(HUDAnswerVoiceCommand.parse(""))
    }

    func testNoteTitleIsTheFirstLine() {
        XCTAssertEqual(HUDAnswerCard.noteTitle(for: "Check the fuse.\nThen the breaker."), "Check the fuse.")
        XCTAssertLessThanOrEqual(HUDAnswerCard.noteTitle(for: longAnswer).count,
                                 HUDTextShaper.maxTitleLength + 1)
    }

    // MARK: - Render-key dedup

    func testRenderKeyStableForIdenticalContent() {
        let a = HUDScreen(title: "T", lines: [HUDLine("x", emphasis: .meta)],
                          items: [HUDItem(id: "i", label: "Go") {}])
        let b = HUDScreen(title: "T", lines: [HUDLine("x", emphasis: .meta)],
                          items: [HUDItem(id: "i", label: "Go") {}])
        XCTAssertEqual(a.renderKey, b.renderKey)
    }

    func testRenderKeyDiffersWhenLabelChanges() {
        let a = HUDScreen(title: "T", items: [HUDItem(id: "i", label: "Go") {}])
        let b = HUDScreen(title: "T", items: [HUDItem(id: "i", label: "Stop") {}])
        XCTAssertNotEqual(a.renderKey, b.renderKey)
    }
}

/// In-memory `HUDTaskSource` double for layout/wiring tests.
@MainActor
private final class FakeTaskSource: HUDTaskSource {
    var title = "Fake"
    var current: HUDStep?
    var next: HUDStep?
    private let subject = PassthroughSubject<Void, Never>()
    var changes: AnyPublisher<Void, Never> { subject.eraseToAnyPublisher() }

    var completeCount = 0
    var skipCount = 0
    var backCount = 0
    var chooseCount = 0
    var lastChoice: String?
    var stubChoices: [HUDChoice] = []
    var choices: [HUDChoice] { stubChoices }

    func complete() async { completeCount += 1 }
    func skip() async { skipCount += 1 }
    func back() async { backCount += 1 }
    func choose(_ id: String) async { chooseCount += 1; lastChoice = id }

    func emitChange() { subject.send(()) }
}

/// In-memory `ProcedureHosting` double for `ProcedureHUDTaskSource` tests.
@MainActor
private final class FakeProcedureHost: ObservableObject, ProcedureHosting {
    var activeProcedureStep: Procedure.Step?
    var activeProcedureTitle: String?
    var advanceChoices: [String?] = []
    var backCount = 0

    func advanceProcedure(choice: String?) throws -> ProcedureRunner.Transition {
        advanceChoices.append(choice)
        return .moved(activeProcedureStep ?? Procedure.Step(id: "x", title: "x", instruction: ""))
    }
    func procedureBack() throws -> Procedure.Step {
        backCount += 1
        return activeProcedureStep ?? Procedure.Step(id: "x", title: "x", instruction: "")
    }
}
