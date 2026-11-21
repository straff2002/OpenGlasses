import XCTest
@testable import OpenGlasses

/// Plan JI §7a (P6b): the talk-through session on a running procedure: start and stop, never with
/// live hints, proposals that move the runner only on a yes, taps, the procedure's own voice first,
/// the mic by setup, "just go", a question mid-job, and no allowance drawn on.
@MainActor
final class TalkThroughSessionTests: XCTestCase {

    // MARK: - Start and stop

    func testItBelongsToARunningProcedure() throws {
        let rig = try TalkThroughRig()
        XCTAssertEqual(rig.service.start(), .started)
        XCTAssertEqual(rig.service.start(), .alreadyRunning)
        XCTAssertEqual(rig.service.procedureId, "qmx_service")
        XCTAssertEqual(rig.captions.starts, 1, "captions on, because nothing had them on")
        XCTAssertTrue(rig.voice.running)
        XCTAssertTrue(rig.clock.isTicking)
        rig.service.stop()
        XCTAssertFalse(rig.service.isRunning)
        XCTAssertEqual(rig.captions.stops, 1)
        XCTAssertFalse(rig.voice.running)
        XCTAssertFalse(rig.clock.isTicking)
    }

    func testCaptionsSomeoneElseStartedStayOn() throws {
        let rig = try TalkThroughRig()
        rig.captions.isActive = true
        rig.service.start()
        rig.service.stop()
        XCTAssertEqual(rig.captions.stops, 0)
    }

    func testItStopsWhenItsRunEnds() throws {
        let short = Procedure(id: "qmx_short", title: "Top up", version: "1", steps: [
            Procedure.Step(id: "fill", title: "Fill the chamber", instruction: "Fill it.", defaultNext: "cap"),
            Procedure.Step(id: "cap", title: "Close the cap", instruction: "Close it.", terminal: true, outcome: "done"),
        ])
        let rig = try TalkThroughRig(procedure: short)
        rig.service.start()
        _ = try rig.host.advanceProcedure(choice: nil)
        rig.clock.advance(by: 0.1)
        XCTAssertTrue(rig.service.isRunning)
        _ = try rig.host.advanceProcedure(choice: nil)                      // finished
        rig.clock.advance(by: 0.1)
        XCTAssertFalse(rig.service.isRunning)
    }

    func testTheRecogniserHearsTheProceduresWords() throws {
        let rig = try TalkThroughRig()
        rig.service.start()
        let words = rig.captions.contextualStrings
        XCTAssertEqual(Array(words.prefix(6)), ["Isolate the pump", "Drain the chamber", "Clean the filter basket",
                                                "Prime the pump", "Reseal the cap", "Run the pump"])
        XCTAssertTrue(words.contains("flow rate"), "the calculation's name, as said")
        rig.service.stop()
    }

    func testProcedureWordsComeRightAfterASessionsKeywords() throws {
        let input = DictationVocabulary.Input(wakePhrases: ["hey there"], keywords: ["warranty"],
                                              procedureWords: ["Prime the pump"])
        XCTAssertEqual(DictationVocabulary.build(input), ["warranty", "Prime the pump", "hey there"])
        XCTAssertEqual(DictationVocabulary.build(DictationVocabulary.Input(wakePhrases: ["hey there"])), ["hey there"],
                       "without talk-through the words are unchanged")
    }

    // MARK: - Never with live hints

    func testStartingEitherStopsTheOtherWithOneLine() {
        let toTalk = HintSessionArbiter.start(.talkThrough, running: .liveHints)
        XCTAssertEqual(toTalk.stop, .liveHints)
        XCTAssertEqual(toTalk.line, "Live hints stopped; talking you through the job.")
        let toHints = HintSessionArbiter.start(.liveHints, running: .talkThrough)
        XCTAssertEqual(toHints.stop, .talkThrough)
        XCTAssertNotNil(toHints.line)
        XCTAssertEqual(HintSessionArbiter.start(.talkThrough, running: nil), .init(stop: nil, line: nil))
        XCTAssertEqual(HintSessionArbiter.start(.liveHints, running: .liveHints), .init(stop: nil, line: nil))
        XCTAssertEqual(HintSessionArbiter.owner(liveHintsRunning: true, talkThroughRunning: false), .liveHints)
        XCTAssertEqual(HintSessionArbiter.owner(liveHintsRunning: false, talkThroughRunning: true), .talkThrough)
        XCTAssertNil(HintSessionArbiter.owner(liveHintsRunning: false, talkThroughRunning: false))
    }

