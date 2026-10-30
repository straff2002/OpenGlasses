import XCTest
@testable import OpenGlasses

/// Saying goodbye to a live session, and the words the session is given about who it is talking to.
final class LiveVoiceEndTests: XCTestCase {

    private let parser = VoiceCommandParser.default.named("Max")
    private let start = Date(timeIntervalSince1970: 1_000)

    // MARK: - Phrases

    func testTheNewSignOffsAreGoodbyes() {
        for phrase in ["I've got to go", "ive got to go", "I got to go", "gotta go", "I have to go",
                       "talk to you later", "talk later", "OK, I've got to go now, thanks"] {
            XCTAssertTrue(VoiceCommandParser.default.isGoodbye(phrase), phrase)
        }
    }

    func testTheDemotionRulesStillHold() {
        for phrase in ["I have to go to the store", "how do you say bye in French",
                       "I've got to go to the dentist tomorrow", "how do I say talk to you later in Spanish"] {
            XCTAssertFalse(VoiceCommandParser.default.isGoodbye(phrase), phrase)
        }
    }

    func testThanksFollowsTheAssistantsNameNotAFixedOne() {
        XCTAssertTrue(parser.isGoodbye("thanks Max"))
        XCTAssertTrue(parser.isGoodbye("thank you max"))
        XCTAssertFalse(parser.isGoodbye("thanks Claude"), "the old fixed name is gone")
        XCTAssertFalse(VoiceCommandParser.default.isGoodbye("thanks claude"))
    }

    // MARK: - The backstop

    private func backstop(_ transcript: String, replied: Bool = true, job: Bool = false) -> Bool {
        LiveVoiceEndPolicy.backstopApplies(transcript: transcript, modelReplied: replied,
                                           jobActive: job, parser: parser)
    }

    func testAGoodbyeTheModelAnsweredEndsTheSession() {
        XCTAssertTrue(backstop("bye"))
        XCTAssertTrue(backstop("I've got to go"))
    }

    func testAQuestionAboutGoodbyeDoesNot() {
        XCTAssertFalse(backstop("how do you say bye in French"))
    }

    func testASilentModelMeansItWasNotSpokenTo() {
        XCTAssertFalse(backstop("bye", replied: false), "a goodbye on the TV ends nothing")
    }

    func testDuringAJobOnlyTheToolDecides() {
        XCTAssertFalse(backstop("bye", job: true))
    }

    func testLongTurnsAreLeftToTheModel() {
        XCTAssertFalse(backstop("that's all I wanted to ask about the weather, goodbye"))
    }

    // MARK: - Finishing the goodbye

    func testAToolRequestWaitsForTheTurnAndThePlayback() {
        var tracker = LiveVoiceEndTracker()
        tracker.request(now: start)
        XCTAssertTrue(tracker.isPending)
        XCTAssertFalse(tracker.shouldStop(now: start.addingTimeInterval(2), toolRunning: false, playbackPending: false),
                       "the turn has not ended")
        tracker.noteTurnComplete()
        XCTAssertFalse(tracker.shouldStop(now: start.addingTimeInterval(3), toolRunning: false, playbackPending: true),
                       "the goodbye is still playing")
        XCTAssertTrue(tracker.shouldStop(now: start.addingTimeInterval(4), toolRunning: false, playbackPending: false))
    }

    func testATurnThatEndsAtOnceDoesNotBeatTheReplyToTheTool() {
        var tracker = LiveVoiceEndTracker()
        tracker.request(now: start)
        tracker.noteTurnComplete()
        XCTAssertFalse(tracker.shouldStop(now: start.addingTimeInterval(0.2), toolRunning: false, playbackPending: false),
                       "the reply to the tool has not had time to start")
    }

    func testThePlaybackWaitIsBounded() {
        var tracker = LiveVoiceEndTracker()
        tracker.request(now: start)
        tracker.noteTurnComplete()
        XCTAssertFalse(tracker.shouldStop(now: start.addingTimeInterval(7.9), toolRunning: false, playbackPending: true))
        XCTAssertTrue(tracker.shouldStop(now: start.addingTimeInterval(8), toolRunning: false, playbackPending: true))
    }

    func testAModelThatNeverFinishesTheTurnIsBoundedToo() {
        var tracker = LiveVoiceEndTracker()
        tracker.request(now: start)
        XCTAssertTrue(tracker.shouldStop(now: start.addingTimeInterval(8), toolRunning: false, playbackPending: false))
    }

    func testARunningToolHoldsTheEndAndRestartsTheWait() {
        var tracker = LiveVoiceEndTracker()
        tracker.request(now: start, turnAlreadyEnded: true)
        XCTAssertFalse(tracker.shouldStop(now: start.addingTimeInterval(30), toolRunning: true, playbackPending: false))
        XCTAssertFalse(tracker.shouldStop(now: start.addingTimeInterval(31), toolRunning: false, playbackPending: false),
                       "the model is about to speak the tool's result")
        XCTAssertTrue(tracker.shouldStop(now: start.addingTimeInterval(38), toolRunning: false, playbackPending: false))
    }

