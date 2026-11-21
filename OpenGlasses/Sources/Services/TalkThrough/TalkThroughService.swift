import Foundation

/// Talk-through (Plan JI §7a, P6b): while a procedure runs, the technician says out loud what they
/// are doing, and the app works out which step they are on, proposes it, and shows that step's
/// authored hint on the lens, in the ear or on the phone.
///
/// **A mode of a running procedure.** It starts on the wearer's word for the procedure running now
/// and stops when that run ends, on the wearer's word, or when live hints starts. It never runs
/// alongside a live hints session (`HintSessionArbiter`); the app stops one before starting the
/// other. It is not a listening session, so the app-wide daily allowance live hints obeys is not
/// drawn on: there is no allowance among its carriers.
///
/// **It reads, it never moves.** Each finished caption goes, in order, to: the author's caution
/// phrases (`CautionPhraseMatcher`: the step's safety note, shown and said at once); a yes or no to
/// a waiting proposal (`TalkThroughReply`, never words the procedure's own voice handling needs);
/// "just go" and "stop talking me through"; a question (`HintTrigger`, answered from the job's
/// manuals); and otherwise `TalkThroughLocator`. A proposal moves the runner only on a yes (a tap,
/// the phone, or the words), and then exactly as a spoken "next" does: through `advanceProcedure`,
/// with the branch's choice where the proposed step lies along one. "Just go" turns proposals into
/// those same advances, said aloud, for the rest of the run.
///
/// **The hints are the author's** (`TalkThroughHint`), shown whenever the runner reaches a step,
/// however it got there. No model writes one. A question gets Field Assist's own manual search with
/// the step beside it (`hintPassages`): the passage at once, and a model's answer only where the
/// job's rules allow one (`HintManualModelRule`) and only if it lands within
/// `HintLimits.modelReplaceWindow`.
///
/// **Delivery is live hints'.** The lens through `HintLensSink` (over a step card a flash, and the
/// step card comes back), the ear through `HintSpeechPolicy` (after a pause, cut off by speech read
/// from the ungated mic level, never the phone speaker), and the phone through what this publishes.
///
/// **Nothing is kept.** Where the technician was, a proposal, an "off order" and a caught phrase
/// live in this object's memory and go at stop. Nothing here writes to the job, the work record,
/// the office, the conversation, memory or disk, and `PrivacyLog` gets lengths and timings only.
@MainActor
final class TalkThroughService: ObservableObject {

    struct Carriers {
        var captions: HintCaptionSource
        var procedure: TalkThroughProcedureHost
        /// The job's manuals, for a question asked mid-job.
        var manuals: HintJobManualSource
        var model: HintModel
        var lens: HintLensSink
        var ear: HintEarSink
        var voiceActivity: HintVoiceActivitySource
        var clock: HintClock
        var similarity: TalkThroughSimilarity
    }

    enum StartOutcome: Equatable {
        case started
        case alreadyRunning
        /// No procedure is running: talk-through belongs to one.
        case noProcedure
    }

    enum StopReason: String, Equatable {
        case wearer
        /// The procedure run it belonged to finished or was replaced.
        case procedureEnded
        /// Live hints started (decision 25).
        case liveHints
        /// The app stayed away as long as captions may.
        case background
    }

    /// A step the narration points at, waiting for the technician's yes.
    struct Proposal: Equatable {
        let stepId: String
        let title: String
        /// The steps from the current one to it, the target last.
        let path: [String]
        let at: Date
    }

    /// A proposal not answered in this long is let go, quietly.
    static let proposalLifetime: TimeInterval = 30
    /// A yes or no heard in the captions is also heard by a turn, when one is open: for this long
    /// after a proposal was answered, the turn's copy is taken and dropped.
    static let replyEchoWindow: TimeInterval = 4

    // MARK: - Published state (the phone)

    @Published private(set) var isRunning = false
    @Published private(set) var justGo = false
    @Published private(set) var proposal: Proposal?
    /// The deviation phrase offered for the step the narration moved past. Phone only, until the
    /// runner moves.
    @Published private(set) var offOrderLine: String?
    /// The current step's authored hint; nil for a step whose author wrote none.
    @Published private(set) var currentHint: TalkThroughHint?
    /// The last question's card: the manual's passage, or the model's answer that replaced it.
    @Published private(set) var questionCard: LiveHint?
    /// The run talk-through belongs to.
    @Published private(set) var procedureId: String?