    /// The app's order, on the same captions: the running session stops first, so its teardown can
    /// never undo the next one's setup.
    func testHandingOverOnSharedCaptionsLeavesOnlyTheNewSession() throws {
        let rig = try TalkThroughRig()
        let allowance = FakeHintAllowance()
        let hints = LiveHintsService(carriers: .init(
            captions: rig.captions, documents: FakeHintDocuments(), model: FakeHintModel(), lens: FakeHintLens(),
            ear: FakeHintEar(), voiceActivity: FakeHintVoiceActivity(), phoneList: LiveHintsPhoneList(),
            clock: rig.clock, allowance: allowance))
        hints.isEnabled = { true }
        hints.firstRunAcknowledged = { true }
        rig.captions.contextualStrings = ["room"]
        XCTAssertEqual(hints.start(), .started)

        // Talk-through starts: live hints stops first.
        func running() -> HintSessionOwner? {
            HintSessionArbiter.owner(liveHintsRunning: hints.isRunning, talkThroughRunning: rig.service.isRunning)
        }
        if HintSessionArbiter.start(.talkThrough, running: running()).stop == .liveHints { hints.stop() }
        rig.service.start()
        XCTAssertFalse(hints.isRunning)
        XCTAssertTrue(rig.service.isRunning)
        XCTAssertTrue(rig.captions.contextualStrings.contains("Drain the chamber"))
        let charged = allowance.charged
        for _ in 0..<50 { rig.clock.advance(by: 60) }
        XCTAssertEqual(allowance.charged, charged, "talk-through never draws on the daily allowance")

        // And back: live hints starts, talk-through stops first.
        if HintSessionArbiter.start(.liveHints, running: running()).stop == .talkThrough { rig.service.stop(reason: .liveHints) }
        XCTAssertEqual(hints.start(), .started)
        XCTAssertFalse(rig.service.isRunning)
        XCTAssertEqual(rig.captions.contextualStrings, [], "live hints' own words, none set")
        hints.stop()
        XCTAssertEqual(rig.captions.contextualStrings, ["room"])
    }

