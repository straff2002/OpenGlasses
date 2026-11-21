import XCTest
@testable import OpenGlasses

// MARK: - Fakes

@MainActor
final class FakeHintCaptions: HintCaptionSource {
    var isActive = false
    var captionHistory: [AmbientCaptionService.CaptionEntry] = []
    var languageCode = "en-GB"
    var onHistoryChanged: (() -> Void)?
    var contextualStrings: [String] = []
    private(set) var starts = 0
    private(set) var stops = 0
    private var seq: UInt64 = 0

    func start() { starts += 1; isActive = true }
    func stop() { stops += 1; isActive = false }

    /// A final caption arrives, as the caption service appends one (newest first).
    func say(_ text: String, speaker: Int? = nil, at date: Date = Date()) {
        seq += 1
        captionHistory.insert(AmbientCaptionService.CaptionEntry(text: text, timestamp: date, seq: seq,
                                                                 speaker: speaker), at: 0)
        onHistoryChanged?()
    }
}

@MainActor
final class FakeHintDocuments: HintDocumentSearch {
    var passages: [HintPassage] = []
    var titles: [String] = []
    private(set) var queries: [String] = []

    func passages(for question: String, limit: Int) -> [HintPassage] {
        queries.append(question)
        return Array(passages.prefix(limit))
    }

    func documentTitles() -> [String] { titles }
}

@MainActor
final class FakeHintModel: HintModel {
    var isAvailable = true
    /// What the model replies, and what the clock reads when it does.
    var reply: String = #"{"hint": "12 weeks from install", "full": "The compressor warranty is 12 weeks from the install date.", "general": false}"#
    var replyDelay: TimeInterval = 0
    var error: Error?
    weak var clock: FakeHintClock?
    private(set) var calls: [(system: String, user: String)] = []

    func complete(system: String, user: String) async throws -> String {
        calls.append((system, user))
        if replyDelay > 0 { clock?.advance(by: replyDelay, ticking: false) }
        if let error { throw error }
        return reply
    }
}

@MainActor
final class FakeHintLens: HintLensSink {
    var isAvailable = true
    var accepts = true
    private(set) var presented: [LiveHint] = []
    private(set) var hidden: [Int] = []

    func present(_ hint: LiveHint) -> Bool {
        guard accepts else { return false }
        presented.append(hint)
        return true
    }

    func hide(hintID: Int) { hidden.append(hintID) }
}

@MainActor
final class FakeHintEar: HintEarSink {
    var isPhoneSpeaker = false
    var onRouteChanged: ((Bool) -> Void)?
    var onFinishedSpeaking: (() -> Void)?
    private(set) var spoken: [String] = []
    private(set) var stops = 0
    private(set) var chimes = 0

    func sayHint(_ text: String) { spoken.append(text) }
    func stopSpeaking() { stops += 1 }
    func chime() { chimes += 1 }
}

@MainActor
final class FakeHintVoiceActivity: HintVoiceActivitySource {
    private(set) var onChange: ((Bool) -> Void)?
    private(set) var running = false
    func start(onChange: @escaping (Bool) -> Void) { self.onChange = onChange; running = true }
    func stop() { onChange = nil; running = false }
}

@MainActor
final class FakeHintClock: HintClock {
    var now: Date
    private var tick: (@MainActor () -> Void)?

    init(now: Date) { self.now = now }

    func repeating(every interval: TimeInterval, _ tick: @escaping @MainActor () -> Void) -> () -> Void {
        self.tick = tick
        return { [weak self] in self?.tick = nil }
    }

    var isTicking: Bool { tick != nil }

    func advance(by seconds: TimeInterval, ticking: Bool = true) {
        now = now.addingTimeInterval(seconds)
        if ticking { tick?() }
    }
}

@MainActor
final class FakeHintAllowance: HintSessionAllowance {
    var left: TimeInterval?
    private(set) var charged: TimeInterval = 0
    init(left: TimeInterval? = nil) { self.left = left }
    func remaining() -> TimeInterval? { left.map { $0 - charged } }
    func charge(_ seconds: TimeInterval) { charged += seconds }
}

