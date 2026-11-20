import Foundation

/// A live-hints session (Plan MO P1): listens to the room through the captions and, when someone
/// asks the wearer a question, puts a short answer from the wearer's own documents on the lens or
/// in their ear.
///
/// **Start and stop.** Only on the wearer's word (`start`), never by itself. The first start ever
/// raises the first-run sheet (`firstRunPending`) and waits for it; every start shows the capture
/// notice (`notice`). Captions are turned on if they are off, and back off at stop only if the
/// session turned them on. The session stops on `stop()`, at the two-hour limit (warned five
/// minutes before), or when the app-wide daily allowance says time is up. Captions alone never
/// charge the allowance: only a running session does, from its own tick.
///
/// **The answer path (§5).** Each final caption goes through `HintTrigger`. A question waits in a
/// `HintQueue`, so one is answered at a time and a newer one replaces a waiting one. For each: the
/// documents are searched (`HintDocumentSearch`), the best passage's sentence goes out at once as
/// the first card (`PassageHint`), then one model call (`HintModel`, with `HintPromptBuilder` and
/// `HintReply`) whose hint replaces the passage card only if it lands within
/// `HintLimits.modelReplaceWindow`. Keyword mode, and a session with no model to ask, show the
/// passage card alone. Answers are cached for the session by the question's normalised words.
///
/// **Delivery (§6).** The lens when a Display is there (`HintLensSink`, two pages, hidden after
/// `HintLimits.lensCardLifetime`, the next replacing it), with a soft tick in the ear; otherwise the
/// ear through `HintSpeechPolicy` (speak when quiet, stop when someone talks, never the phone
/// speaker), with speech activity read from the ungated mic level (`HintVoiceActivitySource`). Every
/// hint also goes to the phone's list (`HintPhoneListSink`), in memory only.
///
/// **Lecture mode (§2).** `MeetingAssistantService` fed with the session's finals, through
/// `LectureKeyPointSink`: about every 60 s, or at a pause after about 100 words, one key-point line
/// for the lens. A question asked of the room is still hinted.
///
/// **What is kept (§9).** Nothing. No hint, question or passage is written to the conversation,
/// memory or disk, the wearer's own voice ("That's me", `markWearer`) is held in memory for the
/// session and never written to the speaker names, and `PrivacyLog` records timings, lengths and
/// reasons only.
@MainActor
final class LiveHintsService: ObservableObject {

    /// What a session is set to (the session sheet, P2).
    struct Settings: Equatable {
        var mode: HintMode = .conversation
        /// Keyword mode's trigger words; also the recogniser's first words in every mode (§8).
        var keywords: [String] = []
        /// The language hints are written in. Nil: the captions' language.
        var hintLanguageCode: String?
        /// Answer from general knowledge, marked so, when the documents don't hold it (decision 6).
        var allowGeneral = true

        init(mode: HintMode = .conversation, keywords: [String] = [], hintLanguageCode: String? = nil,
             allowGeneral: Bool = true) {
            self.mode = mode
            self.keywords = keywords
            self.hintLanguageCode = hintLanguageCode
            self.allowGeneral = allowGeneral
        }
    }

    enum StartOutcome: Equatable {
        case started
        /// The first-run sheet is up; the session starts from `acknowledgeFirstRun()`.
        case needsFirstRun
        case alreadyRunning
        /// Live hints is switched off (`AIFeature.liveHints`).
        case disabled
        /// The app-wide daily allowance has no time left.
        case allowanceSpent
    }

    enum StopReason: String, Equatable {
        case wearer, sessionLimit, allowance
    }

    /// Everything the session talks to.
    struct Carriers {
        var captions: HintCaptionSource
        var documents: HintDocumentSearch
        var model: HintModel
        var lens: HintLensSink
        var ear: HintEarSink
        var voiceActivity: HintVoiceActivitySource
        var phoneList: HintPhoneListSink
        var clock: HintClock
        var allowance: HintSessionAllowance
    }

    // MARK: - Published state