    func testTheBackstopAfterTheToolChangesNothing() {
        var tracker = LiveVoiceEndTracker()
        tracker.request(now: start)
        let once = tracker
        tracker.request(now: start.addingTimeInterval(5), turnAlreadyEnded: true)
        XCTAssertEqual(tracker, once)
    }

    func testNothingRequestedNeverStops() {
        var tracker = LiveVoiceEndTracker()
        tracker.noteTurnComplete()
        XCTAssertFalse(tracker.isPending)
        XCTAssertFalse(tracker.shouldStop(now: start.addingTimeInterval(100), toolRunning: false, playbackPending: false))
    }

    // MARK: - The declaration

    func testTheDeclarationSurvivesTheOpenAIMapping() throws {
        let mapped = ToolDeclarations.openAIRealtimeTools(declarations: [LiveVoiceEndPolicy.declaration])
        let tool = try XCTUnwrap(mapped.first)
        XCTAssertEqual(tool["name"] as? String, LiveVoiceEndPolicy.toolName)
        XCTAssertEqual(tool["type"] as? String, "function")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(tool))
    }

    func testTheDeclarationHasAPropertyBecauseGeminiRefusesAnEmptyObject() throws {
        let parameters = try XCTUnwrap(LiveVoiceEndPolicy.declaration["parameters"] as? [String: Any])
        let properties = try XCTUnwrap(parameters["properties"] as? [String: Any])
        XCTAssertFalse(properties.isEmpty)
        XCTAssertNil(parameters["required"], "nothing the model must supply")
    }

    func testEndReasonLeavesNothingOnTheCard() {
        XCTAssertNil(LiveSessionEndReason.saidGoodbye.notice)
        XCTAssertTrue(LiveActivationSource.voice.isExplicit)
    }

    // MARK: - Who is being spoken to

    func testTheRoomLineIsThereByDefault() {
        let block = LiveAddressingInstruction.block(modeID: "standard", canEndSession: true)
        XCTAssertTrue(block.contains("Stay silent for a TV"))
        XCTAssertTrue(block.contains(LiveVoiceEndPolicy.toolName))
    }

    func testTheTranslatorHearsEveryone() {
        let block = LiveAddressingInstruction.block(modeID: "translator", canEndSession: true)
        XCTAssertFalse(block.contains("Stay silent"))
        XCTAssertTrue(block.contains(LiveVoiceEndPolicy.toolName))
    }

    func testBlindAssistanceAnswersWhenInDoubt() {
        let block = LiveAddressingInstruction.block(modeID: BlindAssistanceContract.presetID, canEndSession: false)
        XCTAssertTrue(block.contains("If it could be a question for you, answer it."))
        XCTAssertFalse(LiveAddressingInstruction.block(modeID: "museum", canEndSession: false)
            .contains("If it could be a question"))
    }

    func testNoToolIsNotOffered() {
        XCTAssertFalse(LiveAddressingInstruction.block(modeID: "standard", canEndSession: false)
            .contains(LiveVoiceEndPolicy.toolName))
        XCTAssertEqual(LiveAddressingInstruction.block(modeID: "translator", canEndSession: false), "")
    }
}

/// The router answers the session's own tool without treating it as a tool call.
@MainActor
final class LiveVoiceEndRouterTests: XCTestCase {

    private func call(_ name: String) throws -> GeminiFunctionCall {
        let batch = try XCTUnwrap(GeminiToolCall(json: ["toolCall": ["functionCalls": [
            ["id": "call-1", "name": name, "args": [:] as [String: Any]]]]]))
        return try XCTUnwrap(batch.functionCalls.first)
    }

    func testTheCallIsInterceptedAndAnswered() throws {
        let router = ToolCallRouter(bridge: OpenClawBridge())
        var ended = 0
        router.onEndLiveSession = { ended += 1 }
        var response: [String: Any]?
        var paused = false
        router.onToolExecutionStarted = { paused = true }

        router.handleToolCall(try call(LiveVoiceEndPolicy.toolName)) { response = $0 }

        XCTAssertEqual(ended, 1)
        XCTAssertNotNil(response, "answered at once")
        XCTAssertFalse(paused, "no tool ran, so the camera is not paused")
        XCTAssertFalse(router.hasInFlightCalls)
    }

    func testRepeatedCallsAreNeverSuspendedByTheBreaker() throws {
        let router = ToolCallRouter(bridge: OpenClawBridge())
        var ended = 0
        router.onEndLiveSession = { ended += 1 }
        for _ in 0..<20 {
            router.handleToolCall(try call(LiveVoiceEndPolicy.toolName)) { _ in }
        }
        XCTAssertEqual(ended, 20)
        XCTAssertTrue(router.suspendedToolNames.isEmpty)
    }
}