    // MARK: - Wiring

    let carriers: Carriers
    /// The provider a question's model call would go to now, nil when none may be asked
    /// (`LLMService.statelessModelProvider`).
    var resolvedProvider: () -> LLMProvider? = { nil }
    var medicalLocalOnly: () -> Bool = { false }
    /// The recogniser's words for the session: the procedure's step titles, its calculation names
    /// and the equipment's model (`DictationVocabulary`). The app adds the equipment.
    var vocabulary: (Procedure) -> [String] = { TalkThroughService.procedureVocabulary($0) }
    /// Recognition must stay on the phone now (`TalkThroughRecognitionPolicy`).
    var recognitionMustStayOnPhone: () -> Bool = { false }
    /// Apply (or lift) the captions' on-device requirement for the session.
    var applyOnDeviceRecognition: (Bool) -> Void = { _ in }
    /// Fired when `isRunning` changes: the app moves the mic, the taps and the Live Activity.
    var onRunningChanged: ((Bool) -> Void)?

    // MARK: - Session state

    private var generation = 0
    private var locator = TalkThroughLocator()
    private var cursor = CaptionCursor()
    private var speech = HintSpeechPolicy()
    private var cancelTick: (() -> Void)?
    private var startedCaptions = false
    private var previousContextualStrings: [String] = []
    private var stepId: String?
    private var nextHintID = 0
    private var lensHint: (id: Int, at: Date)?
    /// The newest thing delivered, for a repeat.
    private var lastDelivered: (hint: LiveHint, spoken: String)?
    private var questionTask: Task<Void, Never>?
    private var hintedQuestions: [String] = []
    private var lastQuestionAt: Date?
    private var lastReplyAt: Date?

    init(carriers: Carriers) {
        self.carriers = carriers
    }

    // MARK: - Start and stop

    /// Start talking the running procedure through. The switch is per run: nothing is stored.
    @discardableResult
    func start() -> StartOutcome {
        guard !isRunning else { return .alreadyRunning }
        guard let procedure = carriers.procedure.activeProcedure else { return .noProcedure }
        generation += 1
        procedureId = procedure.id
        justGo = false
        proposal = nil
        offOrderLine = nil
        questionCard = nil
        locator = TalkThroughLocator()
        hintedQuestions = []
        lastQuestionAt = nil
        lastReplyAt = nil
        nextHintID = 0
        lensHint = nil
        lastDelivered = nil

        let captions = carriers.captions
        previousContextualStrings = captions.contextualStrings
        captions.contextualStrings = vocabulary(procedure)
        applyOnDeviceRecognition(recognitionMustStayOnPhone())
        cursor = CaptionCursor()
        _ = cursor.take(newestFirst: captions.captionHistory)
        captions.onHistoryChanged = { [weak self] in self?.captionsChanged() }
        startedCaptions = !captions.isActive
        if startedCaptions { captions.start() }

        speech = HintSpeechPolicy(isPhoneSpeaker: carriers.ear.isPhoneSpeaker)
        carriers.ear.onRouteChanged = { [weak self] isPhoneSpeaker in
            self?.perform(self?.speech.handle(.outputRoute(isPhoneSpeaker: isPhoneSpeaker)))
        }
        carriers.ear.onFinishedSpeaking = { [weak self] in
            self?.perform(self?.speech.handle(.speechFinished))
        }
        carriers.voiceActivity.start { [weak self] isSpeaking in
            guard let self else { return }
            self.perform(self.speech.handle(.speechActivity(isSpeaking: isSpeaking, at: self.carriers.clock.now)))
        }
        cancelTick = carriers.clock.repeating(every: HintLimits.tickInterval) { [weak self] in self?.tick() }

        isRunning = true
        stepId = currentStepId
        showCurrentStepHint(announce: false)
        PrivacyLog.speech(.talkThrough, .started, count: procedure.steps.count)
        onRunningChanged?(true)
        return .started
    }