    @Published private(set) var isRunning = false
    @Published private(set) var mode: HintMode = .conversation
    /// The first-run sheet is waiting for the wearer.
    @Published private(set) var firstRunPending = false
    /// One line for the phone: the capture notice at every start, or why the session stopped.
    @Published private(set) var notice: String?
    @Published private(set) var startedAt: Date?
    /// The wearer's diarized speaker, once they tapped "That's me". Session memory only.
    @Published private(set) var wearerSpeaker: Int?
    /// Model calls this session (the session footer's count).
    @Published private(set) var modelCalls = 0
    /// Cards this session.
    @Published private(set) var hintsShown = 0
    @Published private(set) var lastStopReason: StopReason?
    /// From each question's final to its first card, this session (and the last, after stop).
    private(set) var latency = HintLatencyStats()

    // MARK: - Wiring

    let carriers: Carriers
    /// Whether the feature is switched on.
    var isEnabled: () -> Bool = { AIFeatureGate.isEnabled(.liveHints) }
    /// The first-run sheet's flag, read and written through these so tests keep preferences alone.
    var firstRunAcknowledged: () -> Bool = { Config.liveHintsFirstRunAcknowledged }
    var setFirstRunAcknowledged: (Bool) -> Void = { Config.liveHintsFirstRunAcknowledged = $0 }
    /// Fired when `isRunning` changes: AppState moves the idle audio session to the hints shape.
    var onRunningChanged: ((Bool) -> Void)?

    // MARK: - Session state

    private var settings = Settings()
    private var pendingSettings: Settings?
    private var generation = 0
    private var cursor = CaptionCursor()
    private var keywordMatcher = KeywordMatcher(keywords: [])
    private var hintedQuestions: [String] = []
    private var lastHintAt: Date?
    private var lastHintSpeaker: Int?
    /// The finals before the newest, oldest first, for the prompt's context.
    private var earlierLines: [String] = []
    private var queue = HintQueue<HintRequest>()
    private var answerTask: Task<Void, Never>?
    private var cache: [String: LiveHint] = [:]
    private var speech = HintSpeechPolicy()
    private var nextHintID = 0
    private var lensHint: (id: Int, at: Date)?
    private var startedCaptions = false
    private var previousContextualStrings: [String] = []
    private var cancelTick: (() -> Void)?
    private var lastChargeAt: Date?
    private var warned = false
    private let lectureAssistant = MeetingAssistantService()

    /// One question waiting for, or being given, an answer.
    struct HintRequest: Equatable {
        let question: String
        let earlier: [String]
        let askedAt: Date
        let speaker: Int?
    }

    init(carriers: Carriers) {
        self.carriers = carriers
    }

    // MARK: - Start and stop

    /// Start a session. The first start ever raises the first-run sheet instead, and starts once the
    /// wearer goes on from it.
    @discardableResult
    func start(_ settings: Settings = Settings()) -> StartOutcome {
        guard isEnabled() else { return .disabled }
        guard !isRunning else { return .alreadyRunning }
        if let remaining = carriers.allowance.remaining(), remaining <= 0 { return .allowanceSpent }
        guard firstRunAcknowledged() else {
            pendingSettings = settings
            firstRunPending = true
            return .needsFirstRun
        }
        begin(settings)
        return .started
    }

    /// The wearer went on from the first-run sheet: it is not shown again, and the session starts.
    @discardableResult
    func acknowledgeFirstRun() -> StartOutcome {
        setFirstRunAcknowledged(true)
        firstRunPending = false
        let settings = pendingSettings ?? Settings()
        pendingSettings = nil
        return start(settings)
    }

    /// The wearer closed the first-run sheet without starting. It shows again at the next start.
    func dismissFirstRun() {
        firstRunPending = false
        pendingSettings = nil
    }

    /// The banner shown the notice for long enough.
    func dismissNotice() {
        notice = nil
    }