// MARK: - Tests

/// Plan MO P1: the live-hints session, headless, with every carrier faked.
@MainActor
final class LiveHintsServiceTests: XCTestCase {

    private var captions: FakeHintCaptions!
    private var documents: FakeHintDocuments!
    private var model: FakeHintModel!
    private var lens: FakeHintLens!
    private var ear: FakeHintEar!
    private var voice: FakeHintVoiceActivity!
    private var list: LiveHintsPhoneList!
    private var clock: FakeHintClock!
    private var allowance: FakeHintAllowance!
    private var acknowledged = true
    private var enabled = true

    private let warrantyPassage = HintPassage(
        documentId: "doc-1", documentName: "Service terms", chunkIndex: 3,
        text: "Parts are covered for a year. The compressor warranty runs 12 weeks from the install date.")

    override func setUp() async throws {
        captions = FakeHintCaptions()
        documents = FakeHintDocuments()
        documents.passages = [warrantyPassage]
        model = FakeHintModel()
        lens = FakeHintLens()
        ear = FakeHintEar()
        voice = FakeHintVoiceActivity()
        list = LiveHintsPhoneList()
        clock = FakeHintClock(now: Date(timeIntervalSinceReferenceDate: 800_000_000))
        model.clock = clock
        allowance = FakeHintAllowance()
        acknowledged = true
        enabled = true
    }

    private func makeService() -> LiveHintsService {
        let service = LiveHintsService(carriers: .init(
            captions: captions, documents: documents, model: model, lens: lens, ear: ear,
            voiceActivity: voice, phoneList: list, clock: clock, allowance: allowance))
        service.isEnabled = { [unowned self] in self.enabled }
        service.firstRunAcknowledged = { [unowned self] in self.acknowledged }
        service.setFirstRunAcknowledged = { [unowned self] in self.acknowledged = $0 }
        return service
    }

    private let question = "What's the warranty on the compressor?"

    // MARK: - Start and stop

    func testStartTurnsCaptionsOnAndStopTurnsThemOffWhenItStartedThem() {
        let service = makeService()
        XCTAssertEqual(service.start(), .started)
        XCTAssertTrue(service.isRunning)
        XCTAssertEqual(captions.starts, 1)
        XCTAssertTrue(voice.running)
        XCTAssertTrue(clock.isTicking)
        service.stop()
        XCTAssertFalse(service.isRunning)
        XCTAssertEqual(captions.stops, 1)
        XCTAssertFalse(voice.running)
        XCTAssertFalse(clock.isTicking)
    }

    func testCaptionsTheWearerHadOnStayOnAtStop() {
        captions.isActive = true
        let service = makeService()
        service.start()
        XCTAssertEqual(captions.starts, 0)
        service.stop()
        XCTAssertEqual(captions.stops, 0)
        XCTAssertTrue(captions.isActive)
    }

    func testEveryStartShowsTheCaptureNotice() {
        let service = makeService()
        service.start()
        XCTAssertEqual(service.notice, "Live hints listens to everyone near you. Tell people you're using it.")
        service.dismissNotice()
        service.stop()
        service.start()
        XCTAssertEqual(service.notice, LiveHintsCopy.captureNotice)
    }

    func testTheFirstStartWaitsForTheFirstRunSheetOnce() {
        acknowledged = false
        let service = makeService()
        XCTAssertEqual(service.start(.init(mode: .keyword, keywords: ["warranty"])), .needsFirstRun)
        XCTAssertTrue(service.firstRunPending)
        XCTAssertFalse(service.isRunning)
        XCTAssertEqual(captions.starts, 0, "nothing listens before the sheet is answered")
        XCTAssertEqual(service.acknowledgeFirstRun(), .started)
        XCTAssertTrue(acknowledged)
        XCTAssertFalse(service.firstRunPending)
        XCTAssertEqual(service.mode, .keyword, "the settings asked for go with the start")
        service.stop()
        XCTAssertEqual(service.start(), .started, "shown once")
    }