    /// Stop. Everything the session held goes with it.
    func stop(reason: StopReason = .wearer) {
        guard isRunning else { return }
        generation += 1
        cancelTick?()
        cancelTick = nil
        questionTask?.cancel()
        questionTask = nil

        carriers.voiceActivity.stop()
        carriers.ear.onRouteChanged = nil
        carriers.ear.onFinishedSpeaking = nil
        if speech.speaking != nil { carriers.ear.stopSpeaking() }
        speech = HintSpeechPolicy()
        if let shown = lensHint { carriers.lens.hide(hintID: shown.id) }
        lensHint = nil

        let captions = carriers.captions
        captions.onHistoryChanged = nil
        captions.contextualStrings = previousContextualStrings
        previousContextualStrings = []
        applyOnDeviceRecognition(false)
        if startedCaptions { captions.stop() }
        startedCaptions = false
        (carriers.similarity as? EmbedderTalkThroughSimilarity)?.reset()

        locator = TalkThroughLocator()
        proposal = nil
        offOrderLine = nil
        currentHint = nil
        questionCard = nil
        lastDelivered = nil
        hintedQuestions = []
        stepId = nil
        procedureId = nil
        justGo = false
        isRunning = false
        PrivacyLog.speech(.talkThrough, .stopped, detail: PrivacyToken(reason.rawValue))
        onRunningChanged?(false)
    }

    // MARK: - The wearer's answers

    /// Yes to the waiting proposal: the runner moves as a spoken "next" moves it. Returns the line
    /// to say when the runner refused (an answer owed, a check to confirm), nil otherwise.
    @discardableResult
    func confirmProposal() -> String? {
        guard isRunning, let waiting = proposal else { return nil }
        proposal = nil
        lastReplyAt = carriers.clock.now
        return move(along: waiting.path)
    }

    /// No to the waiting proposal: the position holds, and it is not asked again on this step.
    func declineProposal() {
        guard isRunning, let waiting = proposal else { return }
        proposal = nil
        lastReplyAt = carriers.clock.now
        locator.noteDeclined(waiting.stepId)
        if speech.speaking != nil || speech.waiting != nil { perform(speech.handle(.skipRequested)) }
    }

    /// "Just go": proposals become spoken advances for the rest of the run.
    func turnOnJustGo() {
        guard isRunning else { return }
        justGo = true
        if proposal != nil { _ = confirmProposal() }
    }

    /// Say (or show) the newest thing again: the proposal, the step's hint, or a question's card.
    func repeatHint() {
        guard isRunning else { return }
        if let waiting = proposal {
            deliver(proposalHint(waiting), spoken: TalkThroughCopy.proposal(waiting.title), wearerAsked: true)
            return
        }
        guard let last = lastDelivered else {
            showCurrentStepHint(announce: false, wearerAsked: true)
            return
        }
        if carriers.lens.isAvailable {
            if carriers.lens.reshow(last.hint) { lensHint = (last.hint.id, carriers.clock.now) }
        } else {
            perform(speech.handle(.hintArrived(last.spoken, at: carriers.clock.now)))
        }
    }

    /// Skip what plays; a waiting proposal is let go as a no.
    func skip() {
        if proposal != nil {
            declineProposal()
            return
        }
        perform(speech.handle(.skipRequested))
    }

    /// Something is being said, or waits for quiet to be said.
    var isHintPlaying: Bool { speech.speaking != nil || speech.waiting != nil }

    /// A yes or no from a spoken turn (the wake word's path), when the procedure's own voice
    /// handling doesn't need the words. True when the words were talk-through's: a proposal
    /// answered, or the turn's copy of a reply the captions already answered.
    func takeReply(_ text: String, presentation: ProcedureStepPresentation?) -> Bool {
        guard isRunning, let reply = TalkThroughReply.parse(text),
              !TalkThroughReply.procedureNeeds(text, on: presentation) else { return false }
        if proposal != nil {
            if reply { _ = confirmProposal() } else { declineProposal() }
            return true
        }
        if let lastReplyAt, carriers.clock.now.timeIntervalSince(lastReplyAt) <= Self.replyEchoWindow {
            return true
        }
        return false
    }

    // MARK: - The clock

    private func tick() {
        guard isRunning else { return }
        let now = carriers.clock.now
        // The run it belongs to ended, or another procedure replaced it.
        guard let procedure = carriers.procedure.activeProcedure, procedure.id == procedureId else {
            stop(reason: .procedureEnded)
            return
        }
        if currentStepId != stepId {
            stepId = currentStepId
            stepChanged()
        }
        if let waiting = proposal, now.timeIntervalSince(waiting.at) >= Self.proposalLifetime - HintLimits.timeTolerance {
            proposal = nil
        }
        if let shown = lensHint,
           now.timeIntervalSince(shown.at) >= HintLimits.lensCardLifetime - HintLimits.timeTolerance {
            carriers.lens.hide(hintID: shown.id)
            lensHint = nil
        }
        perform(speech.handle(.tick(at: now)))
    }