    private func begin(_ settings: Settings) {
        self.settings = settings
        generation += 1
        let now = carriers.clock.now
        mode = settings.mode
        startedAt = now
        lastChargeAt = now
        warned = false
        modelCalls = 0
        hintsShown = 0
        latency.reset()
        lastStopReason = nil
        wearerSpeaker = nil
        hintedQuestions = []
        lastHintAt = nil
        lastHintSpeaker = nil
        earlierLines = []
        cache = [:]
        queue.reset()
        nextHintID = 0
        lensHint = nil
        keywordMatcher = KeywordMatcher(keywords: settings.keywords)

        // The recogniser hears the session's words (§8), from its first request when captions start
        // here; captions already running take them at their next recognition restart.
        let captions = carriers.captions
        previousContextualStrings = captions.contextualStrings
        captions.contextualStrings = DictationVocabulary.build(
            DictationVocabulary.Input(keywords: settings.keywords,
                                      documentTitles: carriers.documents.documentTitles()))
        // Start from the present: what was said before the session is not asked of it.
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

        if settings.mode == .lecture { startLecture() }

        cancelTick = carriers.clock.repeating(every: HintLimits.tickInterval) { [weak self] in self?.tick() }
        notice = LiveHintsCopy.captureNotice
        isRunning = true
        PrivacyLog.speech(.liveHints, .started, detail: PrivacyToken(settings.mode.rawValue))
        onRunningChanged?(true)
    }

    /// Stop the session. Everything it held goes with it.
    func stop(reason: StopReason = .wearer) {
        guard isRunning else { return }
        let now = carriers.clock.now
        chargeAllowance(at: now)
        generation += 1
        cancelTick?()
        cancelTick = nil
        answerTask?.cancel()
        answerTask = nil
        queue.reset()
        lectureAssistant.stop()

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
        if startedCaptions { captions.stop() }
        startedCaptions = false

        carriers.phoneList.clear()
        cache = [:]
        hintedQuestions = []
        earlierLines = []
        wearerSpeaker = nil
        keywordMatcher = KeywordMatcher(keywords: [])

        isRunning = false
        startedAt = nil
        lastStopReason = reason
        PrivacyLog.speech(.liveHints, .latencyReport, count: latency.count,
                          detail: PrivacyToken(Self.latencyToken(latency)))
        PrivacyLog.speech(.liveHints, .stopped, count: modelCalls, detail: PrivacyToken(reason.rawValue))
        onRunningChanged?(false)

        // Said after the teardown, so nothing above cuts it short. Never through the phone speaker.
        let line: String? = switch reason {
        case .wearer: nil
        case .sessionLimit: LiveHintsCopy.limitReached
        case .allowance: LiveHintsCopy.allowanceSpent
        }
        if let line {
            notice = line
            if !carriers.ear.isPhoneSpeaker { carriers.ear.sayHint(line) }
        }
    }

    /// "That's me" (§3): the wearer's diarized speaker, in memory for this session only. Nil
    /// hints every voice again.
    func markWearer(speaker: Int?) {
        guard isRunning else { return }
        wearerSpeaker = speaker
    }

    /// Repeat the last hint in the ear (a temple tap or a media button, P2).
    func repeatLastHint() {
        perform(speech.handle(.repeatRequested(at: carriers.clock.now)))
    }

    /// Skip the hint being spoken, or the one waiting.
    func skipHint() {
        perform(speech.handle(.skipRequested))
    }

    // MARK: - The clock

    private func tick() {
        guard isRunning, let startedAt else { return }
        let now = carriers.clock.now
        chargeAllowance(at: now)
        if let remaining = carriers.allowance.remaining(), remaining <= 0 {
            stop(reason: .allowance)
            return
        }
        let elapsed = now.timeIntervalSince(startedAt)
        if elapsed >= HintLimits.sessionLimit - HintLimits.timeTolerance {
            stop(reason: .sessionLimit)
            return
        }
        if !warned, elapsed >= HintLimits.sessionWarningAt - HintLimits.timeTolerance {
            warned = true
            notice = LiveHintsCopy.limitWarning
            if !carriers.ear.isPhoneSpeaker { carriers.ear.sayHint(LiveHintsCopy.limitWarning) }
            PrivacyLog.speech(.liveHints, .limitWarned, seconds: elapsed)
        }
        if let shown = lensHint,
           now.timeIntervalSince(shown.at) >= HintLimits.lensCardLifetime - HintLimits.timeTolerance {
            carriers.lens.hide(hintID: shown.id)
            lensHint = nil
        }
        perform(speech.handle(.tick(at: now)))
    }

