import XCTest
@testable import OpenGlasses

/// The live-mode "new topic" backstop: the same Tier-0 test as Direct, the live gates, the pairing
/// of a complete transcript with its turn's end, and the record keeping late words with their turn.
final class LiveNewTopicBackstopTests: XCTestCase {

    // MARK: - The phrase check is Tier 0's

    /// Every Tier-0 reset phrase, said bare.
    private let tier0Phrases = [
        "new topic", "new conversation", "start over", "start fresh", "start again",
        "clear the conversation", "clear conversation", "clear our conversation",
        "forget this conversation", "forget that", "reset the conversation", "fresh start",
    ]

    func testEveryTier0PhraseSaidBareIsANewTopicCommand() {
        for phrase in tier0Phrases {
            XCTAssertTrue(ConversationClassifier.isBareNewTopicCommand(phrase), "'\(phrase)'")
        }
    }

    func testFillerAndPunctuationTier0AllowsStillCount() {
        for utterance in ["Hey, new topic.", "okay new conversation please", "Can we start over?",
                          "let's start a new topic", "OK, start fresh!", "  just start again  ",
                          "New topic, please.", "please clear the conversation now"] {
            XCTAssertTrue(ConversationClassifier.isBareNewTopicCommand(utterance), "'\(utterance)'")
        }
    }

    func testSentencesThatOnlyContainAResetPhraseDoNotCount() {
        for utterance in ["write about a new topic for my essay",
                          "can you start over the explanation",
                          "let's discuss a new topic tomorrow",
                          "suggest a new topic for my essay",
                          "help me start over with this recipe from step three",
                          "forget that song, play another one",
                          "start a new field service session as signed job 1005", ""] {
            XCTAssertFalse(ConversationClassifier.isBareNewTopicCommand(utterance), "'\(utterance)'")
        }
    }

    /// The tool-only phrasings are fragments a model has to have chosen; the backstop resets
    /// without a model's choice and gets no more licence than Tier 0.
    func testToolOnlyResetPhrasingsAreNotTier0Commands() {
        for utterance in ["forget everything", "wipe the conversation", "reset our conversation"] {
            XCTAssertFalse(ConversationClassifier.isBareNewTopicCommand(utterance), "'\(utterance)'")
        }
    }

    /// One source of truth: whatever Tier 0 routes to `new_topic`, the backstop reads as a reset,
    /// and nothing else.
    func testTheCheckAgreesWithTier0Routing() {
        let classifier = ConversationClassifier()
        let corpus = tier0Phrases + ["Hey, new topic.", "can we start fresh", "what time is it",
                                     "write about a new topic for my essay", "start over the timer",
                                     "let's discuss a new topic tomorrow", "okay new conversation"]
        for utterance in corpus {
            let routed = classifier.classify(utterance).directToolCall?.toolName == "new_topic"
            XCTAssertEqual(ConversationClassifier.isBareNewTopicCommand(utterance), routed, "'\(utterance)'")
        }
    }

    // MARK: - The live gates

    private func turn(_ text: String = "new topic", replied: Bool = true,
                      consumed: Bool = false) -> LiveWearerTurn {
        LiveWearerTurn(text: text, modelReplied: replied, resetGeneration: 3, consumedByJob: consumed)
    }

    func testABareNewTopicTheModelAnsweredWithoutItsToolIsReset() {
        XCTAssertTrue(LiveNewTopicBackstop.applies(turn(), jobActive: false, interpreting: false))
    }

    func testTheBackstopStaysOutOfTheWay() {
        XCTAssertFalse(LiveNewTopicBackstop.applies(turn(replied: false), jobActive: false, interpreting: false),
                       "a silent model decided it was not being spoken to")
        XCTAssertFalse(LiveNewTopicBackstop.applies(turn(), jobActive: true, interpreting: false),
                       "during a job the model's tool alone decides")
        XCTAssertFalse(LiveNewTopicBackstop.applies(turn(consumed: true), jobActive: false, interpreting: false),
                       "words the job flow took as an answer were an answer")
        XCTAssertFalse(LiveNewTopicBackstop.applies(turn(), jobActive: false, interpreting: true),
                       "an interpreter's words may be the other person's")
        XCTAssertFalse(LiveNewTopicBackstop.applies(turn("let's discuss a new topic tomorrow"),
                                                    jobActive: false, interpreting: false))
    }

    // MARK: - Complete transcripts (JSON providers)

    func testATranscriptBeforeItsTurnEndsIsReportedAtTheEnd() {
        var pairing = CompleteTranscriptPairing()
        XCTAssertNil(pairing.transcriptArrived("new topic", resetGeneration: 2, consumedByJob: false))
        XCTAssertEqual(pairing.turnEnded(modelReplied: true),
                       LiveWearerTurn(text: "new topic", modelReplied: true, resetGeneration: 2,
                                      consumedByJob: false))
        XCTAssertNil(pairing.turnEnded(modelReplied: true), "reported once")
    }

    func testATranscriptAfterItsTurnEndedIsReportedWithThatTurnsReply() {
        var pairing = CompleteTranscriptPairing()
        XCTAssertNil(pairing.turnEnded(modelReplied: false))
        XCTAssertEqual(pairing.transcriptArrived("start over", resetGeneration: nil, consumedByJob: true),
                       LiveWearerTurn(text: "start over", modelReplied: false, resetGeneration: nil,
                                      consumedByJob: true))
    }

    func testANewUtteranceLetsGoOfAnythingUnpaired() {
        var pairing = CompleteTranscriptPairing()
        XCTAssertNil(pairing.turnEnded(modelReplied: true))
        pairing.speechStarted()
        XCTAssertNil(pairing.transcriptArrived("new topic", resetGeneration: 1, consumedByJob: false),
                     "a transcript after the next utterance began cannot be told from the next turn's")
        pairing.speechStarted()
        XCTAssertNil(pairing.turnEnded(modelReplied: true))
    }
}