    private var currentStepId: String? {
        guard let procedure = carriers.procedure.activeProcedure else { return nil }
        return TalkThroughLocator.currentStepId(procedure: procedure, visited: carriers.procedure.activeProcedureVisited)
    }

    /// The runner reached another step, however it got there: what was asked of the last one goes.
    private func stepChanged() {
        proposal = nil
        offOrderLine = nil
        locator.clearStreak()
        showCurrentStepHint(announce: false)
    }

    // MARK: - Captions

    private func captionsChanged() {
        guard isRunning else { return }
        let fresh = cursor.take(newestFirst: carriers.captions.captionHistory)
        for entry in fresh { handleFinal(entry) }
    }

    private func handleFinal(_ entry: AmbientCaptionService.CaptionEntry) {
        guard isRunning else { return }
        // The step may have moved since the last tick (a button on the phone, a spoken "next").
        if currentStepId != stepId {
            stepId = currentStepId
            stepChanged()
        }
        let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.hasPrefix("[Visual:"),
              let procedure = carriers.procedure.activeProcedure else { return }
        let visited = carriers.procedure.activeProcedureVisited
        let now = carriers.clock.now

        // 1. The author's words to catch: the step's safety note, at once, whatever the pause.
        if let caught = CautionPhraseMatcher.caught(in: text, procedure: procedure, visited: visited),
           let hint = TalkThroughHint.make(for: caught.step), let note = hint.safetyNote {
            deliverSafety(note, hint: hint)
        }

        // 2. A yes or no to the waiting proposal, unless the procedure needs the words.
        if let reply = TalkThroughReply.parse(text) {
            let needed = TalkThroughReply.procedureNeeds(text, on: carriers.procedure.activeProcedurePresentation)
            if proposal != nil, !needed {
                if reply { _ = confirmProposal() } else { declineProposal() }
            }
            return
        }

        // 3. The session's own words, said without the wake word.
        switch TalkThroughVoiceCommand.parse(text) {
        case .justGo?:
            turnOnJustGo()
            return
        case .stop?:
            stop(reason: .wearer)
            return
        case .start?:
            return
        case nil:
            break
        }

        // 4. A question: answered from the job's manuals, with the step beside it.
        let caption = HintCaption(entry, languageCode: carriers.captions.languageCode)
        let context = HintTrigger.Context(mode: .conversation, hintedQuestions: hintedQuestions,
                                          lastHintAt: lastQuestionAt, now: now)
        if case .hint(let question) = HintTrigger.evaluate(caption, context: context) {
            hintedQuestions.append(question)
            lastQuestionAt = now
            answer(question, askedAt: now)
            return
        }

        // 5. Where they are.
        let similarity = carriers.similarity
        let decision = locator.read(caption, procedure: procedure, visited: visited) { sentence, step in
            similarity.similarity(sentence, step)
        }
        switch decision {
        case .stay:
            break
        case let .propose(target, path):
            guard let step = procedure.step(id: target) else { return }
            let waiting = Proposal(stepId: target, title: step.title, path: path, at: now)
            if justGo {
                move(along: path, announce: true)
            } else {
                proposal = waiting
                deliver(proposalHint(waiting), spoken: TalkThroughCopy.proposal(step.title), wearerAsked: false)
            }
        case let .offOrder(target, open):
            guard let step = procedure.step(id: target), let openStep = procedure.step(id: open) else { return }
            let line = TalkThroughCopy.offOrder(target: step.title, open: openStep.title)
            offOrderLine = line
            deliver(makeHint(title: TalkThroughCopy.lensTitle, line: line), spoken: line, wearerAsked: false)
        }
    }

    // MARK: - Moving the runner (on a yes only)

