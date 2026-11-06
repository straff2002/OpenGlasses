import XCTest
@testable import OpenGlasses

/// Plan KP P2 — a follow-ups tail is never spoken while a reply streams, on any provider path that
/// streams Direct speech, and never shown in the Chat tab's live bubble.
///
/// The provider streams are the real streaming parsers fed canned SSE (`SSEQueueProtocol`):
/// Anthropic's whole tool-loop turn (`sendAnthropic`), the OpenAI-compatible chat stream
/// (`streamOpenAIMessage`, which every OpenAI-compatible provider's `onToken` comes from) and the
/// Responses stream the ChatGPT account route uses (`streamResponsesTurn`). The on-device MLX model
/// can't run headless, so its stream is the shape it produces — token-sized pieces, a think block
/// — fed straight to the turn's `ingest`. Gemini doesn't stream: its reply is said whole, after
/// the tail is off. Each ends as `sendMessage` does, with `takingFollowUpTail`, then
/// `finish(reply:)`.
@MainActor
final class FollowUpStreamingTests: XCTestCase {

    override func setUp() {
        super.setUp()
        CloudConsentFixture.approveShared(["https://api.anthropic.com"])
        SSEQueueProtocol.queue = []
    }

    override func tearDown() {
        CloudConsentFixture.restoreShared()
        super.tearDown()
    }

    private var request: URLRequest { URLRequest(url: URL(string: "https://api.test/v1")!) }

    private func service() -> LLMService {
        let llm = LLMService()
        llm.processingConsent = CloudConsentFixture.conversation()
        llm.streamingSession = SSEQueueProtocol.session()
        return llm
    }