    func testClosingTheFirstRunSheetStartsNothingAndAsksAgain() {
        acknowledged = false
        let service = makeService()
        service.start()
        service.dismissFirstRun()
        XCTAssertFalse(service.firstRunPending)
        XCTAssertFalse(service.isRunning)
        XCTAssertEqual(service.start(), .needsFirstRun)
    }

    func testSwitchedOffNothingStarts() {
        enabled = false
        let service = makeService()
        XCTAssertEqual(service.start(), .disabled)
        XCTAssertEqual(captions.starts, 0)
    }

    func testRunningChangesAreReported() {
        let service = makeService()
        var seen: [Bool] = []
        service.onRunningChanged = { seen.append($0) }
        service.start()
        service.stop()
        XCTAssertEqual(seen, [true, false])
    }

    // MARK: - The answer path

    func testAQuestionShowsThePassageAtOnceThenTheModelsHint() async {
        let service = makeService()
        service.start()
        captions.say("So we were talking about the units on the roof.")
        captions.say(question, speaker: 1)
        await service.waitUntilIdle()

        XCTAssertEqual(documents.queries, [question])
        XCTAssertEqual(lens.presented.count, 2, "the passage card, then the model's hint in its place")
        XCTAssertEqual(lens.presented[0].source, .passage)
        XCTAssertEqual(lens.presented[0].line, "The compressor warranty runs 12 weeks from the install date.")
        XCTAssertEqual(lens.presented[1].id, lens.presented[0].id, "replaced, not a second card")
        XCTAssertEqual(lens.presented[1].source, .model)
        XCTAssertEqual(lens.presented[1].line, "12 weeks from install")
        XCTAssertEqual(lens.presented[1].passage?.documentId, "doc-1")
        XCTAssertEqual(model.calls.count, 1)
        XCTAssertTrue(model.calls[0].user.contains("So we were talking about the units on the roof."),
                      "the earlier final goes as context")
        XCTAssertEqual(service.modelCalls, 1)
        XCTAssertEqual(list.hints.map(\.line), ["12 weeks from install"])
        XCTAssertEqual(ear.chimes, 1, "a soft tick when a hint lands on the lens")
        XCTAssertTrue(ear.spoken.isEmpty, "with a lens, nothing is spoken")
    }

    func testTheModelsHintArrivingLateLeavesThePassageCard() async {
        model.replyDelay = 3.5
        let service = makeService()
        service.start()
        captions.say(question)
        await service.waitUntilIdle()
        XCTAssertEqual(lens.presented.map(\.source), [.passage])
        XCTAssertEqual(list.hints.first?.source, .passage)
    }

    func testTheModelsHintWithinTheWindowReplaces() async {
        model.replyDelay = 2.9
        let service = makeService()
        service.start()
        captions.say(question)
        await service.waitUntilIdle()
        XCTAssertEqual(lens.presented.map(\.source), [.passage, .model])
    }

    func testNoPassageTheModelsHintIsTheFirstCard() async {
        documents.passages = []
        let service = makeService()
        service.start()
        captions.say(question)
        await service.waitUntilIdle()
        XCTAssertEqual(lens.presented.map(\.source), [.model])
        XCTAssertNil(lens.presented[0].passage)
    }

    func testNoProviderReachableShowsThePassageCardOnly() async {
        model.isAvailable = false
        let service = makeService()
        service.start()
        captions.say(question)
        await service.waitUntilIdle()
        XCTAssertTrue(model.calls.isEmpty)
        XCTAssertEqual(lens.presented.map(\.source), [.passage])
    }

    func testAModelErrorLeavesThePassageCard() async {
        model.error = URLError(.notConnectedToInternet)
        let service = makeService()
        service.start()
        captions.say(question)
        await service.waitUntilIdle()
        XCTAssertEqual(lens.presented.map(\.source), [.passage])
    }

    func testANotWorthShowingReplyKeepsThePassageCard() async {
        model.reply = #"{"hint": ""}"#
        let service = makeService()
        service.start()
        captions.say(question)
        await service.waitUntilIdle()
        XCTAssertEqual(lens.presented.map(\.source), [.passage])
    }

