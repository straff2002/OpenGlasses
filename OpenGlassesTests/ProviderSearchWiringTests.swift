import XCTest
@testable import OpenGlasses

/// Plan KZ P1–P3: the provider's own search on the real send paths, over a recording transport.
///
/// Response fixtures are handwritten from each provider's documented shape (read 2026-11-10):
/// Anthropic — platform.claude.com/docs/en/agents-and-tools/tool-use/web-search-tool and
/// …/tool-use/server-tools (pause_turn); OpenAI — developers.openai.com/api/docs/guides/tools-web-search;
/// xAI — docs.x.ai/developers/tools/web-search; OpenRouter —
/// openrouter.ai/docs/guides/features/server-tools/web-search; Gemini —
/// aistudio.google.com/docs/google-search, aistudio.google.com/docs/tool-combination and
/// aistudio.google.com/api-reference/generate-content.
@MainActor
final class ProviderSearchWiringTests: XCTestCase {

    private var suite: String!
    private var memory: ProviderSearchMemory!
    private var savedSwitch: Bool!
    private var savedHIPAA: Bool!

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipIf(ProviderSearchLive.configuredEngine != nil,
                      "a search key on this simulator wins over provider search (Decision 2)")
        RecordingQueueProtocol.reset()
        suite = "ProviderSearchWiringTests-\(UUID().uuidString)"
        memory = ProviderSearchMemory(defaults: UserDefaults(suiteName: suite)!)
        savedSwitch = Config.providerWebSearchEnabled
        savedHIPAA = Config.hipaaMode
        Config.providerWebSearchEnabled = true
        Config.hipaaMode = false
        LLMService.resetLearnedRouteStateForTesting()
    }

    override func tearDown() {
        RecordingQueueProtocol.reset()
        if let savedSwitch { Config.providerWebSearchEnabled = savedSwitch }
        if let savedHIPAA { Config.hipaaMode = savedHIPAA }
        if let suite { UserDefaults().removePersistentDomain(forName: suite) }
        LLMService.resetLearnedRouteStateForTesting()
        super.tearDown()
    }

    private func service(origin: String, webSearchConsent: Bool = true) -> LLMService {
        let s = LLMService()
        var grants: [(origin: String, scope: CloudProcessingScope)] = [(origin, .conversation)]
        if webSearchConsent { grants.append((origin, .webSearch)) }
        s.processingConsent = CloudConsentFixture.approving(grants)
        let session = RecordingQueueProtocol.session()
        s.streamingSession = session
        s.dataSession = session
        s.providerSearchMemory = memory
        s.usageTrackerOverride = UsageTracker(store: UsageStore(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("kz-usage-\(UUID().uuidString).sqlite")))
        s.nativeToolRouter = NativeToolRouter(registry: NativeToolRegistry(locationService: LocationService()))
        return s
    }

    private func body(_ index: Int) throws -> [String: Any] {
        let requests = RecordingQueueProtocol.requests
        XCTAssertGreaterThan(requests.count, index)
        return try XCTUnwrap(requests[index].json)
    }

    private func tools(_ index: Int) throws -> [[String: Any]] {
        try XCTUnwrap(body(index)["tools"] as? [[String: Any]])
    }

    private func equal(_ lhs: [[String: Any]], _ rhs: [[String: Any]]) -> Bool {
        (lhs as NSArray).isEqual(to: rhs)
    }

    // MARK: - Anthropic

    private let claude = ModelConfig(id: "kz", name: "kz", provider: LLMProvider.anthropic.rawValue,
                                     apiKey: "sk-ant-test", model: "claude-sonnet-5-5", baseURL: "")

    private let searchedBlocks: [[String: Any]] = [
        ["type": "server_tool_use", "id": "srvtoolu_1", "name": "web_search",
         "input": ["query": "airport chocolate shop hours"]],
        ["type": "web_search_tool_result", "tool_use_id": "srvtoolu_1", "content": [
            ["type": "web_search_result", "url": "https://airport.example/shops", "title": "Shops",
             "encrypted_content": "ENCRYPTED-FIXTURE", "page_age": "1 day"]]],
    ]

    private func anthropicJSON(_ content: [[String: Any]], stop: String) -> String {
        let object: [String: Any] = ["content": content, "stop_reason": stop,
                                     "usage": ["input_tokens": 10, "output_tokens": 4,
                                               "server_tool_use": ["web_search_requests": 1]]]
        return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private var answeredBlocks: [[String: Any]] {
        searchedBlocks + [
            ["type": "text", "text": "Yes, it's open until 9 tonight", "citations": [
                ["type": "web_search_result_location", "url": "https://airport.example/shops", "title": "Shops",
                 "encrypted_index": "IDX", "cited_text": "Open 06:00–21:00"]]],
            ["type": "text", "text": ", according to the airport's shop list."],
        ]
    }

    func testAnthropicCarriesItsSearchWithholdsOursAndKeepsTheSources() async throws {
        RecordingQueueProtocol.queue = [(200, anthropicJSON(answeredBlocks, stop: "end_turn"))]
        let svc = service(origin: "https://api.anthropic.com")
        let exposure = TurnWebExposure()
        let reply = try await TurnWebExposure.$current.withValue(exposure) {
            try await svc.sendAnthropic("Is the shop open?", systemPrompt: "sys", volatileTail: "tail",
                                        config: claude, includeTools: true, imageData: nil)
        }
        XCTAssertEqual(reply, "Yes, it's open until 9 tonight, according to the airport's shop list.")

        let sent = try tools(0)
        let server = sent.filter { $0["type"] as? String == "web_search_20250305" }
        XCTAssertEqual(server.count, 1)
        XCTAssertEqual(server.first?["max_uses"] as? Int, 3)
        XCTAssertFalse(ProviderSearchPolicy.declaresOurTool(sent), "our web_search is withheld")
        let system = try XCTUnwrap(body(0)["system"] as? [[String: Any]])
        XCTAssertTrue(system.compactMap { $0["text"] as? String }.joined().contains("WEB SEARCH:"))

        XCTAssertEqual(svc.replyWebSources.map(\.url), ["https://airport.example/shops"])
        XCTAssertTrue(exposure.readWeb, "the turn read the web")
        // The search blocks leave the history with the turn.
        XCTAssertFalse(String(describing: svc.rawConversationHistoryForTesting()).contains("ENCRYPTED-FIXTURE"))
    }

    func testWithoutWebSearchConsentOurToolStays() async throws {
        RecordingQueueProtocol.queue = [(200, anthropicJSON([["type": "text", "text": "ok"]], stop: "end_turn"))]
        let svc = service(origin: "https://api.anthropic.com", webSearchConsent: false)
        _ = try await svc.sendAnthropic("q", systemPrompt: "sys", config: claude, includeTools: true, imageData: nil)
        let sent = try tools(0)
        XCTAssertTrue(ProviderSearchPolicy.declaresOurTool(sent))
        XCTAssertFalse(sent.contains { $0["type"] as? String == "web_search_20250305" })
    }

    func testMedicalComplianceRequestsCarryNoProviderSearch() async throws {
        Config.hipaaMode = true
        RecordingQueueProtocol.queue = [(200, anthropicJSON([["type": "text", "text": "ok"]], stop: "end_turn"))]
        let svc = service(origin: "https://api.anthropic.com")
        _ = try await svc.sendAnthropic("q", systemPrompt: "sys", config: claude, includeTools: true, imageData: nil)
        let text = RecordingQueueProtocol.requests.first?.bodyText ?? ""
        XCTAssertFalse(text.contains("web_search_20250305"))
        XCTAssertFalse(text.contains("WEB SEARCH:"))
    }

    func testARefusalIsRetriedOnceWithOurToolAndRemembered() async throws {
        RecordingQueueProtocol.queue = [
            (400, #"{"type":"error","error":{"type":"invalid_request_error","message":"Web search is not enabled for this organization."}}"#),
            (200, anthropicJSON([["type": "text", "text": "It closes at 9."]], stop: "end_turn")),
        ]
        let svc = service(origin: "https://api.anthropic.com")
        let reply = try await svc.sendAnthropic("q", systemPrompt: "sys", config: claude, includeTools: true, imageData: nil)
        XCTAssertEqual(reply, "It closes at 9.")
        XCTAssertEqual(RecordingQueueProtocol.requests.count, 2)
        XCTAssertTrue(try tools(0).contains { $0["type"] as? String == "web_search_20250305" })
        XCTAssertFalse(try tools(1).contains { $0["type"] as? String == "web_search_20250305" })
        XCTAssertTrue(ProviderSearchPolicy.declaresOurTool(try tools(1)))
        let messages = try XCTUnwrap(body(1)["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.filter { $0["role"] as? String == "user" }.count, 1, "the question is not added twice")
        XCTAssertEqual(memory.reading(provider: .anthropic, credential: "sk-ant-test", model: claude.model),
                       .refused(.searchDisabled))

        // The next turn goes straight to our tool.
        RecordingQueueProtocol.queue = [(200, anthropicJSON([["type": "text", "text": "ok"]], stop: "end_turn"))]
        _ = try await svc.sendAnthropic("again", systemPrompt: "sys", config: claude, includeTools: true, imageData: nil)
        XCTAssertFalse(try tools(2).contains { $0["type"] as? String == "web_search_20250305" })
    }

    func testAnErrorThatDoesNotNameSearchIsNotRetried() async throws {
        RecordingQueueProtocol.queue = [
            (400, #"{"type":"error","error":{"type":"invalid_request_error","message":"max_tokens: too large"}}"#),
        ]
        let svc = service(origin: "https://api.anthropic.com")
        do {
            _ = try await svc.sendAnthropic("q", systemPrompt: "sys", config: claude, includeTools: true, imageData: nil)
            XCTFail("the refusal stands")
        } catch {}
        XCTAssertEqual(RecordingQueueProtocol.requests.count, 1)
        XCTAssertEqual(memory.reading(provider: .anthropic, credential: "sk-ant-test", model: claude.model), .clear)
    }

    func testPauseTurnIsResumedWithThePausedContentUnchanged() async throws {
        RecordingQueueProtocol.queue = [
            (200, anthropicJSON(searchedBlocks, stop: "pause_turn")),
            (200, anthropicJSON([["type": "text", "text": "Open until 9."]], stop: "end_turn")),
        ]
        let svc = service(origin: "https://api.anthropic.com")
        let reply = try await svc.sendAnthropic("q", systemPrompt: "sys", config: claude, includeTools: true, imageData: nil)
        XCTAssertEqual(reply, "Open until 9.")
        let messages = try XCTUnwrap(body(1)["messages"] as? [[String: Any]])
        let resumed = try XCTUnwrap(messages.last)
        XCTAssertEqual(resumed["role"] as? String, "assistant")
        XCTAssertTrue(equal(resumed["content"] as? [[String: Any]] ?? [], searchedBlocks), "sent back as it came")
        XCTAssertTrue(equal(try tools(0), try tools(1)), "with the same tools")
    }

    func testSearchBlocksReplayUnchangedAcrossAToolRound() async throws {
        let toolRound = searchedBlocks + [["type": "tool_use", "id": "toolu_1", "name": "kz_missing_tool", "input": [:]]]
        RecordingQueueProtocol.queue = [
            (200, anthropicJSON(toolRound, stop: "tool_use")),
            (200, anthropicJSON([["type": "text", "text": "Done."]], stop: "end_turn")),
        ]
        let svc = service(origin: "https://api.anthropic.com")
        _ = try await svc.sendAnthropic("q", systemPrompt: "sys", config: claude, includeTools: true, imageData: nil)
        let messages = try XCTUnwrap(body(1)["messages"] as? [[String: Any]])
        XCTAssertTrue(equal(messages[1]["content"] as? [[String: Any]] ?? [], toolRound),
                      "encrypted_content and all, as received")
    }

    func testStreamedSearchBlocksAndCitationsAreAssembled() async throws {
        let stream = #"""
        data: {"type":"message_start","message":{}}

        data: {"type":"content_block_start","index":0,"content_block":{"type":"server_tool_use","id":"srvtoolu_9","name":"web_search","input":{}}}

        data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"query\":\"shop hours\"}"}}

        data: {"type":"content_block_start","index":1,"content_block":{"type":"web_search_tool_result","tool_use_id":"srvtoolu_9","content":[{"type":"web_search_result","url":"https://airport.example/shops","title":"Shops","encrypted_content":"E"}]}}

        data: {"type":"content_block_start","index":2,"content_block":{"type":"text","text":""}}

        data: {"type":"content_block_delta","index":2,"delta":{"type":"citations_delta","citation":{"type":"web_search_result_location","url":"https://airport.example/shops","title":"Shops","encrypted_index":"I","cited_text":"Open"}}}

        data: {"type":"content_block_delta","index":2,"delta":{"type":"text_delta","text":"Open until 9."}}

        data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}

        data: {"type":"message_stop"}

        """#
        RecordingQueueProtocol.queue = [(200, stream)]
        let (content, _) = try await service(origin: "https://api.test").streamAnthropicContent(
            request: URLRequest(url: URL(string: "https://api.test/v1")!), model: "m") { _ in }
        XCTAssertEqual((content[0]["input"] as? [String: Any])?["query"] as? String, "shop hours")
        XCTAssertEqual(content[1]["type"] as? String, "web_search_tool_result")
        let evidence = ProviderSearchEvidence.anthropic(content: content)
        XCTAssertEqual(evidence.queries, ["shop hours"])
        XCTAssertEqual(evidence.sources.map(\.url), ["https://airport.example/shops"])
    }

    // MARK: - OpenAI and xAI on Responses

    private func responsesStream(text: String, url: String) -> String {
        """
        event: response.output_item.done
        data: {"type":"response.output_item.done","item":{"type":"web_search_call","id":"ws_1","status":"completed","action":{"type":"search","query":"store hours"}}}

        event: response.output_item.done
        data: {"type":"response.output_item.done","item":{"type":"message","id":"msg_1","role":"assistant","content":[{"type":"output_text","text":"\(text)","annotations":[{"type":"url_citation","start_index":0,"end_index":4,"url":"\(url)","title":"Hours"}]}]}}

        event: response.completed
        data: {"type":"response.completed","response":{"id":"resp_1","status":"completed","usage":{"input_tokens":20,"output_tokens":5}}}


        """
    }

    func testOpenAIGoesToResponsesWithItsSearch() async throws {
        RecordingQueueProtocol.queue = [(200, responsesStream(text: "Closes at 6.", url: "https://hardware.example/h"))]
        let svc = service(origin: "https://api.openai.com")
        let config = ModelConfig(id: "kzo", name: "kzo", provider: LLMProvider.openai.rawValue, apiKey: "sk-test",
                                 model: "gpt-4.1", baseURL: "")
        let reply = try await svc.sendOpenAICompatibleForTesting("q", config: config)
        XCTAssertEqual(reply, "Closes at 6.")
        XCTAssertEqual(RecordingQueueProtocol.requests.first?.url, "https://api.openai.com/v1/responses")
        let sent = try tools(0)
        let hosted = sent.filter { $0["type"] as? String == "web_search" }
        XCTAssertEqual(hosted.count, 1)
        XCTAssertNotNil(hosted.first?["user_location"])
        XCTAssertFalse(sent.contains { $0["type"] as? String == "function" && $0["name"] as? String == "web_search" })
        XCTAssertEqual(svc.replyWebSources.map(\.url), ["https://hardware.example/h"])
    }

    func testXAIGoesToItsOwnResponsesHostWithoutOpenAIsExtras() async throws {
        RecordingQueueProtocol.queue = [(200, responsesStream(text: "Yes.", url: "https://x.example/p"))]
        let svc = service(origin: "https://api.x.ai")
        let config = ModelConfig(id: "kzx", name: "kzx", provider: LLMProvider.xai.rawValue, apiKey: "xai-test",
                                 model: "grok-4.7", baseURL: "https://api.x.ai/v1/chat/completions")
        _ = try await svc.sendOpenAICompatibleForTesting("q", config: config)
        XCTAssertEqual(RecordingQueueProtocol.requests.first?.url, "https://api.x.ai/v1/responses")
        let sent = try body(0)
        XCTAssertEqual(sent["include"] as? [String], ["no_inline_citations"])
        XCTAssertNil(sent["prompt_cache_key"])
        XCTAssertNil(sent["reasoning"])
        XCTAssertTrue((sent["tools"] as? [[String: Any]] ?? []).contains { $0["type"] as? String == "web_search" })
    }

    // MARK: - OpenRouter on Chat Completions

    func testOpenRouterCarriesTheNativeServerTool() async throws {
        let response = #"""
        {"choices":[{"message":{"role":"assistant","content":"Yes.","annotations":[{"type":"url_citation","url_citation":{"url":"https://a.example/1","title":"First","content":"…"}}]}}],
         "usage":{"prompt_tokens":10,"completion_tokens":2,"server_tool_use_details":{"web_search_requests":1}}}
        """#
        RecordingQueueProtocol.queue = [(200, response)]
        let svc = service(origin: "https://openrouter.ai")
        let config = ModelConfig(id: "kzr", name: "kzr", provider: LLMProvider.openrouter.rawValue, apiKey: "or-test",
                                 model: "anthropic/claude-sonnet-5.5",
                                 baseURL: "https://openrouter.ai/api/v1/chat/completions")
        let reply = try await svc.sendOpenAICompatibleForTesting("q", config: config)
        XCTAssertEqual(reply, "Yes.")
        let sent = try tools(0)
        let server = sent.first { $0["type"] as? String == "openrouter:web_search" }
        XCTAssertEqual((server?["parameters"] as? [String: Any])?["engine"] as? String, "native")
        XCTAssertFalse(ProviderSearchPolicy.declaresOurTool(sent))
        XCTAssertEqual(svc.replyWebSources.map(\.title), ["First"])
        XCTAssertFalse(String(describing: svc.rawConversationHistoryForTesting()).contains("url_citation"))
    }

    // MARK: - Gemini

    func testGeminiGroundsWithGoogleSearchAndKeepsTheSuggestions() async throws {
        let response = #"""
        {"candidates":[{"content":{"role":"model","parts":[{"text":"Open until 9."}]},
          "groundingMetadata":{"webSearchQueries":["airport shop hours"],
            "groundingChunks":[{"web":{"uri":"https://vertexaisearch.cloud.google.com/grounding-api-redirect/X","title":"airport.example"}}],
            "groundingSupports":[{"segment":{"startIndex":0,"endIndex":13},"groundingChunkIndices":[0]}],
            "searchEntryPoint":{"renderedContent":"<div class=\"g\">suggestions</div>"}}}],
         "usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":3}}
        """#
        RecordingQueueProtocol.queue = [(200, response)]
        let svc = service(origin: "https://generativelanguage.googleapis.com")
        let config = ModelConfig(id: "kzg", name: "kzg", provider: LLMProvider.gemini.rawValue, apiKey: "g-test",
                                 model: "gemini-3.5-flash-lite", baseURL: "")
        let reply = try await svc.sendGemini("q", systemPrompt: "sys", config: config, includeTools: true, imageData: nil)
        XCTAssertEqual(reply, "Open until 9.")
        let sent = try tools(0)
        XCTAssertTrue(sent.contains { $0["google_search"] != nil })
        XCTAssertFalse(ProviderSearchPolicy.declaresOurTool(sent))
        XCTAssertEqual((try body(0)["toolConfig"] as? [String: Any]).flatMap { $0["functionCallingConfig"] as? [String: String] },
                       ["mode": "VALIDATED"])
        XCTAssertEqual(svc.replyWebSources.count, 1)
        XCTAssertEqual(svc.replySearchSuggestions?.renderedContent, "<div class=\"g\">suggestions</div>")
        let taken = svc.takeReplyWebAttachments()
        XCTAssertNotNil(taken.suggestions)
        XCTAssertNil(svc.replySearchSuggestions, "handed over once")
    }

    // MARK: - A boundary that comes on mid-turn (review follow-up 2026-11-10)

    /// After the first request of the turn is sent, Medical Compliance comes on: the next round
    /// must carry no provider search and nothing the search left in the history.
    private func boundaryAfterFirstRequest() {
        RecordingQueueProtocol.onRequest = { index in if index == 0 { Config.hipaaMode = true } }
    }

    func testAnthropicDropsItsSearchAndItsBlocksWhenABoundaryComesOnMidTurn() async throws {
        let toolRound = answeredBlocks + [["type": "tool_use", "id": "toolu_1", "name": "kz_missing_tool", "input": [:]]]
        RecordingQueueProtocol.queue = [
            (200, anthropicJSON(toolRound, stop: "tool_use")),
            (200, anthropicJSON([["type": "text", "text": "Done."]], stop: "end_turn")),
        ]
        boundaryAfterFirstRequest()
        let svc = service(origin: "https://api.anthropic.com")
        _ = try await svc.sendAnthropic("q", systemPrompt: "sys", config: claude, includeTools: true, imageData: nil)
        XCTAssertEqual(RecordingQueueProtocol.requests.count, 2)
        XCTAssertTrue(try tools(0).contains { $0["type"] as? String == "web_search_20250305" })
        XCTAssertFalse(try tools(1).contains { $0["type"] as? String == "web_search_20250305" }, "no search tool")
        let messages = try XCTUnwrap(body(1)["messages"] as? [[String: Any]])
        let blocks = messages.flatMap { $0["content"] as? [[String: Any]] ?? [] }
        XCTAssertFalse(blocks.contains { ["server_tool_use", "web_search_tool_result"].contains($0["type"] as? String ?? "") },
                       "no search block orphaned without its tool")
        XCTAssertFalse(blocks.contains { $0["citations"] != nil })
        XCTAssertTrue(blocks.contains { $0["type"] as? String == "tool_use" }, "the tool call and its result stay")
        let sent = RecordingQueueProtocol.requests[1].bodyText
        XCTAssertFalse(sent.contains("ENCRYPTED-FIXTURE"))
        XCTAssertFalse(sent.contains("WEB SEARCH:"))
    }

    func testResponsesDropsItsSearchAndItsItemsWhenABoundaryComesOnMidTurn() async throws {
        let round1 = """
        event: response.output_item.done
        data: {"type":"response.output_item.done","item":{"type":"web_search_call","id":"ws_1","status":"completed","action":{"type":"search","query":"store hours"}}}

        event: response.output_item.done
        data: {"type":"response.output_item.done","item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"kz_missing_tool","arguments":"{}"}}

        event: response.completed
        data: {"type":"response.completed","response":{"id":"resp_1","status":"completed","usage":{"input_tokens":20,"output_tokens":5}}}


        """
        RecordingQueueProtocol.queue = [(200, round1), (200, responsesStream(text: "Done.", url: "https://h.example/1"))]
        boundaryAfterFirstRequest()
        let svc = service(origin: "https://api.openai.com")
        let config = ModelConfig(id: "kzo", name: "kzo", provider: LLMProvider.openai.rawValue, apiKey: "sk-test",
                                 model: "gpt-4.1", baseURL: "")
        _ = try await svc.sendOpenAICompatibleForTesting("q", config: config)
        XCTAssertEqual(RecordingQueueProtocol.requests.count, 2)
        XCTAssertTrue(try tools(0).contains { $0["type"] as? String == "web_search" })
        XCTAssertFalse(try tools(1).contains { $0["type"] as? String == "web_search" }, "no hosted search")
        let input = try XCTUnwrap(body(1)["input"] as? [[String: Any]])
        XCTAssertFalse(input.contains { $0["type"] as? String == "web_search_call" }, "no search item replayed")
        XCTAssertTrue(input.contains { $0["type"] as? String == "function_call" }, "the tool call is still replayed")
        XCTAssertTrue(input.contains { $0["type"] as? String == "function_call_output" })
    }

    func testOpenRouterDropsItsServerToolWhenABoundaryComesOnMidTurn() async throws {
        let round1 = #"""
        {"choices":[{"message":{"role":"assistant","content":"","annotations":[{"type":"url_citation","url_citation":{"url":"https://a.example/1","title":"First","content":"…"}}],
          "tool_calls":[{"id":"call_1","type":"function","function":{"name":"kz_missing_tool","arguments":"{}"}}]}}],
         "usage":{"prompt_tokens":10,"completion_tokens":2,"server_tool_use_details":{"web_search_requests":1}}}
        """#
        let round2 = #"{"choices":[{"message":{"role":"assistant","content":"Done."}}],"usage":{"prompt_tokens":10,"completion_tokens":2}}"#
        RecordingQueueProtocol.queue = [(200, round1), (200, round2)]
        boundaryAfterFirstRequest()
        let svc = service(origin: "https://openrouter.ai")
        let config = ModelConfig(id: "kzr", name: "kzr", provider: LLMProvider.openrouter.rawValue, apiKey: "or-test",
                                 model: "anthropic/claude-sonnet-5.5",
                                 baseURL: "https://openrouter.ai/api/v1/chat/completions")
        _ = try await svc.sendOpenAICompatibleForTesting("q", config: config)
        XCTAssertEqual(RecordingQueueProtocol.requests.count, 2)
        XCTAssertTrue(try tools(0).contains { $0["type"] as? String == "openrouter:web_search" })
        XCTAssertFalse(try tools(1).contains { $0["type"] as? String == "openrouter:web_search" })
        XCTAssertFalse(RecordingQueueProtocol.requests[1].bodyText.contains("url_citation"))
    }

    func testGeminiDropsGoogleSearchWhenABoundaryComesOnMidTurn() async throws {
        let round1 = #"""
        {"candidates":[{"content":{"role":"model","parts":[{"functionCall":{"name":"kz_missing_tool","args":{}}}]},
          "groundingMetadata":{"webSearchQueries":["q"],"groundingChunks":[{"web":{"uri":"https://g.example/r","title":"g.example"}}]}}],
         "usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":3}}
        """#
        let round2 = #"{"candidates":[{"content":{"role":"model","parts":[{"text":"Done."}]}}],"usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":1}}"#
        RecordingQueueProtocol.queue = [(200, round1), (200, round2)]
        boundaryAfterFirstRequest()
        let svc = service(origin: "https://generativelanguage.googleapis.com")
        let config = ModelConfig(id: "kzg", name: "kzg", provider: LLMProvider.gemini.rawValue, apiKey: "g-test",
                                 model: "gemini-3.5-flash-lite", baseURL: "")
        _ = try await svc.sendGemini("q", systemPrompt: "sys", config: config, includeTools: true, imageData: nil)
        XCTAssertEqual(RecordingQueueProtocol.requests.count, 2)
        XCTAssertTrue(try tools(0).contains { $0["google_search"] != nil })
        XCTAssertFalse(try tools(1).contains { $0["google_search"] != nil })
        let toolConfig = (try body(1)["toolConfig"] as? [String: Any]).flatMap { $0["functionCallingConfig"] as? [String: String] }
        XCTAssertNotEqual(toolConfig, ["mode": "VALIDATED"])
    }

    func testTheTurnStripLeavesEarlierTurnsAlone() {
        let earlier: [String: Any] = ["role": "assistant", "content": [["type": "text", "text": "old", "citations": [["u": 1]]]]]
        let thisTurn: [String: Any] = ["role": "assistant", "content": searchedBlocks + [["type": "text", "text": "new"]]]
        let responses: [String: Any] = ["role": "assistant", "content": "r",
                                        ResponsesTranslator.rawOutputItemsKey: [["type": "web_search_call", "id": "ws"]]]
        let out = HistoryHygiene.strippingProviderSearch([earlier, ["role": "user", "content": "q"], thisTurn, responses],
                                                         fromTurnStart: 1)
        XCTAssertNotNil((out[0]["content"] as? [[String: Any]])?.first?["citations"], "before the turn: untouched")
        XCTAssertEqual((out[2]["content"] as? [[String: Any]])?.map { $0["type"] as? String }, ["text"])
        XCTAssertNil(out[3][ResponsesTranslator.rawOutputItemsKey])
        XCTAssertEqual(out[3]["content"] as? String, "r")
    }

    // MARK: - The Responses fallback after a tool ran (review follow-up 2026-11-10)

    func testAResponsesRefusalAfterAToolRanIsNotRerunOnChatCompletions() async throws {
        let round1 = """
        event: response.output_item.done
        data: {"type":"response.output_item.done","item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"kz_missing_tool","arguments":"{}"}}

        event: response.completed
        data: {"type":"response.completed","response":{"id":"resp_1","status":"completed","usage":{"input_tokens":20,"output_tokens":5}}}


        """
        RecordingQueueProtocol.queue = [(200, round1), (400, #"{"error":{"message":"kz fixture shape refused"}}"#)]
        let svc = service(origin: "https://api.openai.com")
        let config = ModelConfig(id: "kzo", name: "kzo", provider: LLMProvider.openai.rawValue, apiKey: "sk-test",
                                 model: "gpt-4.1", baseURL: "")
        do {
            _ = try await svc.sendOpenAICompatibleForTesting("q", config: config)
            XCTFail("the refusal stands: the turn is not run again")
        } catch {}
        XCTAssertEqual(RecordingQueueProtocol.requests.count, 2)
        XCTAssertFalse(RecordingQueueProtocol.requests.contains { $0.url.hasSuffix("/chat/completions") },
                       "a tool already ran, so nothing is run a second time")
    }

    // MARK: - The confirmation gate (§5, Decision 8)

    func testATurnThatReadTheWebAsksBeforeAHighImpactAction() {
        let call = ResolvedToolCall.root(name: "send_message", origin: .model)
        let plain = ToolAuthorizationPolicy.evaluate(.init(call: call, agentModeEnabled: false))
        XCTAssertEqual(plain, .allow, "the default context, with nothing read")
        guard case .confirm = ToolAuthorizationPolicy.evaluate(.init(call: call, agentModeEnabled: false,
                                                                      turnReadWeb: true)) else {
            return XCTFail("a turn that read the web asks first, even with agent mode off")
        }
        let read = ResolvedToolCall.root(name: "get_weather", origin: .model)
        XCTAssertEqual(ToolAuthorizationPolicy.evaluate(.init(call: read, agentModeEnabled: false, turnReadWeb: true)),
                       .allow, "a read is not asked about")
    }

    func testTheWebMarkIsPerTurn() async {
        XCTAssertFalse(TurnWebExposure.turnReadWeb)
        let exposure = TurnWebExposure()
        await TurnWebExposure.$current.withValue(exposure) {
            XCTAssertFalse(TurnWebExposure.turnReadWeb)
            exposure.markReadWeb()
            XCTAssertTrue(TurnWebExposure.turnReadWeb)
        }
        XCTAssertFalse(TurnWebExposure.turnReadWeb, "gone with the turn")
    }

    func testWithoutAConfirmationCoordinatorTheCallIsRefused() async {
        let registry = NativeToolRegistry(locationService: LocationService())
        let router = NativeToolRouter(registry: registry)
        router.confirmationCoordinator = nil
        let exposure = TurnWebExposure()
        exposure.markReadWeb()
        let outcome = await TurnWebExposure.$current.withValue(exposure) {
            await router.executeRoot(name: "send_message", args: ["to": "Everyone", "body": "hi"],
                                     origin: .model, invocationID: UUID().uuidString)
        }
        guard case .rejected = outcome else { return XCTFail("fails closed: \(outcome)") }
    }
}