    private func chargeAllowance(at now: Date) {
        guard let last = lastChargeAt else { return }
        let used = now.timeIntervalSince(last)
        lastChargeAt = now
        if used > 0 { carriers.allowance.charge(used) }
    }

    // MARK: - Captions

    private func captionsChanged() {
        guard isRunning else { return }
        let fresh = cursor.take(newestFirst: carriers.captions.captionHistory)
        guard !fresh.isEmpty else { return }
        for entry in fresh { handleFinal(entry) }
        if settings.mode == .lecture { lectureAssistant.ingest(fresh) }
    }

    private func handleFinal(_ entry: AmbientCaptionService.CaptionEntry) {
        let now = carriers.clock.now
        let caption = HintCaption(entry, languageCode: carriers.captions.languageCode)
        let context = HintTrigger.Context(mode: settings.mode, wearerSpeaker: wearerSpeaker,
                                          hintedQuestions: hintedQuestions, lastHintAt: lastHintAt,
                                          lastHintSpeaker: lastHintSpeaker, now: now)
        let outcome = HintTrigger.evaluate(caption, context: context, keywords: &keywordMatcher)
        let earlier = earlierLines
        if !entry.text.hasPrefix("[Visual:") {
            earlierLines.append(entry.text)
            if earlierLines.count > HintLimits.earlierLinesMax { earlierLines.removeFirst() }
        }
        switch outcome {
        case .hint(let question):
            hintedQuestions.append(question)
            lastHintAt = now
            lastHintSpeaker = entry.speaker
            offer(HintRequest(question: question, earlier: earlier, askedAt: now, speaker: entry.speaker))
        case .keyword(let word):
            showKeyword(word, askedAt: now)
        case .none(let reason):
            if Self.loggedSkips.contains(reason) {
                PrivacyLog.speech(.liveHints, .hintSkipped, detail: PrivacyToken(reason.rawValue))
            }
        }
    }

    /// The skips worth a line in the report: a question the session chose not to hint. Not every
    /// caption that was no question at all.
    private static let loggedSkips: Set<HintTrigger.SkipReason> = [
        .wearer, .tagQuestion, .smallTalk, .alreadyHinted, .tooSoon,
    ]

    // MARK: - The answer path

    private func offer(_ request: HintRequest) {
        switch queue.offer(request) {
        case .start(let request):
            startAnswering(request)
        case .waiting(let replaced):
            guard let replaced else { return }
            // Never hinted: asked again later, it is not a repeat.
            if let index = hintedQuestions.lastIndex(of: replaced.question) { hintedQuestions.remove(at: index) }
            PrivacyLog.speech(.liveHints, .hintSkipped, detail: PrivacyToken("replacedWhileWaiting"))
        }
    }

    private func startAnswering(_ request: HintRequest) {
        let session = generation
        answerTask = Task { [weak self] in
            await self?.answer(request, session: session)
            guard let self, session == self.generation else { return }
            if let next = self.queue.finish() {
                self.startAnswering(next)
            } else {
                self.answerTask = nil
            }
        }
    }

    /// Wait until no answer is in flight or waiting. Tests use it; the app never waits on it.
    func waitUntilIdle() async {
        while let task = answerTask {
            await task.value
            if answerTask == task { break }
        }
    }

    /// The lecture's key-point analysis now running, if any. Tests await it.
    var lectureAnalysisTask: Task<Void, Never>? { lectureAssistant.analysisTask }

    /// The normalised question an answer is cached by.
    nonisolated static func cacheKey(_ question: String) -> String {
        HintText.normalized(question)
    }