    func testKeywordModeMakesNoModelCall() async {
        let service = makeService()
        service.start(.init(mode: .keyword, keywords: ["compressor"]))
        captions.say("The compressor on unit four is new.")
        await service.waitUntilIdle()
        XCTAssertTrue(model.calls.isEmpty)
        XCTAssertEqual(lens.presented.count, 1)
        XCTAssertEqual(lens.presented[0].keyword, "compressor")
        XCTAssertEqual(lens.presented[0].source, .passage)
        XCTAssertEqual(service.latency.count, 1)
    }

    func testOneHintInFlightAndANewerQuestionReplacesTheWaitingOne() async {
        model.replyDelay = 0.5
        let service = makeService()
        service.start()
        captions.say("What's the warranty on the compressor?", speaker: 1)
        // Two more questions while the first is answered, from other speakers so spacing allows them.
        captions.say("How long does the install take for one unit?", speaker: 2)
        captions.say("Which refrigerant does the new model use?", speaker: 3)
        await service.waitUntilIdle()
        let asked = model.calls.map { call -> String in
            let question = call.user.components(separatedBy: "</question>").first ?? ""
            return ["warranty", "install", "refrigerant"].first { question.contains($0) } ?? "?"
        }
        XCTAssertEqual(asked, ["warranty", "refrigerant"], "the waiting question was replaced by the newer one")
    }

    func testAQuestionReplacedWhileWaitingCanBeAskedAgain() async {
        model.replyDelay = 0.5
        let service = makeService()
        service.start()
        captions.say("What's the warranty on the compressor?", speaker: 1)
        captions.say("How long does the install take for one unit?", speaker: 2)
        captions.say("Which refrigerant does the new model use?", speaker: 3)
        await service.waitUntilIdle()
        clock.advance(by: 30, ticking: false)
        captions.say("How long does the install take for one unit?", speaker: 2)
        await service.waitUntilIdle()
        XCTAssertEqual(model.calls.count, 3, "the replaced question was never hinted, so it is not a repeat")
    }

    func testTheWearersOwnQuestionGetsNoHint() async {
        let service = makeService()
        service.start()
        service.markWearer(speaker: 0)
        captions.say(question, speaker: 0)
        await service.waitUntilIdle()
        XCTAssertTrue(lens.presented.isEmpty)
        captions.say(question, speaker: 1)
        await service.waitUntilIdle()
        XCTAssertFalse(lens.presented.isEmpty)
    }

    func testCaptionsBeforeTheStartAreNotAsked() async {
        captions.isActive = true
        captions.say(question)
        let service = makeService()
        service.start()
        captions.say("Thanks, that's all for now.")
        await service.waitUntilIdle()
        XCTAssertTrue(documents.queries.isEmpty)
    }

    // MARK: - Latency

    func testLatencyIsFromTheFinalToTheFirstCard() async {
        documents.passages = []
        model.replyDelay = 1.2
        let service = makeService()
        service.start()
        captions.say(question)
        await service.waitUntilIdle()
        XCTAssertEqual(service.latency.count, 1)
        XCTAssertEqual(service.latency.p50 ?? 0, 1.2, accuracy: 0.001)
        XCTAssertEqual(service.latency.p95 ?? 0, 1.2, accuracy: 0.001)
    }

    func testThePassageCardSetsTheLatencyNotTheModel() async {
        model.replyDelay = 2
        let service = makeService()
        service.start()
        captions.say(question)
        await service.waitUntilIdle()
        XCTAssertEqual(service.latency.p50 ?? -1, 0, accuracy: 0.001, "the passage card was at once")
    }

    // MARK: - The cache

    func testTheCacheIsKeyedByTheNormalisedQuestion() {
        XCTAssertEqual(LiveHintsService.cacheKey("What's the WARRANTY,  on the compressor?"),
                       LiveHintsService.cacheKey("what's the warranty on the compressor"))
    }