    func testTheAllowanceIsNotAmongItsCarriers() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OpenGlasses/Sources/Services/TalkThrough")
        for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            let code = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(code.contains("HintSessionAllowance"), url.lastPathComponent)
            XCTAssertFalse(code.contains(".charge("), url.lastPathComponent)
        }
    }

    // MARK: - Proposals move the runner only on a yes

    private func proposeDrain(_ rig: TalkThroughRig) {
        rig.say("Opening the drain plug now.")
        rig.say("Letting the chamber empty into the bucket.")
    }

    func testAProposalWaitsAndNeverMovesTheRunnerByItself() throws {
        let rig = try TalkThroughRig()
        rig.service.start()
        proposeDrain(rig)
        XCTAssertEqual(rig.service.proposal?.stepId, "drain")
        XCTAssertEqual(rig.ear.spoken.last, HintReply.cutSpoken("Unplug the lead before opening the housing."),
                       "the ear is still saying the step's hint; the proposal waits its turn")
        for _ in 0..<100 { rig.clock.advance(by: 0.1) }
        XCTAssertEqual(rig.visited, ["isolate"])
        rig.service.stop()
    }

    func testAYesMovesItAsASpokenNextWould() throws {
        let rig = try TalkThroughRig()
        rig.service.start()
        proposeDrain(rig)
        rig.say("Yes, that's right.")
        XCTAssertEqual(rig.visited, ["isolate", "drain"])
        XCTAssertNil(rig.service.proposal)
        XCTAssertEqual(rig.service.currentHint?.items, [.expect("chamber empty")])
        rig.service.stop()
    }

    func testANoHoldsAndIsNotAskedAgainOnThisStep() throws {
        let rig = try TalkThroughRig()
        rig.service.start()
        proposeDrain(rig)
        rig.say("Not yet.")
        XCTAssertNil(rig.service.proposal)
        proposeDrain(rig)
        XCTAssertNil(rig.service.proposal)
        XCTAssertEqual(rig.visited, ["isolate"])
        rig.service.stop()
    }

    func testAProposalAlongABranchTakesTheBranch() throws {
        let rig = try TalkThroughRig()
        for _ in 0..<3 { _ = try rig.host.advanceProcedure(choice: nil) }    // at prime
        rig.service.start()
        rig.say("Fitting a new cap seal.")
        rig.say("Reseal done, cap closed again.")
        XCTAssertEqual(rig.service.proposal?.stepId, "reseal")
        rig.service.confirmProposal()
        XCTAssertEqual(rig.visited.last, "reseal")
        rig.service.stop()
    }

    func testTheChoiceASpokenNextWouldPass() throws {
        let procedure = try TalkThroughFixtures.procedure()
        let prime = try XCTUnwrap(procedure.step(id: "prime"))
        XCTAssertNil(TalkThroughService.choice(from: prime, to: "run"), "its own way on")
        XCTAssertEqual(TalkThroughService.choice(from: prime, to: "reseal"), "leaking")
        XCTAssertNil(TalkThroughService.choice(from: try XCTUnwrap(procedure.step(id: "isolate")), to: "drain"))
    }

    func testARefusalIsSaidAndTheRunnerStays() throws {
        // The yes/no step needs its answer before it goes on: the runner says so.
        let rig = try TalkThroughRig(procedure: TalkThroughFixtures.yesNoProcedure())
        rig.service.start()
        rig.say("Rinsing the filter basket under the tap.")
        rig.say("Filter basket rinsed under the tap.")
        XCTAssertEqual(rig.service.proposal?.stepId, "rinse")
        rig.ear.onFinishedSpeaking?()
        let line = rig.service.confirmProposal()
        XCTAssertNotNil(line)
        XCTAssertEqual(rig.visited, ["outlet"])
        rig.service.stop()
    }

    // MARK: - Just go

    func testJustGoTurnsProposalsIntoSpokenAdvances() throws {
        let rig = try TalkThroughRig()
        rig.service.start()
        rig.say("Just go.")
        XCTAssertTrue(rig.service.justGo)
        proposeDrain(rig)
        XCTAssertEqual(rig.visited, ["isolate", "drain"], "taken without asking")
        XCTAssertNil(rig.service.proposal)
        rig.say("Lifting out the filter basket.")
        rig.say("Rinsing the filter mesh under the tap.")
        XCTAssertEqual(rig.visited, ["isolate", "drain", "filter"])
        rig.service.stop()
        XCTAssertFalse(rig.service.justGo, "for this run only")
    }

    func testJustGoNeverTakesAStepPastAnOpenOne() throws {
        let rig = try TalkThroughRig()
        rig.service.start()
        rig.service.turnOnJustGo()
        rig.say("Lifting out the filter basket.")
        rig.say("Rinsing the filter mesh under the tap.")
        XCTAssertEqual(rig.visited, ["isolate"], "off order is offered, never taken")
        XCTAssertEqual(rig.service.offOrderLine,
                       "Sounds like Clean the filter basket. Drain the chamber isn't done: skipped it, or did it differently?")
        rig.service.stop()
    }

    // MARK: - Taps

    func testOneTapConfirmsAWaitingProposalAndOtherwiseRepeats() {
        XCTAssertEqual(TalkThroughTapPolicy.resolve(.one, sessionRunning: true, proposalWaiting: true, hintPlaying: true),
                       .confirmProposal)
        XCTAssertEqual(TalkThroughTapPolicy.resolve(.one, sessionRunning: true, proposalWaiting: false, hintPlaying: true),
                       .repeatHint)
        XCTAssertEqual(TalkThroughTapPolicy.resolve(.one, sessionRunning: true, proposalWaiting: false, hintPlaying: false),
                       .repeatHint)
        XCTAssertEqual(TalkThroughTapPolicy.resolve(.two, sessionRunning: true, proposalWaiting: false, hintPlaying: true), .skip)
        XCTAssertEqual(TalkThroughTapPolicy.resolve(.two, sessionRunning: true, proposalWaiting: true, hintPlaying: false), .skip)
        XCTAssertEqual(TalkThroughTapPolicy.resolve(.two, sessionRunning: true, proposalWaiting: false, hintPlaying: false), .ignored)
        XCTAssertEqual(TalkThroughTapPolicy.resolve(.three, sessionRunning: true, proposalWaiting: true, hintPlaying: true), .ignored)
        XCTAssertEqual(TalkThroughTapPolicy.resolve(.one, sessionRunning: false, proposalWaiting: true, hintPlaying: true), .notOurs)
        XCTAssertEqual(TalkThroughTapPolicy.earcon(for: .ignored), .refused)
        XCTAssertEqual(TalkThroughTapPolicy.earcon(for: .confirmProposal), .accepted)
    }

    /// The app's tap handler, as `AppState.handleTalkThroughTap` carries an outcome out.
    private func tap(_ gesture: TempleGesture, _ rig: TalkThroughRig) {
        switch TalkThroughTapPolicy.resolve(gesture, sessionRunning: rig.service.isRunning,
                                            proposalWaiting: rig.service.proposal != nil,
                                            hintPlaying: rig.service.isHintPlaying) {
        case .confirmProposal: rig.service.confirmProposal()
        case .repeatHint: rig.service.repeatHint()
        case .skip: rig.service.skip()
        case .ignored, .notOurs: break
        }
    }

    func testATapWithNoProposalNeverAdvancesTheRunner() throws {
        let rig = try TalkThroughRig()
        rig.service.start()
        for gesture in [TempleGesture.one, .two, .three, .one, .one] { tap(gesture, rig) }
        XCTAssertEqual(rig.visited, ["isolate"])
        proposeDrain(rig)
        tap(.one, rig)
        XCTAssertEqual(rig.visited, ["isolate", "drain"], "one tap is yes to the waiting proposal")
        tap(.one, rig)
        XCTAssertEqual(rig.visited, ["isolate", "drain"], "and with none waiting it only repeats")
        rig.service.stop()
    }

    func testTwoTapsLetAProposalGo() throws {
        let rig = try TalkThroughRig()
        rig.service.start()
        proposeDrain(rig)
        tap(.two, rig)
        XCTAssertNil(rig.service.proposal)
        XCTAssertEqual(rig.visited, ["isolate"])
        rig.service.stop()
    }

    func testRepeatSaysTheHintAgain() throws {
        let rig = try TalkThroughRig()
        rig.service.start()
        rig.ear.onFinishedSpeaking?()
        let count = rig.ear.spoken.count
        rig.service.repeatHint()
        XCTAssertEqual(rig.ear.spoken.count, count + 1)
        XCTAssertEqual(rig.ear.spoken.last, rig.ear.spoken[count - 1])
        rig.service.stop()
    }

    // MARK: - The procedure keeps its voice

    func testAYesTheProcedureNeedsIsLeftToTheProcedure() throws {
        let rig = try TalkThroughRig(procedure: TalkThroughFixtures.yesNoProcedure())
        rig.service.start()
        rig.say("Rinsing the filter basket under the tap.")
        rig.say("Filter basket rinsed under the tap.")
        XCTAssertNotNil(rig.service.proposal)
        let presentation = rig.host.activeProcedurePresentation
        XCTAssertTrue(TalkThroughReply.procedureNeeds("yes", on: presentation))
        XCTAssertEqual(ProcedureVoiceDecider.decide("yes", on: try XCTUnwrap(presentation)), .answer("yes"))

        rig.say("yes")
        XCTAssertNotNil(rig.service.proposal, "the step's own yes/no answer is the procedure's")
        XCTAssertFalse(rig.service.takeReply("yes", presentation: presentation), "a turn's yes goes on to the procedure")
        XCTAssertEqual(rig.visited, ["outlet"])
        rig.service.stop()
    }

    func testAReplyThatIsNotTheProceduresIsTakenFromATurnInEitherRunMode() throws {
        let rig = try TalkThroughRig()
        rig.service.start()
        proposeDrain(rig)
        let presentation = rig.host.activeProcedurePresentation
        XCTAssertEqual(ProcedureVoiceDecider.decide("that's right", on: try XCTUnwrap(presentation)), .fallback,
                       "with no model the procedure would only say its one line to it")
        XCTAssertTrue(rig.service.takeReply("that's right", presentation: presentation))
        XCTAssertEqual(rig.visited, ["isolate", "drain"])
        // The same yes heard by the captions and then by a turn is taken once.
        XCTAssertTrue(rig.service.takeReply("that's right", presentation: rig.host.activeProcedurePresentation))
        XCTAssertEqual(rig.visited, ["isolate", "drain"])
        rig.clock.advance(by: TalkThroughService.replyEchoWindow + 1)
        XCTAssertFalse(rig.service.takeReply("yes", presentation: rig.host.activeProcedurePresentation))
        rig.service.stop()
    }

    func testStepWordsAreNeverTalkThroughsCommands() {
        for word in ["next", "done", "skip", "back", "repeat", "go on", "continue", "yes", "no"] {
            XCTAssertNil(TalkThroughVoiceCommand.parse(word), "\"\(word)\" is the procedure's")
        }
        XCTAssertEqual(TalkThroughVoiceCommand.parse("Talk me through it"), .start)
        XCTAssertEqual(TalkThroughVoiceCommand.parse("okay, talk me through this please"), .start)
        XCTAssertEqual(TalkThroughVoiceCommand.parse("Stop talking me through."), .stop)
        XCTAssertEqual(TalkThroughVoiceCommand.parse("just go"), .justGo)
        XCTAssertNil(TalkThroughVoiceCommand.parse("can you talk me through it in more detail"))
    }

    func testRepliesAreShortAndPlain() {
        XCTAssertEqual(TalkThroughReply.parse("yes"), true)
        XCTAssertEqual(TalkThroughReply.parse("Yeah."), true)
        XCTAssertEqual(TalkThroughReply.parse("that's right"), true)
        XCTAssertEqual(TalkThroughReply.parse("no"), false)
        XCTAssertEqual(TalkThroughReply.parse("not yet"), false)
        XCTAssertNil(TalkThroughReply.parse("yes I opened the drain plug and the bucket is filling"))
        XCTAssertNil(TalkThroughReply.parse("Opening the drain plug."))
    }

    // MARK: - The mic by setup

    func testTheMicFollowsTheSetup() {
        XCTAssertEqual(TalkThroughMicPlan.route(glassesConnected: true, glassesHaveDisplay: false), .glasses)
        XCTAssertEqual(TalkThroughMicPlan.route(glassesConnected: true, glassesHaveDisplay: true), .phone)
        XCTAssertEqual(TalkThroughMicPlan.route(glassesConnected: false, glassesHaveDisplay: false), .phone)
    }

    private func inputs(talk: Bool = false, talkMic: MicRoute = .phone, hints: Bool = false,
                        consumer: Bool = false) -> WakeListenPolicy.Inputs {
        WakeListenPolicy.Inputs(listeningEnabled: true, silentMode: false, wearerAudioConsumerActive: consumer,
                                wakeListenMic: .iPhone, micRoute: .glasses, liveHintsActive: hints,
                                talkThroughActive: talk, talkThroughMic: talkMic)
    }

    func testTheIdleListenerTakesTheTalkThroughMic() {
        let glasses = WakeListenPolicy.decide(inputs(talk: true, talkMic: .glasses))
        XCTAssertEqual(glasses.listen, .bluetooth(.glasses), "glasses with no display: the wearer's own mic")
        XCTAssertFalse(glasses.hintsShape)

        let phone = WakeListenPolicy.decide(inputs(talk: true, talkMic: .phone, consumer: true))
        XCTAssertEqual(phone.listen, .phone, "a Display, or no glasses: the phone, over a caption consumer's hold")
        XCTAssertTrue(phone.hintsShape)
        XCTAssertFalse(phone.categoryOptions.contains(.allowBluetoothHFP))
    }

    func testLiveHintsPhoneMicRuleIsUnchanged() {
        XCTAssertEqual(WakeListenPolicy.decide(inputs(hints: true)).listen, .phone)
        XCTAssertTrue(WakeListenPolicy.decide(inputs(hints: true)).hintsShape)
        XCTAssertEqual(WakeListenPolicy.decide(inputs(hints: true, consumer: true)).listen, .phone)
        XCTAssertEqual(WakeListenPolicy.decide(inputs()).listen, .phone)
        XCTAssertFalse(WakeListenPolicy.decide(inputs()).hintsShape)
        XCTAssertEqual(WakeListenPolicy.decide(inputs(consumer: true)).listen, .bluetooth(.glasses))
    }

    // MARK: - A question mid-job

    func testAQuestionShowsTheManualsPassageAtOnce() throws {
        let rig = try TalkThroughRig(lensAvailable: true)
        rig.model.isAvailable = false
        rig.service.start()
        rig.say("How tight should the priming cap be?")
        XCTAssertEqual(rig.manuals.queries, ["How tight should the priming cap be?"])
        let card = try XCTUnwrap(rig.service.questionCard)
        XCTAssertTrue(card.line.contains("priming cap"))
        XCTAssertEqual(card.sourceLabel, "QMX90 Pump Guide, page 12")
        XCTAssertEqual(rig.lens.presented.last?.question, "How tight should the priming cap be?")
        XCTAssertEqual(rig.visited, ["isolate"], "a question never moves anything")
        rig.service.stop()
    }

    func testTheModelIsAskedOnlyAsTheJobsRulesAllow() async throws {
        // Medical Local Only with a cloud model: the passage alone.
        let local = try TalkThroughRig()
        local.service.resolvedProvider = { .anthropic }
        local.service.medicalLocalOnly = { true }
        local.service.start()
        local.say("How tight should the priming cap be?")
        await local.service.waitUntilIdle()
        XCTAssertEqual(local.model.calls.count, 0)
        XCTAssertEqual(local.service.questionCard?.source, .passage)
        local.service.stop()

        // No permitted model: the passage alone.
        let none = try TalkThroughRig()
        none.service.resolvedProvider = { nil }
        none.service.start()
        none.say("How tight should the priming cap be?")
        await none.service.waitUntilIdle()
        XCTAssertEqual(none.model.calls.count, 0)
        none.service.stop()

        // A sealed job: asked, with general knowledge off.
        let sealed = try TalkThroughRig()
        sealed.manuals.hintJobManuals = HintJobManuals(vaultId: "garden", vaultName: "Garden pumps",
                                                       vaultOnly: true, citationsRequired: false)
        sealed.service.resolvedProvider = { .anthropic }
        sealed.service.start()
        sealed.say("How tight should the priming cap be?")
        await sealed.service.waitUntilIdle()
        XCTAssertEqual(sealed.model.calls.count, 1)
        XCTAssertEqual(sealed.model.calls.first?.system,
                       HintPromptBuilder.build(question: "x", earlierLines: [], passages: [], hintLanguageCode: "en-GB",
                                               allowGeneral: false).system)
        sealed.service.stop()
    }

    func testALateModelAnswerDoesNotReplaceThePassage() async throws {
        let rig = try TalkThroughRig()
        rig.service.resolvedProvider = { .anthropic }
        rig.model.replyDelay = HintLimits.modelReplaceWindow + 1
        rig.service.start()
        rig.say("How tight should the priming cap be?")
        await rig.service.waitUntilIdle()
        XCTAssertEqual(rig.model.calls.count, 1)
        XCTAssertEqual(rig.service.questionCard?.source, .passage)
        rig.service.stop()
    }

    func testAQuestionTheManualsCannotAnswerShowsNothing() throws {
        let rig = try TalkThroughRig()
        rig.manuals.result = .nothing(.insufficient)
        rig.service.resolvedProvider = { .anthropic }
        rig.service.start()
        rig.say("What does the warranty cover on this pump?")
        XCTAssertNil(rig.service.questionCard)
        XCTAssertEqual(rig.model.calls.count, 0, "the model is never asked to answer around the gate")
        rig.service.stop()
    }
}
