import AVFoundation
import XCTest
@testable import OpenGlasses

/// A speech side for streamed replies that records instead of playing. Synthesis is the system
/// voice's "nothing to prepare"; playback completes after one hop of the main actor unless the
/// reply has been cancelled under it, which is what a barge-in looks like from the queue.
@MainActor
final class RecordingStreamedSpeech: StreamedSpeechBackend, StreamedReplySpeaking {
    var chain: [TTSEngine] = [.system]
    private(set) var played: [String] = []
    private(set) var wholeReplies: [String] = []
    private(set) var records: [StreamedReplyRecord] = []
    private(set) var active: StreamedReplyQueue?
    /// Called as each sentence starts playing, with its 1-based number.
    var onPlay: ((Int, String) -> Void)?

    func beginStreamedReply(isCurrent: @escaping @MainActor () -> Bool) -> StreamedReplyQueue {
        let queue = StreamedReplyQueue(backend: self, source: .reply, isCurrent: isCurrent)
        active = queue
        return queue
    }

    func speakWholeReply(_ text: String) async { wholeReplies.append(text) }

    func streamedSpeechChain() -> [TTSEngine] { chain }

    func synthesizeStreamedSentence(_ text: String, engine: TTSEngine) async throws -> StreamedSpeechAudio {
        await Task.yield()
        return .live
    }

    func beginStreamedPlayback() async {}

    func playStreamedSentence(_ text: String, audio: StreamedSpeechAudio, engine: TTSEngine,
                              source: SpeechSource) async -> SpeechDeliveryOutcome {
        played.append(text)
        onPlay?(played.count, text)
        await Task.yield()
        if let active, active.isCancelled { return .interrupted(by: active.interruption ?? .stop) }
        return .completed
    }

    func streamedReplyDidEnd(_ queue: StreamedReplyQueue, record: StreamedReplyRecord,
                             playbackBegan: Bool) async {
        records.append(record)
    }
}

/// Plan HZ P1 — a Direct turn's streamed reply end to end: tokens from the real provider streaming
/// code in, sentences out in order, and the spoken words exactly the reply's words; barge-in,
/// reset and the switched-off path.
@MainActor
final class StreamedReplyTurnTests: XCTestCase {

    override func setUp() {
        super.setUp()
        CloudConsentFixture.approveShared([
            "https://api.anthropic.com"
        ])
        SSEQueueProtocol.queue = []
    }

    override func tearDown() {
        CloudConsentFixture.restoreShared()
        super.tearDown()
    }