    func testARepeatedQuestionCostsNoSecondModelCall() async {
        let service = makeService()
        service.start()
        captions.say(question, speaker: 1)
        await service.waitUntilIdle()
        // A different speaker past the spacing, asking the same words: skipped as already hinted,
        // and the cache stands behind it for any repeat that reaches the answer path.
        clock.advance(by: 30)
        captions.say(question, speaker: 2)
        await service.waitUntilIdle()
        XCTAssertEqual(model.calls.count, 1, "never a second model call for the same question")
    }

    // MARK: - Delivery

    func testTheLensCardHidesAfter20Seconds() async {
        let service = makeService()
        service.start()
        captions.say(question)
        await service.waitUntilIdle()
        let id = lens.presented[0].id
        clock.advance(by: 19.9)
        XCTAssertTrue(lens.hidden.isEmpty)
        clock.advance(by: 0.1)
        XCTAssertEqual(lens.hidden, [id])
    }

    func testADismissedLensStaysDismissedAndTheHintIsOnThePhone() async {
        lens.accepts = false
        let service = makeService()
        service.start()
        captions.say(question)
        await service.waitUntilIdle()
        XCTAssertTrue(lens.presented.isEmpty)
        XCTAssertTrue(ear.spoken.isEmpty, "not moved to the ear")
        XCTAssertEqual(list.hints.count, 1)
    }

    func testWithNoLensTheHintIsSpokenWhenQuiet() async {
        lens.isAvailable = false
        let service = makeService()
        service.start()
        voice.onChange?(true)
        captions.say(question)
        await service.waitUntilIdle()
        XCTAssertTrue(ear.spoken.isEmpty, "someone is speaking")
        voice.onChange?(false)
        clock.advance(by: 0.3)
        XCTAssertTrue(ear.spoken.isEmpty)
        clock.advance(by: 0.1)
        XCTAssertEqual(ear.spoken.count, 1)
        XCTAssertLessThanOrEqual(ear.spoken[0].split(separator: " ").count, HintLimits.spokenHintMaxWords)
    }

    func testSomeoneTalkingOverAHintStopsIt() async {
        lens.isAvailable = false
        documents.passages = []
        let service = makeService()
        service.start()
        captions.say(question)
        await service.waitUntilIdle()
        XCTAssertEqual(ear.spoken, ["12 weeks from install"])
        voice.onChange?(true)
        XCTAssertEqual(ear.stops, 1)
    }

    func testNeverThroughThePhoneSpeaker() async {
        lens.isAvailable = false
        ear.isPhoneSpeaker = true
        let service = makeService()
        service.start()
        captions.say(question)
        await service.waitUntilIdle()
        clock.advance(by: 1)
        XCTAssertTrue(ear.spoken.isEmpty)
        XCTAssertEqual(ear.chimes, 0)
        XCTAssertFalse(list.hints.isEmpty, "the screen still has it")
    }

    func testTheRouteFallingBackToTheSpeakerStopsAHint() async {
        lens.isAvailable = false
        documents.passages = []
        let service = makeService()
        service.start()
        captions.say(question)
        await service.waitUntilIdle()
        XCTAssertEqual(ear.spoken.count, 1)
        ear.onRouteChanged?(true)
        XCTAssertEqual(ear.stops, 1)
    }

    func testThePhoneListKeepsTheLastTenAndGoesAtStop() async {
        let service = makeService()
        service.start(.init(mode: .keyword, keywords: ["compressor", "warranty"]))
        for index in 0..<12 {
            clock.advance(by: 61, ticking: false)
            captions.say(index.isMultiple(of: 2) ? "the compressor again" : "the warranty again")
        }
        XCTAssertEqual(list.hints.count, HintLimits.phoneListMax)
        XCTAssertEqual(list.hints.first?.id, 12, "newest first")
        service.stop()
        XCTAssertTrue(list.hints.isEmpty)
    }

    // MARK: - Limits