    /// Move along `path` as a spoken "next" would: the photo-aware next where the hop is the step's
    /// own way on, the branch's choice where the target lies along a branch. Returns the refusal
    /// line when the runner refused.
    @discardableResult
    private func move(along path: [String], announce: Bool = false) -> String? {
        let host = carriers.procedure
        for target in path {
            guard let procedure = host.activeProcedure,
                  let from = TalkThroughLocator.currentStepId(procedure: procedure, visited: host.activeProcedureVisited),
                  let step = procedure.step(id: from) else { return nil }
            let choice = Self.choice(from: step, to: target)
            do {
                if let choice {
                    try host.advanceProcedure(choice: choice)
                } else {
                    try host.advanceProcedureAttachingPhotos()
                }
            } catch let refusal as ProcedureAnswerRefusal {
                say(refusal.line)
                return refusal.line
            } catch {
                let line = ProcedureVoiceDecider.refusalLine(error, on: host.activeProcedurePresentation)
                say(line)
                return line
            }
        }
        guard isRunning else { return nil }
        stepId = currentStepId
        proposal = nil
        offOrderLine = nil
        locator.clearStreak()
        guard host.activeProcedure != nil else { return nil }
        showCurrentStepHint(announce: announce)
        return nil
    }

    /// The choice a spoken "next" would pass to reach `target` from `step`: none for its own way
    /// on (`default_next`) and for a step whose rules decide, the branch's id otherwise.
    nonisolated static func choice(from step: Procedure.Step, to target: String) -> String? {
        if step.defaultNext == target || step.isAppDecided || step.branches.isEmpty { return nil }
        return step.branches.first { $0.next == target }?.id
    }

    // MARK: - The step's hint

    private func showCurrentStepHint(announce: Bool, wearerAsked: Bool = false) {
        guard let procedure = carriers.procedure.activeProcedure, let id = currentStepId,
              let step = procedure.step(id: id) else {
            currentHint = nil
            return
        }
        let hint = TalkThroughHint.make(for: step)
        currentHint = hint
        if announce {
            let line = TalkThroughCopy.moved(step.title)
            let spoken = hint.map { line + " " + $0.spoken } ?? line
            deliver(makeHint(title: step.title, line: hint?.lensBody ?? line), spoken: spoken, wearerAsked: wearerAsked)
            return
        }
        guard let hint else { return }
        deliver(makeHint(title: hint.lensTitle, line: hint.lensBody), spoken: hint.spoken, wearerAsked: wearerAsked)
    }

    /// A caught phrase: the safety note on the lens and in the ear at once, whatever the pause.
    private func deliverSafety(_ note: String, hint: TalkThroughHint) {
        let card = makeHint(title: hint.lensTitle, line: TalkThroughHint.Item.safety(note).text)
        lastDelivered = (card, note)
        if carriers.lens.isAvailable, carriers.lens.reshow(card) { lensHint = (card.id, carriers.clock.now) }
        let action = speech.handle(.urgentArrived(note, at: carriers.clock.now))
        if case .speak = action { carriers.ear.stopSpeaking() }
        perform(action)
    }

    private func proposalHint(_ proposal: Proposal) -> LiveHint {
        makeHint(title: TalkThroughCopy.lensTitle,
                 line: TalkThroughCopy.proposal(proposal.title) + " " + TalkThroughCopy.proposalPrompt)
    }

    private func makeHint(title: String, line: String) -> LiveHint {
        nextHintID += 1
        return LiveHint(id: nextHintID, question: nil, keyword: title, line: line, full: "",
                        spoken: HintReply.cutSpoken(line), source: .authored, general: false,
                        passage: nil, askedAt: carriers.clock.now)
    }

    /// To the lens when there is one (with a soft tick), to the ear otherwise.
    private func deliver(_ hint: LiveHint, spoken: String, wearerAsked: Bool) {
        lastDelivered = (hint, spoken)
        if carriers.lens.isAvailable {
            let shown = wearerAsked ? carriers.lens.reshow(hint) : carriers.lens.present(hint)
            if shown {
                lensHint = (hint.id, carriers.clock.now)
                if !carriers.ear.isPhoneSpeaker { carriers.ear.chime() }
                return
            }
        }
        perform(speech.handle(.hintArrived(spoken, at: carriers.clock.now)))
    }

    private func say(_ line: String) {
        perform(speech.handle(.hintArrived(line, at: carriers.clock.now)))
    }

