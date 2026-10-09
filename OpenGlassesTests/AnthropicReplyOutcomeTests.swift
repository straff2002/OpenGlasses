import XCTest
@testable import OpenGlasses

/// Plan IE P3 — effort on the wire, and a 200 that is not an answer. A declined reply and a
/// reply that ran out of room used to reach the caller as "invalid response"; each is now its own
/// error, with its own line in the report, its own banner, and its own place in the fallback chain.
@MainActor
final class AnthropicReplyOutcomeTests: XCTestCase {

    override func setUp() {
        super.setUp()
        RecordingQueueProtocol.reset()
    }

    override func tearDown() {
        RecordingQueueProtocol.reset()
        super.tearDown()
    }

    private func service() -> LLMService {
        let s = LLMService()
        let session = RecordingQueueProtocol.session()
        s.streamingSession = session
        s.dataSession = session
        return s
    }

    private let config = ModelConfig(id: "ie", name: "ie", provider: LLMProvider.anthropic.rawValue,
                                     apiKey: "test", model: "claude-sonnet-5-5", baseURL: "",
                                     reasoningEffort: nil)

    private func send(_ svc: LLMService, streamed: Bool) async throws -> String {
        try await svc.sendAnthropic("hello", systemPrompt: "sys", config: config, includeTools: true,
                                    imageData: nil, onToken: streamed ? { _ in } : nil)
    }

    // MARK: - Effort on the wire