    private func normalised(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: - Fixtures

    /// A tool turn that opens with a preamble, then calls a tool.
    private let preambleToolTurn = """
    data: {"type":"message_start","message":{}}

    data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Let me check the "}}

    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"forecast for you."}}

    data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"tu_1","name":"get_weather"}}

    data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\"city\\":\\"Auckland\\"}"}}

    data: {"type":"message_delta","delta":{"stop_reason":"tool_use"}}

    data: {"type":"message_stop"}

    """

    /// The final reply, in chunks that fall inside words and numbers.
    private let finalTurn = """
    data: {"type":"message_start","message":{}}

    data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Sure. The forecast for Auckland is sunny"}}

    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" today with a high of 2"}}

    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"2 degrees. Expect light winds after 3"}}

    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" pm. Take a hat!"}}

    data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}

    data: {"type":"message_stop"}

    """

    // MARK: - Tokens in, sentences out

    func testTokensInSentencesOutInOrderAndTheSpokenTextIsTheReply() async throws {
        SSEQueueProtocol.queue = [(200, preambleToolTurn), (200, finalTurn)]
        let llm = LLMService()
        llm.streamingSession = SSEQueueProtocol.session()
        let speech = RecordingStreamedSpeech()
        let stream = DirectReplySpeechStream(speaker: speech)
        var transcriptLines: [String] = []
        stream.onPreamble = { transcriptLines.append($0) }

        let config = ModelConfig(id: "t", name: "t", provider: "anthropic",
                                 apiKey: "sk-test", model: "claude-test", baseURL: "")
        let response = try await llm.sendAnthropic(
            "what's the weather", systemPrompt: "sys", config: config,
            includeTools: true, imageData: nil,
            onToken: { stream.ingest($0) },
            onStreamReset: { stream.streamDidReset() })

        XCTAssertEqual(stream.queue?.sentenceCount, 3,
                       "the preamble and two sentences reached speech before generation ended")

        await stream.finish(reply: response)

        XCTAssertEqual(speech.played, [
            "Let me check the forecast for you.",
            "Sure. The forecast for Auckland is sunny today with a high of 22 degrees.",
            "Expect light winds after 3 pm.",
            "Take a hat!"
        ])
        XCTAssertEqual(transcriptLines, ["Let me check the forecast for you."],
                       "the preamble that was heard is shown as its own line")
        XCTAssertEqual(normalised(speech.played.dropFirst().joined(separator: " ")), normalised(response),
                       "the reply is spoken word for word — only the timing changed")
        XCTAssertEqual(speech.wholeReplies, [], "nothing was said twice")
        XCTAssertEqual(speech.records.last?.heardCount, 4)
        XCTAssertNil(speech.records.last?.interruption)
    }

    // MARK: - Barge-in and reset

    func testABargeInAfterTheFirstSentenceDropsTheRestAndRecordsOneHeard() async {
        let speech = RecordingStreamedSpeech()
        let stream = DirectReplySpeechStream(speaker: speech)
        // What `TextToSpeechService.stopSpeaking(interruption: .bargeIn)` does to the reply.
        speech.onPlay = { number, _ in if number == 2 { speech.active?.cancel(.bargeIn) } }

        for chunk in ["The forecast for Auckland is sunny today. ", "Expect light winds after three. ",
                      "Take a hat with you. ", "It will rain tomorrow."] {
            stream.ingest(chunk)
        }
        await stream.finish(reply: "The forecast for Auckland is sunny today. Expect light winds after three. Take a hat with you. It will rain tomorrow.")

        XCTAssertEqual(speech.played, ["The forecast for Auckland is sunny today.",
                                       "Expect light winds after three."],
                       "the second was cut off as it started; nothing after it played")
        let record = speech.records.last
        XCTAssertEqual(record?.heardCount, 1)
        XCTAssertEqual(record?.interruption, .bargeIn)
        XCTAssertEqual(record?.unheardSentences.first, "Expect light winds after three.",
                       "a replay starts at the first unheard sentence")
        XCTAssertTrue(stream.wasStopped)

        // More of the stream arriving after the barge-in says nothing.
        stream.ingest(" Anything else? Just ask me.")
        XCTAssertEqual(speech.played.count, 2)
    }

    func testAResetMidReplyPlaysNothingFurther() async {
        let speech = RecordingStreamedSpeech()
        var current = true
        let stream = DirectReplySpeechStream(speaker: speech, isCurrent: { current })
        speech.onPlay = { number, _ in if number == 1 { current = false } }   // a "new conversation"

        stream.ingest("The forecast for Auckland is sunny today. Expect light winds after three. Take a hat.")
        await stream.queue?.finish()

        XCTAssertEqual(speech.played, ["The forecast for Auckland is sunny today."])
        XCTAssertEqual(speech.records.last?.interruption, .stop)
        stream.ingest(" More words for a conversation that is gone.")
        await stream.finish(reply: "irrelevant")
        XCTAssertEqual(speech.played.count, 1)
        XCTAssertEqual(speech.wholeReplies, [])
    }

    func testAnotherUtteranceTakingTheFloorLeavesTheRestOwedAndSaidAtTheEnd() async {
        let speech = RecordingStreamedSpeech()
        let stream = DirectReplySpeechStream(speaker: speech)
        // A notice superseding the reply as its second sentence starts.
        speech.onPlay = { number, _ in if number == 2 { speech.active?.cancel(.newUtterance) } }

        stream.ingest("The forecast for Auckland is sunny today. Expect light winds after three. Take a hat.")
        await stream.finish(reply: "The forecast for Auckland is sunny today. Expect light winds after three. Take a hat.")

        XCTAssertEqual(speech.played.first, "The forecast for Auckland is sunny today.")
        XCTAssertEqual(speech.wholeReplies, ["Expect light winds after three. Take a hat."],
                       "what was not heard is said, whole, once the reply is final")
    }

    // MARK: - The switched-off path

    func testTheSwitchIsOffByDefault() {
        let key = "directSentenceStreamingEnabled"
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertFalse(Config.directSentenceStreamingEnabled)
    }

    func testNothingStreamedIsTodaysPathByteForByte() async {
        let speech = RecordingStreamedSpeech()
        let stream = DirectReplySpeechStream(speaker: speech)
        let reply = "  It is sunny.\n\nTake a hat!  "
        await stream.finish(reply: reply)
        XCTAssertFalse(stream.didStream)
        XCTAssertNil(stream.queue)
        XCTAssertEqual(speech.wholeReplies, [reply], "the exact text `speak(response)` would have had")
        XCTAssertEqual(speech.played, [])
    }

    func testAReplyHeldFromTheStartIsSpokenWholeAsToday() async {
        let speech = RecordingStreamedSpeech()
        let stream = DirectReplySpeechStream(speaker: speech)
        stream.ingest("Got it, I will remember that your van is the white one. ")
        stream.ingest("[REMEMBER: van = white] Anything else I can help with today?")
        let processed = "Got it, I will remember that your van is the white one.  Anything else I can help with today?"
        await stream.finish(reply: processed)
        XCTAssertFalse(stream.didStream)
        XCTAssertEqual(speech.wholeReplies, [processed])
        XCTAssertEqual(speech.played, [])
    }

    // MARK: - The speech service

    /// A synthesizer that reports start and finish on the next main-queue turn — except the
    /// utterance it is told to hang on, which plays until something stops it.
    private final class ScriptedSynthesizer: SpeechSynthesizing {
        weak var delegate: (any AVSpeechSynthesizerDelegate)?
        private let source = AVSpeechSynthesizer()
        var spoken: [String] = []
        var hangsOnUtterance = Int.max

        func speak(_ utterance: AVSpeechUtterance) {
            spoken.append(utterance.speechString)
            guard spoken.count < hangsOnUtterance else { return }
            let source = self.source
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.speechSynthesizer?(source, didStart: utterance)
                self?.delegate?.speechSynthesizer?(source, didFinish: utterance)
            }
        }

        func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool { true }
    }