    func testTheSessionWarnsAt1h55AndStopsAt2h() {
        lens.isAvailable = false
        let service = makeService()
        service.start()
        clock.advance(by: HintLimits.sessionWarningAt - 1)
        XCTAssertTrue(ear.spoken.isEmpty)
        clock.advance(by: 1)
        XCTAssertEqual(ear.spoken, [LiveHintsCopy.limitWarning])
        XCTAssertEqual(service.notice, LiveHintsCopy.limitWarning)
        clock.advance(by: 4 * 60)
        XCTAssertTrue(service.isRunning)
        clock.advance(by: 60)
        XCTAssertFalse(service.isRunning)
        XCTAssertEqual(service.lastStopReason, .sessionLimit)
        XCTAssertEqual(ear.spoken.last, LiveHintsCopy.limitReached)
    }

    func testTheWarningIsNeverSpokenOnThePhoneSpeaker() {
        ear.isPhoneSpeaker = true
        let service = makeService()
        service.start()
        clock.advance(by: HintLimits.sessionWarningAt)
        XCTAssertTrue(ear.spoken.isEmpty)
        XCTAssertEqual(service.notice, LiveHintsCopy.limitWarning)
    }

    func testTheAllowanceRunningOutStopsTheSession() {
        allowance.left = 30
        let service = makeService()
        service.start()
        clock.advance(by: 20)
        XCTAssertTrue(service.isRunning)
        clock.advance(by: 10)
        XCTAssertFalse(service.isRunning)
        XCTAssertEqual(service.lastStopReason, .allowance)
        XCTAssertEqual(service.notice, LiveHintsCopy.allowanceSpent)
    }

    func testNoTimeLeftNothingStarts() {
        allowance.left = 0
        let service = makeService()
        XCTAssertEqual(service.start(), .allowanceSpent)
        XCTAssertEqual(captions.starts, 0)
    }

    func testCaptionsAloneNeverDrawOnTheAllowance() {
        allowance.left = 60
        let service = makeService()
        // The wearer's own captions, for ten minutes, with no hints session: nothing is charged.
        captions.start()
        clock.advance(by: 600)
        XCTAssertEqual(allowance.charged, 0)
        XCTAssertFalse(service.isRunning)
        // A session over captions already on charges its own time only, and leaves them on.
        service.start()
        clock.advance(by: 20)
        service.stop()
        XCTAssertEqual(allowance.charged, 20, accuracy: 0.001)
        clock.advance(by: 600)
        XCTAssertEqual(allowance.charged, 20, accuracy: 0.001)
        XCTAssertTrue(captions.isActive)
    }

    // MARK: - Vocabulary

    func testTheSessionsWordsGoToTheRecogniserAndAreRestoredAtStop() {
        captions.contextualStrings = ["earlier"]
        documents.titles = ["Service terms", "Install guide"]
        let service = makeService()
        service.start(.init(mode: .keyword, keywords: ["Tecumseh", "warranty"]))
        XCTAssertEqual(captions.contextualStrings, ["Tecumseh", "warranty", "Service terms", "Install guide"])
        service.stop()
        XCTAssertEqual(captions.contextualStrings, ["earlier"])
    }

    // MARK: - Lecture mode

    func testLectureModeSendsAKeyPointToTheLensAfterAbout100Words() async {
        model.reply = "Heat pumps move heat rather than make it."
        let service = makeService()
        service.start(.init(mode: .lecture))
        let sentence = "A heat pump moves heat from outside to inside using a refrigerant cycle that runs in reverse."
        for _ in 0..<6 { captions.say(sentence) }   // 6 × 18 words
        await service.lectureAnalysisTask?.value
        XCTAssertEqual(lens.presented.last?.source, .keyPoint)
        XCTAssertEqual(lens.presented.last?.line, "Heat pumps move heat rather than make it.")
        XCTAssertEqual(model.calls.last?.system, LectureKeyPointSink.system)
        XCTAssertTrue(ear.spoken.isEmpty)
    }

    func testALectureQuestionToTheRoomIsStillHinted() async {
        let service = makeService()
        service.start(.init(mode: .lecture))
        captions.say("So who can tell me what the warranty on the compressor is?")
        await service.waitUntilIdle()
        XCTAssertFalse(lens.presented.isEmpty)
    }
}