// MARK: - The handover record

@MainActor
final class LiveRecorderLateWordsTests: XCTestCase {

    func testLateWordsReviseTheCompletedTurnsWearerRecord() {
        let recorder = LiveConversationRecorder()
        recorder.setWearerTurn("I have to go")
        recorder.setAssistantTurn("Okay, see you")
        recorder.completeTurn()

        recorder.reviseCompletedWearerTurn("I have to go bye")

        XCTAssertEqual(recorder.turns.map(\.text), ["I have to go bye", "Okay, see you"])
        XCTAssertEqual(recorder.turns.map(\.speaker), [.wearer, .assistant])
    }

    func testWordsThatAllArrivedLateAreFiledAheadOfTheAnswer() {
        let recorder = LiveConversationRecorder()
        recorder.setAssistantTurn("Hello there")
        recorder.completeTurn()

        recorder.reviseCompletedWearerTurn("hi")

        XCTAssertEqual(recorder.turns.map(\.speaker), [.wearer, .assistant])
        XCTAssertEqual(recorder.turns.first?.text, "hi")
    }

    func testARevisionAfterTheNextTurnBeganChangesNothing() {
        let recorder = LiveConversationRecorder()
        recorder.setWearerTurn("first")
        recorder.setAssistantTurn("answer")
        recorder.completeTurn()
        recorder.setWearerTurn("second")
        recorder.setAssistantTurn("another")

        recorder.reviseCompletedWearerTurn("first and more")

        XCTAssertEqual(recorder.turns.map(\.text), ["first", "answer", "second"])
    }
}

// MARK: - One reset per turn

@MainActor
final class LiveNewTopicResetDedupeTests: XCTestCase {

    private final class Counts {
        var announced = 0
        var threads = 0
        var resets = 0
    }

    private final class LiveAdapter: ConversationContextResetting {
        let backend: ConversationBackendID = .geminiLive
        let counts: Counts
        var parked: CheckedContinuation<Void, Never>?
        var parks = false
        init(_ counts: Counts) { self.counts = counts }
        func resetConversationContext() async -> ConversationResetOutcome {
            counts.resets += 1
            if parks { await withCheckedContinuation { parked = $0 } }
            return .completed(.geminiLive)
        }
    }

    private func makeCoordinator(_ counts: Counts, adapter: LiveAdapter) -> ConversationResetCoordinator {
        let coordinator = ConversationResetCoordinator()
        coordinator.configure(.init(
            plan: { [.geminiLive] },
            adapter: { _ in adapter },
            startSavedThread: { counts.threads += 1 },
            announce: { _ in counts.announced += 1 }))
        return coordinator
    }

    func testTheRuleIsThatAMovedGenerationMeansTheTurnWasAlreadyReset() {
        XCTAssertFalse(ConversationResetCoordinator.backstopIsAbsorbed(turnGeneration: 5, current: 5))
        XCTAssertTrue(ConversationResetCoordinator.backstopIsAbsorbed(turnGeneration: 4, current: 5))
    }

    func testTheBackstopResetsWhenNothingElseDid() async {
        let counts = Counts()
        let coordinator = makeCoordinator(counts, adapter: LiveAdapter(counts))
        let turnGeneration = coordinator.currentGeneration

        let report = await coordinator.requestLiveBackstopReset(turnGeneration: turnGeneration)

        XCTAssertEqual(report?.source, .voiceCommand)
        XCTAssertEqual(counts.resets, 1)
        XCTAssertEqual(counts.announced, 1)
        XCTAssertEqual(counts.threads, 1)
    }

    /// The model called `new_topic` mid-turn and its reset finished before the turn's words were
    /// final. The backstop must not retire the brand-new conversation or confirm a second time.
    func testTheBackstopAfterTheModelsCompletedResetIsAbsorbed() async {
        let counts = Counts()
        let coordinator = makeCoordinator(counts, adapter: LiveAdapter(counts))
        let turnGeneration = coordinator.currentGeneration
        await coordinator.requestReset(source: .modelToolCall)
        let generationAfterModel = coordinator.currentGeneration

        let report = await coordinator.requestLiveBackstopReset(turnGeneration: turnGeneration)

        XCTAssertNil(report)
        XCTAssertEqual(coordinator.absorbedBackstopRequests, 1)
        XCTAssertEqual(coordinator.currentGeneration, generationAfterModel, "no second generation")
        XCTAssertEqual(counts.resets, 1)
        XCTAssertEqual(counts.announced, 1, "the confirmation is spoken once")
        XCTAssertEqual(counts.threads, 1)
    }

    func testTheBackstopWhileTheModelsResetRunsJoinsIt() async {
        let counts = Counts()
        let adapter = LiveAdapter(counts)
        adapter.parks = true
        let coordinator = makeCoordinator(counts, adapter: adapter)
        let turnGeneration = coordinator.currentGeneration

        let modelRun = Task { await coordinator.requestReset(source: .modelToolCall) }
        while adapter.parked == nil { await Task.yield() }
        let backstop = Task { await coordinator.requestLiveBackstopReset(turnGeneration: turnGeneration) }
        while coordinator.coalescedRequests == 0 { await Task.yield() }
        adapter.parked?.resume()

        let modelReport = await modelRun.value
        let backstopReport = await backstop.value
        XCTAssertEqual(backstopReport, modelReport, "the backstop joined the run already going")
        XCTAssertEqual(counts.resets, 1)
        XCTAssertEqual(counts.announced, 1)
        XCTAssertEqual(counts.threads, 1)
    }
}