    /// OpenClaw's `speakStreaming` keeps its API and moves onto the new splitter and queue: a
    /// sentence is spoken once it is complete, a partial one waits for the rest of its words, and
    /// "2.5" is not a sentence end.
    func testTheGatewayStreamSpeaksWholeSentencesInOrder() async {
        let savedPreference = UserDefaults.standard.string(forKey: "ttsEnginePreference")
        defer { UserDefaults.standard.set(savedPreference, forKey: "ttsEnginePreference") }
        Config.setTTSEnginePreference(.system)

        let synth = ScriptedSynthesizer()
        let service = TextToSpeechService(synthesizerFactory: { synth })
        service.suppressionCheck = { nil }

        await service.speakStreaming("The gap should be 2.", source: .reply)
        await service.speakStreaming("5 on each side today. Expect light", source: .reply)
        await service.speakStreaming(" winds after three.", source: .reply)
        await service.flushStreamBuffer()

        XCTAssertEqual(synth.spoken, ["The gap should be 2.5 on each side today.",
                                      "Expect light winds after three."])
        XCTAssertEqual(service.lastStreamedReply?.heardCount, 2)
        XCTAssertNil(service.activeStreamedReply)
        XCTAssertFalse(service.isSpeaking)
    }

    func testStopSpeakingMidReplyRecordsHowMuchWasHeardOnTheService() async {
        let savedPreference = UserDefaults.standard.string(forKey: "ttsEnginePreference")
        defer { UserDefaults.standard.set(savedPreference, forKey: "ttsEnginePreference") }
        Config.setTTSEnginePreference(.system)

        let synth = ScriptedSynthesizer()
        synth.hangsOnUtterance = 2
        let service = TextToSpeechService(synthesizerFactory: { synth })
        service.suppressionCheck = { nil }

        let reply = service.beginStreamedReply(source: .reply)
        let sentences = ["The forecast for Auckland is sunny today.",
                         "Expect light winds after three.",
                         "Take a hat with you."]
        sentences.forEach { reply.enqueue($0) }
        let finished = Task { await reply.finish() }
        for _ in 0..<250 where synth.spoken.count < 2 { try? await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(synth.spoken.count, 2, "the second sentence is playing")
        XCTAssertTrue(service.isSpeaking)

        service.stopSpeaking(interruption: .bargeIn)
        let record = await finished.value

        XCTAssertEqual(record.heardCount, 1)
        XCTAssertEqual(record.interruption, .bargeIn)
        XCTAssertEqual(record.unheardSentences, Array(sentences.dropFirst()))
        XCTAssertEqual(service.lastStreamedReply, record)
        XCTAssertNil(service.activeStreamedReply)
        XCTAssertFalse(service.isSpeaking)
        XCTAssertEqual(synth.spoken.count, 2, "the third sentence never reached the engine")
    }
}