    private func perform(_ action: HintSpeechPolicy.Action?) {
        switch action {
        case .speak(let text)?:
            carriers.ear.sayHint(text)
            PrivacyLog.speech(.talkThrough, .hintSpoken, characters: text.count)
        case .stopSpeaking?:
            carriers.ear.stopSpeaking()
        case .drop?, .none?, nil:
            break
        }
    }

    // MARK: - A question mid-job

    /// The job's manuals searched with the step beside the question (`hintPassages`), the passage
    /// shown at once, and a model's answer only where the job's rules allow and only within the
    /// replace window. Never a web search: the search is the vault's, and the call is tool-free.
    private func answer(_ question: String, askedAt: Date) {
        questionTask?.cancel()
        let session = generation
        let manuals = carriers.manuals
        let found = manuals.hintPassages(for: question, limit: HintLimits.passagesMax)
        guard case .passages(let passages) = found else {
            if case .nothing(let reason) = found {
                PrivacyLog.speech(.talkThrough, .hintSkipped, detail: PrivacyToken("question-" + reason.rawValue))
            }
            return
        }
        var shown: (hint: LiveHint, at: Date)?
        if let card = PassageHint.pick(from: passages, for: question) {
            nextHintID += 1
            let hint = LiveHintsService.passageHint(card, id: nextHintID, question: question, keyword: nil, askedAt: askedAt)
            questionCard = hint
            deliver(hint, spoken: hint.spoken, wearerAsked: false)
            shown = (hint, carriers.clock.now)
            PrivacyLog.speech(.talkThrough, .hintShown, characters: hint.line.count,
                              seconds: carriers.clock.now.timeIntervalSince(askedAt), detail: PrivacyToken("passage"))
        }
        guard let job = manuals.hintJobManuals else { return }
        guard case .ask(let allowGeneral) = HintManualModelRule.decide(job: job, resolvedProvider: resolvedProvider(),
                                                                      medicalLocalOnly: medicalLocalOnly()),
              carriers.model.isAvailable else { return }
        let prompt = HintPromptBuilder.build(question: question, earlierLines: [], passages: passages,
                                             hintLanguageCode: carriers.captions.languageCode,
                                             allowGeneral: allowGeneral)
        let model = carriers.model
        let shownCard = shown
        questionTask = Task { [weak self] in
            let raw: String
            do {
                raw = try await model.complete(system: prompt.system, user: prompt.user)
            } catch {
                PrivacyLog.speech(.talkThrough, .providerUnavailable, error: SafeErrorSummary(error))
                return
            }
            guard let self, session == self.generation, self.isRunning, !Task.isCancelled,
                  case .hint(let reply) = HintReply.parse(raw) else { return }
            let now = self.carriers.clock.now
            if let shown = shownCard {
                guard now.timeIntervalSince(shown.at) <= HintLimits.modelReplaceWindow + HintLimits.timeTolerance else { return }
                var better = shown.hint
                better.line = reply.hint
                better.full = reply.full
                better.spoken = reply.spokenHint
                better.source = .model
                better.general = reply.general
                if reply.general { better.passage = nil }
                self.questionCard = better
                self.deliver(better, spoken: better.spoken, wearerAsked: false)
            } else {
                self.nextHintID += 1
                let hint = LiveHint(id: self.nextHintID, question: question, keyword: nil, line: reply.hint,
                                    full: reply.full, spoken: reply.spokenHint, source: .model, general: reply.general,
                                    passage: nil, askedAt: askedAt)
                self.questionCard = hint
                self.deliver(hint, spoken: hint.spoken, wearerAsked: false)
            }
            PrivacyLog.speech(.talkThrough, .hintReplaced, characters: reply.hint.count,
                              seconds: now.timeIntervalSince(askedAt))
        }
    }

    /// Wait for a question's model call. Tests use it; the app never waits on it.
    func waitUntilIdle() async {
        await questionTask?.value
    }

    // MARK: - Vocabulary

    /// The procedure's own words for the recogniser: its step titles and the names in its
    /// calculations (`calc_ref.op`, as said). The app adds the equipment's model.
    nonisolated static func procedureVocabulary(_ procedure: Procedure, equipment: EquipmentIdentity? = nil) -> [String] {
        var words = procedure.steps.map(\.title)
        words += procedure.steps.compactMap { $0.calcRef?.op.replacingOccurrences(of: "_", with: " ") }
        return DictationVocabulary.build(DictationVocabulary.Input(activeEquipment: equipment, procedureWords: words))
    }
}