    private func normalised(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Nothing of the tail — no tag, no question — was said.
    private func assertNoTailSaid(_ speech: RecordingStreamedSpeech, questions: [String],
                                  file: StaticString = #filePath, line: UInt = #line) {
        let said = (speech.played + speech.wholeReplies).joined(separator: " ")
        XCTAssertFalse(said.contains("<"), "no tag or piece of one: \(said)", file: file, line: line)
        XCTAssertFalse(said.contains("|"), said, file: file, line: line)
        for question in questions {
            XCTAssertFalse(said.contains(question), "\(question) was said: \(said)", file: file, line: line)
        }
    }

    private func sse(_ deltas: [String], anthropic: Bool) -> String {
        func escaped(_ text: String) -> String {
            String(data: try! JSONSerialization.data(withJSONObject: [text], options: [.fragmentsAllowed]),
                   encoding: .utf8)!.dropFirst().dropLast().description
        }
        if anthropic {
            var body = """
            data: {"type":"message_start","message":{}}

            data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}


            """
            for delta in deltas {
                body += "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\(escaped(delta))}}\n\n"
            }
            body += """
            data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}

            data: {"type":"message_stop"}


            """
            return body
        }
        var body = ""
        for delta in deltas {
            body += "data: {\"choices\":[{\"delta\":{\"content\":\(escaped(delta))}}]}\n\n"
        }
        return body + "data: [DONE]\n\n"
    }

    // MARK: - Anthropic: the whole turn, history included

    func testAnthropicTailSplitOverChunksAndSentencesIsNeverSaid() async throws {
        let questions = ["Where is the panel?", "How do I test it?"]
        // The tag arrives in two pieces, its questions over three, and each ends in "?" so the
        // splitter would cut the tail into several sentences if it were ever handed it.
        SSEQueueProtocol.queue = [(200, sse([
            "The fuse is in the panel by the door. ",
            "Check it first.\n<ne", "xt>Where is the", " panel?|How do I",
            " test it?</next>",
        ], anthropic: true))]
        let llm = service()
        let speech = RecordingStreamedSpeech()
        let stream = DirectReplySpeechStream(speaker: speech)
        let config = ModelConfig(id: "t", name: "t", provider: "anthropic",
                                 apiKey: "sk-test", model: "claude-test", baseURL: "")

        let response = try await llm.sendAnthropic(
            "where's the fuse", systemPrompt: "sys", config: config, includeTools: false,
            imageData: nil, onToken: { stream.ingest($0) }, onStreamReset: { stream.streamDidReset() })
        XCTAssertEqual(stream.queue?.sentenceCount, 2,
                       "both sentences reached speech before generation ended, and nothing more")
        let reply = llm.takingFollowUpTail(response)
        await stream.finish(reply: reply)

        XCTAssertEqual(reply, "The fuse is in the panel by the door. Check it first.")
        XCTAssertEqual(llm.replyFollowUps, questions)
        XCTAssertEqual(speech.played, ["The fuse is in the panel by the door.", "Check it first."])
        XCTAssertEqual(normalised(speech.played.joined(separator: " ")), normalised(reply),
                       "the answer is said word for word, and only the answer")
        XCTAssertEqual(speech.wholeReplies, [])
        assertNoTailSaid(speech, questions: questions)
        let history = llm.conversationHistoryForTesting()
        XCTAssertEqual(history.last?.role, "assistant")
        XCTAssertEqual(history.last?.content, reply, "the model never sees its own tags again")
    }

    func testAChunkHoldingTheAnswersEndAndTheTailsStartSaysOnlyTheAnswer() async throws {
        SSEQueueProtocol.queue = [(200, sse([
            "Turn the isolator off first. ",
            "Then open the cover. <next>Is it safe?|What next?</next>",
        ], anthropic: true))]
        let llm = service()
        let speech = RecordingStreamedSpeech()
        let stream = DirectReplySpeechStream(speaker: speech)
        let config = ModelConfig(id: "t", name: "t", provider: "anthropic",
                                 apiKey: "sk-test", model: "claude-test", baseURL: "")
        let response = try await llm.sendAnthropic(
            "how do I open it", systemPrompt: "sys", config: config, includeTools: false,
            imageData: nil, onToken: { stream.ingest($0) }, onStreamReset: { stream.streamDidReset() })
        // The splitter would not cut before "<", so without the hold the tail rode on the last
        // sentence. The answer's end is released the moment the tail starts.
        XCTAssertEqual(stream.queue?.sentenceCount, 2)
        await stream.finish(reply: llm.takingFollowUpTail(response))

        XCTAssertEqual(speech.played, ["Turn the isolator off first.", "Then open the cover."])
        assertNoTailSaid(speech, questions: ["Is it safe?", "What next?"])
    }

    // MARK: - OpenAI-compatible chat stream

    func testOpenAICompatibleStreamNeverSaysTheTail() async throws {
        SSEQueueProtocol.queue = [(200, sse([
            "Yes", ". The", " part ships", " tomorrow", " morning.", "\n", "<", "next", ">",
            "When does", " it arrive?", "|", "Can I track", " it?", "</", "next", ">",
        ], anthropic: false))]
        let speech = RecordingStreamedSpeech()
        let stream = DirectReplySpeechStream(speaker: speech)
        let message = try await service().streamOpenAIMessage(
            request: request, provider: .openai, model: "m") { stream.ingest($0) }
        let llm = LLMService()
        let reply = llm.takingFollowUpTail(message["content"] as? String ?? "")
        await stream.finish(reply: reply)

        XCTAssertEqual(reply, "Yes. The part ships tomorrow morning.")
        XCTAssertEqual(llm.replyFollowUps, ["When does it arrive?", "Can I track it?"])
        XCTAssertEqual(speech.played, ["Yes. The part ships tomorrow morning."])
        assertNoTailSaid(speech, questions: llm.replyFollowUps)
    }

    // MARK: - Responses stream (ChatGPT account route)

    func testResponsesStreamNeverSaysTheTail() async throws {
        let text = "The filter is under the unit. Slide it out to the left.\n<next>How often to change it?</next>"
        let deltas = ["The filter is under", " the unit. Slide it out", " to the left.\n<next>How",
                      " often to change it?</next>"]
        var body = "event: response.created\ndata: {\"type\":\"response.created\",\"response\":{\"id\":\"r\"}}\n\n"
        for delta in deltas {
            let json = String(data: try JSONSerialization.data(withJSONObject: ["type": "response.output_text.delta", "delta": delta]), encoding: .utf8)!
            body += "event: response.output_text.delta\ndata: \(json)\n\n"
        }
        let content: [[String: Any]] = [["type": "output_text", "text": text]]
        let output: [[String: Any]] = [["type": "message", "content": content]]
        let usage: [String: Any] = ["input_tokens": 3, "output_tokens": 4]
        let response: [String: Any] = ["id": "r", "output": output, "usage": usage]
        let completed: [String: Any] = ["type": "response.completed", "response": response]
        body += "event: response.completed\ndata: \(String(data: try JSONSerialization.data(withJSONObject: completed), encoding: .utf8)!)\n\n"
        SSEQueueProtocol.queue = [(200, body)]

        let speech = RecordingStreamedSpeech()
        let stream = DirectReplySpeechStream(speaker: speech)
        let json = try await service().streamResponsesTurn(request: request) { stream.ingest($0) }
        let llm = LLMService()
        let reply = llm.takingFollowUpTail(ResponsesTranslator.parseOutput(json).text)
        await stream.finish(reply: reply)

        XCTAssertEqual(reply, "The filter is under the unit. Slide it out to the left.")
        XCTAssertEqual(normalised(speech.played.joined(separator: " ")), normalised(reply))
        assertNoTailSaid(speech, questions: ["How often to change it?"])
    }

    // MARK: - On-device MLX shape, and Gemini (whole)

    func testOnDeviceTokenStreamWithAThinkBlockNeverSaysTheTail() async {
        let speech = RecordingStreamedSpeech()
        let stream = DirectReplySpeechStream(speaker: speech)
        for token in ["<think>", "The user", " wants the", " breaker.", "</think>", "Sure", ".", " The",
                      " breaker", " is", " on", " the", " left", ".", "\n", "<", "ne", "xt", ">", "Which",
                      " one", "?", "|", "Why", "?", "</", "next", ">"] {
            stream.ingest(token)
        }
        let llm = LLMService()
        let reply = llm.takingFollowUpTail("Sure. The breaker is on the left.\n<next>Which one?|Why?</next>")
        await stream.finish(reply: reply)

        XCTAssertEqual(speech.played, ["Sure. The breaker is on the left."])
        XCTAssertEqual(speech.wholeReplies, [])
        assertNoTailSaid(speech, questions: ["Which one?", "Why?"])
    }

    func testAReplyThatIsNotStreamedIsSaidWholeWithoutItsTail() async {
        // Gemini, the Apple model, or the switch off: nothing reaches `ingest`.
        let speech = RecordingStreamedSpeech()
        let stream = DirectReplySpeechStream(speaker: speech)
        let llm = LLMService()
        let reply = llm.takingFollowUpTail("It's twelve degrees.\n<next>Will it rain?</next>")
        await stream.finish(reply: reply)
        XCTAssertEqual(speech.wholeReplies, ["It's twelve degrees."])
        assertNoTailSaid(speech, questions: ["Will it rain?"])
    }

    // MARK: - The gate's edges

    func testATagInsideASentenceHoldsTheRestForTheFinalReply() async {
        // Not a tail by the parser's rules when unclosed, but a closed one at the end is: either
        // way nothing from the tag on is streamed, and the end says what the final reply says.
        let speech = RecordingStreamedSpeech()
        let stream = DirectReplySpeechStream(speaker: speech)
        stream.ingest("All done <next>Anything else?</next>")
        let reply = LLMService().takingFollowUpTail("All done <next>Anything else?</next>")
        await stream.finish(reply: reply)
        XCTAssertEqual(speech.played, [])
        XCTAssertEqual(speech.wholeReplies, ["All done"])
    }

    func testAPieceThatNeverBecomesTheTagIsStillSaid() async {
        let speech = RecordingStreamedSpeech()
        let stream = DirectReplySpeechStream(speaker: speech)
        for chunk in ["The reading should be under 5 psi, so a", " gauge reading of 3 <", " 5 is fine. ",
                      "Carry on with the next step now."] {
            stream.ingest(chunk)
        }
        let reply = "The reading should be under 5 psi, so a gauge reading of 3 < 5 is fine. Carry on with the next step now."
        await stream.finish(reply: LLMService().takingFollowUpTail(reply))
        XCTAssertEqual(normalised(speech.played.joined(separator: " ")), normalised(reply),
                       "a held \"<\" that was not the tag is released with the next chunk")
    }

    func testAToolLoopResetDoesNotReleaseATail() {
        let gate = StreamSpeechGate()
        _ = gate.ingest("Let me check that for you. <next>Is it on?</next>")
        XCTAssertEqual(gate.holdReason, .followUpTail)
        XCTAssertEqual(gate.endIteration(), [], "the preamble was released when the tail started")
        XCTAssertEqual(gate.ingest("The unit is on and cooling well right now. "), [])
        XCTAssertNil(gate.holdReason, "the next iteration starts clean")
    }

    func testTheGateReleasesTheAnswerEndAtOnceWhenTheTailStarts() {
        let gate = StreamSpeechGate()
        XCTAssertEqual(gate.ingest("Yes."), [], "short, so it waits to merge")
        XCTAssertEqual(gate.ingest("\n<next>Why?</next>"), ["Yes."])
        XCTAssertEqual(gate.ingest(" More text after the tail."), [])
    }

    // MARK: - The Chat tab's live bubble

    func testTheLiveBubbleNeverShowsTheTail() {
        var bubble = StreamingTurn(threadId: "t", text: "")
        for chunk in ["The fuse is in", " the panel.\n<", "nex", "t>Where is", " it?</next>"] {
            bubble.append(chunk)
            XCTAssertFalse(bubble.text.contains("<"), bubble.text)
            XCTAssertFalse(bubble.text.contains("Where"), bubble.text)
        }
        XCTAssertEqual(bubble.text, "The fuse is in the panel.\n")
        bubble.restart()
        bubble.append("A new iteration.")
        XCTAssertEqual(bubble.text, "A new iteration.")
    }

    func testStreamingVisibleHoldsBackOnlyWhatCouldBecomeTheTag() {
        XCTAssertEqual(FollowUpTail.streamingVisible("a <").visible, "a ")
        XCTAssertEqual(FollowUpTail.streamingVisible("a <NeX").visible, "a ")
        XCTAssertEqual(FollowUpTail.streamingVisible("a <b").visible, "a <b")
        XCTAssertEqual(FollowUpTail.streamingVisible("a <nexus").visible, "a <nexus")
        let started = FollowUpTail.streamingVisible("done <NEXT>why")
        XCTAssertEqual(started.visible, "done ")
        XCTAssertTrue(started.tailStarted)
        XCTAssertFalse(FollowUpTail.streamingVisible("plain").tailStarted)
    }
}