    private func answer(_ request: HintRequest, session: Int) async {
        let key = Self.cacheKey(request.question)
        if let cached = cache[key] {
            let hint = LiveHint(id: makeHintID(), question: request.question, keyword: nil, line: cached.line,
                            full: cached.full, spoken: cached.spoken, source: cached.source,
                            general: cached.general, passage: cached.passage, askedAt: request.askedAt)
            show(hint, firstFor: request)
            PrivacyLog.speech(.liveHints, .hintShown, characters: hint.line.count,
                              detail: PrivacyToken("cache"))
            return
        }

        let passages = carriers.documents.passages(for: request.question, limit: HintLimits.passagesMax)
        let card = PassageHint.pick(from: passages, for: request.question)
        var shown: (hint: LiveHint, at: Date)?
        if let card {
            let hint = Self.passageHint(card, id: makeHintID(), question: request.question, keyword: nil,
                                        askedAt: request.askedAt)
            show(hint, firstFor: request)
            shown = (hint, carriers.clock.now)
            PrivacyLog.speech(.liveHints, .hintShown, characters: hint.line.count,
                              seconds: carriers.clock.now.timeIntervalSince(request.askedAt),
                              detail: PrivacyToken(LiveHint.Source.passage.rawValue))
        }

        guard settings.mode != .keyword, carriers.model.isAvailable else {
            if let shown { cache[key] = shown.hint } else {
                PrivacyLog.speech(.liveHints, .hintSkipped, detail: PrivacyToken("noPassageNoModel"))
            }
            return
        }

        let prompt = HintPromptBuilder.build(question: request.question, earlierLines: request.earlier,
                                             passages: passages,
                                             hintLanguageCode: settings.hintLanguageCode ?? carriers.captions.languageCode,
                                             allowGeneral: settings.allowGeneral)
        modelCalls += 1
        let raw: String
        do {
            raw = try await carriers.model.complete(system: prompt.system, user: prompt.user)
        } catch {
            guard session == generation else { return }
            PrivacyLog.speech(.liveHints, .providerUnavailable, error: SafeErrorSummary(error))
            if let shown { cache[key] = shown.hint }
            return
        }
        guard session == generation, isRunning, !Task.isCancelled else { return }

        guard case .hint(let reply) = HintReply.parse(raw) else {
            PrivacyLog.speech(.liveHints, .hintSkipped, detail: PrivacyToken("nothingToShow"))
            if let shown { cache[key] = shown.hint }
            return
        }

        let now = carriers.clock.now
        if let shown {
            guard now.timeIntervalSince(shown.at) <= HintLimits.modelReplaceWindow + HintLimits.timeTolerance else {
                PrivacyLog.speech(.liveHints, .hintSkipped, seconds: now.timeIntervalSince(shown.at),
                                  detail: PrivacyToken("modelLate"))
                cache[key] = shown.hint
                return
            }
            var better = shown.hint
            better.line = reply.hint
            better.full = reply.full
            better.spoken = reply.spokenHint
            better.source = .model
            better.general = reply.general
            if reply.general { better.passage = nil }
            deliver(better, isUpdate: true)
            cache[key] = better
            PrivacyLog.speech(.liveHints, .hintReplaced, characters: better.line.count,
                              seconds: now.timeIntervalSince(request.askedAt))
        } else {
            let hint = LiveHint(id: makeHintID(), question: request.question, keyword: nil, line: reply.hint,
                                full: reply.full, spoken: reply.spokenHint, source: .model, general: reply.general,
                                passage: nil, askedAt: request.askedAt)
            show(hint, firstFor: request)
            cache[key] = hint
            PrivacyLog.speech(.liveHints, .hintShown, characters: hint.line.count,
                              seconds: now.timeIntervalSince(request.askedAt),
                              detail: PrivacyToken(LiveHint.Source.model.rawValue))
        }
    }

    /// Keyword mode (§2, §5 step 4): the passage the keyword hits, as a fact card. No model.
    private func showKeyword(_ word: String, askedAt: Date) {
        let passages = carriers.documents.passages(for: word, limit: HintLimits.passagesMax)
        guard let card = PassageHint.pick(from: passages, for: word) else {
            PrivacyLog.speech(.liveHints, .hintSkipped, detail: PrivacyToken("keywordNoPassage"))
            return
        }
        let hint = Self.passageHint(card, id: makeHintID(), question: nil, keyword: word, askedAt: askedAt)
        deliver(hint, isUpdate: false)
        latency.record(carriers.clock.now.timeIntervalSince(askedAt))
        PrivacyLog.speech(.liveHints, .hintShown, characters: hint.line.count,
                          seconds: carriers.clock.now.timeIntervalSince(askedAt),
                          detail: PrivacyToken("keyword"))
    }