    private func sentBody(model: String, effort: String?, tools: Bool = true) async throws -> [String: Any] {
        RecordingQueueProtocol.reset()
        RecordingQueueProtocol.queue = [(200, #"{"content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn"}"#)]
        var config = self.config
        config.model = model
        config.reasoningEffort = effort
        _ = try await service().sendAnthropic("hello", systemPrompt: "sys", config: config,
                                              includeTools: tools, imageData: nil)
        return try XCTUnwrap(RecordingQueueProtocol.requests.last?.json)
    }

    private func effort(in body: [String: Any]) -> String? {
        (body["output_config"] as? [String: Any])?["effort"] as? String
    }

    /// The owner's decision: at Automatic, a model that thinks by default is sent `low`.
    func testAutomaticSendsLowToAModelThatThinksByDefault() async throws {
        for model in ["claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5",
                      "claude-sonnet-5", "claude-haiku-5-5"] {
            let body = try await sentBody(model: model, effort: nil)
            XCTAssertEqual(effort(in: body), "low", model)
            XCTAssertEqual(body["max_tokens"] as? Int, 4_096, "\(model): the tool turn is no longer capped at 1,024")
            XCTAssertNil(body["thinking"], model)
        }
        for model in ["claude-opus-4-8", "claude-opus-4-6", "claude-haiku-4-5", "claude-nova-9"] {
            let body = try await sentBody(model: model, effort: nil)
            XCTAssertNil(body["output_config"], model)
            XCTAssertNil(body["thinking"], model)
        }
        let unchanged = try await sentBody(model: "claude-opus-4-8", effort: nil)
        XCTAssertEqual(unchanged["max_tokens"] as? Int, 1_024,
                       "a model that does not think by default keeps its tool-turn cap")
    }

    func testAnExplicitSettingWins() async throws {
        let high = try await sentBody(model: "claude-sonnet-5-5", effort: "high")
        XCTAssertEqual(effort(in: high), "high")
        let extraHigh = try await sentBody(model: "claude-opus-5-5", effort: "xhigh")
        XCTAssertEqual(effort(in: extraHigh), "xhigh")
        let medium = try await sentBody(model: "claude-opus-4-8", effort: "medium")
        XCTAssertEqual(effort(in: medium), "medium")
        // `none` has no Anthropic equivalent: the lowest effort, never a disabled-thinking switch.
        let none = try await sentBody(model: "claude-opus-5-5", effort: "none")
        XCTAssertEqual(effort(in: none), "low")
        XCTAssertNil(none["thinking"])
        // …and a model that would refuse the field is never sent it, whatever was saved.
        let older = try await sentBody(model: "claude-haiku-4-5", effort: "high")
        XCTAssertNil(older["output_config"])
    }

    // MARK: - The outcome (pure)

    func testOutcomeTable() {
        typealias Outcome = AnthropicReply.Outcome
        let rows: [(stop: String?, text: String, tools: Bool, expected: Outcome)] = [
            ("end_turn", "An answer.", false, .answered),
            ("tool_use", "", true, .answered),
            (nil, "An answer.", false, .answered),
            // An empty reply that simply ended is the old "invalid response", not a new outcome.
            ("end_turn", "", false, .answered),
            ("refusal", "", false, .declined),
            ("refusal", "I can't help with that.", false, .declined),
            ("refusal", "", true, .declined),
            ("max_tokens", "", false, .ranOutOfRoom),
            ("max_tokens", "  \n", false, .ranOutOfRoom),
            // Cut short, but something was said or called: that is a short answer.
            ("max_tokens", "Half an", false, .answered),
            ("max_tokens", "", true, .answered),
        ]
        for row in rows {
            XCTAssertEqual(AnthropicReply.outcome(stopReason: row.stop, text: row.text, hasToolCalls: row.tools),
                           row.expected, "\(row.stop ?? "nil") text=\(row.text.count) tools=\(row.tools)")
        }
    }

    // MARK: - A declined reply

    func testADeclinedReplyIsItsOwnError() async {
        // Checked before the content is read: this one carries text, and none of it is an answer.
        RecordingQueueProtocol.queue = [(200, #"{"content":[{"type":"text","text":"I can't help with that."}],"stop_reason":"refusal"}"#)]
        do {
            _ = try await send(service(), streamed: false)
            XCTFail("a declined reply is not an answer")
        } catch LLMError.modelDeclined(let provider) {
            XCTAssertEqual(provider, "Anthropic")
        } catch {
            XCTFail("expected .modelDeclined, got \(error)")
        }
    }

    func testADeclinedStreamIsItsOwnError() async {
        let stream = """
        data: {"type":"message_start","message":{}}

        data: {"type":"message_delta","delta":{"stop_reason":"refusal"}}

        data: {"type":"message_stop"}

        """
        RecordingQueueProtocol.queue = [(200, stream)]
        do {
            _ = try await send(service(), streamed: true)
            XCTFail("a declined reply is not an answer")
        } catch LLMError.modelDeclined {
        } catch {
            XCTFail("expected .modelDeclined, got \(error)")
        }
        XCTAssertEqual(RecordingQueueProtocol.requests.count, 1, "a decline is not retried as a transient fault")
    }

    // MARK: - A reply that ran out of room

    func testAReplyThatSpentItsRoomOnThinkingIsItsOwnError() async {
        RecordingQueueProtocol.queue = [(200, #"{"content":[{"type":"thinking","thinking":"","signature":"signature-fixture"}],"stop_reason":"max_tokens"}"#)]
        do {
            _ = try await send(service(), streamed: false)
            XCTFail("nothing was said")
        } catch LLMError.outputTruncated(let provider) {
            XCTAssertEqual(provider, "Anthropic")
        } catch {
            XCTFail("expected .outputTruncated, got \(error)")
        }
    }

    func testATruncatedStreamWithNoTextIsItsOwnError() async {
        let stream = """
        data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}

        data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"signature-fixture"}}

        data: {"type":"message_delta","delta":{"stop_reason":"max_tokens"}}

        data: {"type":"message_stop"}

        """
        RecordingQueueProtocol.queue = [(200, stream)]
        do {
            _ = try await send(service(), streamed: true)
            XCTFail("nothing was said")
        } catch LLMError.outputTruncated {
        } catch {
            XCTFail("expected .outputTruncated, got \(error)")
        }
    }

    func testAReplyCutShortAfterItSaidSomethingIsStillAReply() async throws {
        RecordingQueueProtocol.queue = [(200, #"{"content":[{"type":"text","text":"The valve is"}],"stop_reason":"max_tokens"}"#)]
        let reply = try await send(service(), streamed: false)
        XCTAssertEqual(reply, "The valve is")
    }

    func testAnEmptyReplyThatSimplyEndedIsStillAnInvalidResponse() async {
        RecordingQueueProtocol.queue = [(200, #"{"content":[],"stop_reason":"end_turn"}"#)]
        do {
            _ = try await send(service(), streamed: false)
            XCTFail("an empty reply is not an answer")
        } catch LLMError.invalidResponse {
        } catch {
            XCTFail("expected .invalidResponse, got \(error)")
        }
    }

    // MARK: - What may be written down, and what the wearer reads

    func testEachOutcomeHasItsOwnSummaryRung() {
        let declined = SafeErrorSummary(LLMError.modelDeclined(provider: "Anthropic"))
        XCTAssertEqual(declined.category, .modelDeclined)
        XCTAssertEqual(declined.description, "modelDeclined(refusal)")

        let truncated = SafeErrorSummary(LLMError.outputTruncated(provider: "Anthropic"))
        XCTAssertEqual(truncated.category, .outputTruncated)
        XCTAssertEqual(truncated.description, "outputTruncated(max_tokens)")

        XCTAssertEqual(SafeErrorSummary(LLMError.invalidResponse("Anthropic")).description,
                       "badServerResponse(invalidResponse)", "the old rung is as it was")
    }

    func testEachOutcomeHasItsOwnBannerReason() {
        let declined = AppState.plainReason(SafeErrorSummary(LLMError.modelDeclined(provider: "Anthropic")).description)
        let truncated = AppState.plainReason(SafeErrorSummary(LLMError.outputTruncated(provider: "Anthropic")).description)
        let unreadable = AppState.plainReason(SafeErrorSummary(LLMError.invalidResponse("Anthropic")).description)

        XCTAssertTrue(declined.contains("declined"), declined)
        XCTAssertTrue(truncated.contains("ran out of room"), truncated)
        XCTAssertEqual(unreadable, "the AI's reply couldn't be read")
        XCTAssertEqual(Set([declined, truncated, unreadable]).count, 3)
        for line in [declined, truncated] {
            XCTAssertNil(line.range(of: #"\bPlan [A-Z]{1,2}\b"#, options: .regularExpression), line)
        }
    }

    // MARK: - The fallback chain

    func testADeclineEndsTheCandidateAndATruncationTriesAnotherModel() {
        // A decline: asking this model again changes nothing, but another model may answer.
        XCTAssertEqual(ModelFallbackChain.classify(LLMError.modelDeclined(provider: "Anthropic")), .terminalForCandidate)
        // A truncation: a model that thinks less may fit the same answer.
        XCTAssertEqual(ModelFallbackChain.classify(LLMError.outputTruncated(provider: "Anthropic")), .retryOtherModel)

        let candidates = [
            ModelFallbackChain.Candidate(id: "a", isLocalMLX: false, supportsVision: true, contextTokens: 200_000),
            ModelFallbackChain.Candidate(id: "b", isLocalMLX: false, supportsVision: true, contextTokens: 200_000),
        ]
        let needs = ModelFallbackChain.TurnNeeds(requiresVision: false, isBackgrounded: false)
        for error in [LLMError.modelDeclined(provider: "Anthropic"), .outputTruncated(provider: "Anthropic")] {
            let next = ModelFallbackChain.next(candidates: candidates, tried: ["a"], needs: needs,
                                               failure: ModelFallbackChain.classify(error), currentWindow: 200_000)
            XCTAssertEqual(next?.id, "b", "neither ends the turn: \(error)")
        }
    }

    func testNeitherIsRetriedAsATransientStreamFault() {
        XCTAssertFalse(LLMService.isTransientSSEError(LLMError.modelDeclined(provider: "Anthropic")))
        XCTAssertFalse(LLMService.isTransientSSEError(LLMError.outputTruncated(provider: "Anthropic")))
    }

    func testTheSpokenReasonForADeclineIsNotACredentialProblem() {
        let phrase = ModelSwitchNarrator.exhaustionPhrase(lastError: LLMError.modelDeclined(provider: "Anthropic"))
        XCTAssertTrue(phrase.contains("declined"), phrase)
        XCTAssertFalse(phrase.contains("credentials"), phrase)
    }
}