    /// The no-model card as a hint: the passage's sentence is the line, the ear form its first
    /// words.
    nonisolated static func passageHint(_ card: PassageHint, id: Int, question: String?, keyword: String?,
                                        askedAt: Date) -> LiveHint {
        LiveHint(id: id, question: question, keyword: keyword, line: card.text, full: "",
                 spoken: HintReply.cutSpoken(card.text), source: .passage, general: false,
                 passage: card, askedAt: askedAt)
    }

    /// A question's first card: counted, and its latency recorded.
    private func show(_ hint: LiveHint, firstFor request: HintRequest) {
        deliver(hint, isUpdate: false)
        latency.record(carriers.clock.now.timeIntervalSince(request.askedAt))
    }

    private func makeHintID() -> Int {
        nextHintID += 1
        return nextHintID
    }

    // MARK: - Lecture mode

    private func startLecture() {
        let model = carriers.model
        let session = generation
        lectureAssistant.startFed(
            llm: { prompt in try await model.complete(system: LectureKeyPointSink.system, user: prompt) },
            sink: LectureKeyPointSink { [weak self] line in
                guard let self, session == self.generation, self.isRunning else { return }
                self.showKeyPoint(line)
            })
    }

    private func showKeyPoint(_ line: String) {
        let now = carriers.clock.now
        let hint = LiveHint(id: makeHintID(), question: nil, keyword: nil, line: line, full: "",
                            spoken: HintReply.cutSpoken(line), source: .keyPoint, general: false,
                            passage: nil, askedAt: now)
        // Key points are for the lens and the phone; the ear is kept for questions.
        carriers.phoneList.record(hint)
        hintsShown += 1
        if carriers.lens.isAvailable, carriers.lens.present(hint) { lensHint = (hint.id, now) }
        PrivacyLog.speech(.liveHints, .hintShown, characters: line.count,
                          detail: PrivacyToken(LiveHint.Source.keyPoint.rawValue))
    }

    // MARK: - Delivery

    private func deliver(_ hint: LiveHint, isUpdate: Bool) {
        let now = carriers.clock.now
        if isUpdate { carriers.phoneList.update(hint) } else {
            carriers.phoneList.record(hint)
            hintsShown += 1
        }
        if carriers.lens.isAvailable {
            // A lens the wearer dismissed stays dismissed: the hint is on the phone.
            guard carriers.lens.present(hint) else { return }
            lensHint = (hint.id, isUpdate ? (lensHint?.at ?? now) : now)
            if !isUpdate, !carriers.ear.isPhoneSpeaker { carriers.ear.chime() }
        } else {
            perform(speech.handle(.hintArrived(hint.spoken, at: now)))
        }
    }

    private func perform(_ action: HintSpeechPolicy.Action?) {
        switch action {
        case .speak(let text)?:
            carriers.ear.sayHint(text)
            PrivacyLog.speech(.liveHints, .hintSpoken, characters: text.count)
        case .stopSpeaking?:
            carriers.ear.stopSpeaking()
        case .drop(let reason)?:
            PrivacyLog.speech(.liveHints, .hintSkipped, detail: PrivacyToken("ear-" + reason.rawValue))
        case .none?, nil:
            break
        }
    }

    // MARK: - The report

    /// p50 and p95 as milliseconds, for the log: "p50ms-820.p95ms-2400", or "none".
    nonisolated static func latencyToken(_ stats: HintLatencyStats) -> String {
        guard let p50 = stats.p50, let p95 = stats.p95 else { return "none" }
        return "p50ms-\(Int((p50 * 1000).rounded())).p95ms-\(Int((p95 * 1000).rounded()))"
    }
}
