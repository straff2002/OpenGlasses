import XCTest
@testable import OpenGlasses

/// Plan KZ §3: each provider's response shape read into queries, sources and errors.
///
/// Every fixture is written by hand from the shape the provider's own documentation gives
/// (read 2026-11-10), not copied from it. The source page is named on each.
final class ProviderSearchEvidenceTests: XCTestCase {

    private func json(_ text: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }

    // MARK: - Anthropic

    /// Shape: platform.claude.com/docs/en/agents-and-tools/tool-use/web-search-tool —
    /// `server_tool_use`, `web_search_tool_result` with `web_search_result` items, and text blocks
    /// carrying `web_search_result_location` citations; `usage.server_tool_use.web_search_requests`.
    private let anthropicResponse = #"""
    {"content":[
      {"type":"text","text":"I'll check the shop list."},
      {"type":"server_tool_use","id":"srvtoolu_fixture1","name":"web_search","input":{"query":"airport chocolate shop opening hours"}},
      {"type":"web_search_tool_result","tool_use_id":"srvtoolu_fixture1","content":[
        {"type":"web_search_result","url":"https://www.airport.example/shops","title":"Shops and hours","encrypted_content":"ENC1","page_age":"2 days"},
        {"type":"web_search_result","url":"https://news.example/a","title":"A news page","encrypted_content":"ENC2"}]},
      {"type":"text","text":"It's open until 9 tonight","citations":[
        {"type":"web_search_result_location","url":"https://www.airport.example/shops","title":"Shops and hours","encrypted_index":"IDX","cited_text":"Open daily 06:00 to 21:00."}]},
      {"type":"text","text":", according to the airport's shop list."}],
     "stop_reason":"end_turn",
     "usage":{"input_tokens":10,"output_tokens":5,"server_tool_use":{"web_search_requests":1}}}
    """#

    func testAnthropicQueriesSourcesSnippetsAndCount() {
        let response = json(anthropicResponse)
        let evidence = ProviderSearchEvidence.anthropic(content: response["content"] as! [[String: Any]],
                                                        usage: response["usage"] as? [String: Any])
        XCTAssertEqual(evidence.queries, ["airport chocolate shop opening hours"])
        XCTAssertEqual(evidence.sources.map(\.url), ["https://www.airport.example/shops"], "only what the reply cites")
        XCTAssertEqual(evidence.sources.first?.site, "airport.example")
        XCTAssertEqual(evidence.sources.first?.title, "Shops and hours")
        XCTAssertEqual(evidence.citedSnippets, ["Open daily 06:00 to 21:00."])
        XCTAssertEqual(evidence.searchCount, 1)
        XCTAssertEqual(evidence.resultCount, 2)
        XCTAssertTrue(evidence.readWeb)
    }

    func testAnthropicCitedTextIsJoinedWithoutBreakingTheSentence() {
        let content = json(anthropicResponse)["content"] as! [[String: Any]]
        XCTAssertEqual(AnthropicReply.text(in: content),
                       "I'll check the shop list. It's open until 9 tonight, according to the airport's shop list.",
                       "two whole sentences cut at a block boundary get their space back (review follow-up 2026-11-10)")
        // Cut mid-sentence at a citation, nothing is added.
        XCTAssertEqual(AnthropicReply.text(in: [
            ["type": "text", "text": "Let me check."],
            ["type": "text", "text": "The shop is open", "citations": [["type": "web_search_result_location", "url": "https://a.example"]]],
            ["type": "text", "text": " until 9, per its site."],
        ]), "Let me check. The shop is open until 9, per its site.")
        // Without citations the blocks stay on their own lines, as before.
        XCTAssertEqual(AnthropicReply.text(in: [["type": "text", "text": "a"], ["type": "text", "text": "b"]]), "a\nb")
    }

    /// Shape: the same page — an error is one `web_search_tool_result_error` object with an
    /// `error_code`, returned inside a 200.
    func testAnthropicErrorBlockAndEmptyResults() {
        let content: [[String: Any]] = [
            ["type": "server_tool_use", "id": "srvtoolu_2", "name": "web_search", "input": ["query": "q"]],
            ["type": "web_search_tool_result", "tool_use_id": "srvtoolu_2",
             "content": ["type": "web_search_tool_result_error", "error_code": "unavailable"]],
        ]
        let failed = ProviderSearchEvidence.anthropic(content: content)
        XCTAssertEqual(failed.errors, ["unavailable"])
        XCTAssertEqual(failed.searchCount, 1)
        XCTAssertFalse(failed.readWeb)
        XCTAssertTrue(ProviderSearchRefusal.startsCoolOff(failed.errors))

        let empty = ProviderSearchEvidence.anthropic(content: [
            ["type": "server_tool_use", "id": "s", "name": "web_search", "input": ["query": "nothing"]],
            ["type": "web_search_tool_result", "tool_use_id": "s", "content": [[String: Any]]()],
        ])
        XCTAssertTrue(empty.sources.isEmpty)
        XCTAssertEqual(empty.resultCount, 0)
        XCTAssertTrue(empty.errors.isEmpty)
        XCTAssertFalse(ProviderSearchRefusal.startsCoolOff(["max_uses_exceeded", "query_too_long"]))
    }

    // MARK: - OpenAI Responses

    /// Shape: developers.openai.com/api/docs/guides/tools-web-search — a `web_search_call` item
    /// with `action {type: search, query, sources}`, then a message whose `output_text` carries
    /// `url_citation` annotations.
    func testOpenAIResponsesCallsAndAnnotations() {
        let response = json(#"""
        {"output":[
          {"type":"web_search_call","id":"ws_1","status":"completed","action":{"type":"search","query":"hardware store main street hours","sources":[{"type":"url","url":"https://hardware.example/hours"}]}},
          {"type":"message","role":"assistant","content":[{"type":"output_text","text":"It closes at 6.","annotations":[
            {"type":"url_citation","start_index":0,"end_index":15,"url":"https://hardware.example/hours","title":"Opening hours"},
            {"type":"url_citation","start_index":0,"end_index":15,"url":"https://hardware.example/hours","title":"Opening hours"}]}]}]}
        """#)
        let evidence = ProviderSearchEvidence.responses(response, provider: .openai)
        XCTAssertEqual(evidence.queries, ["hardware store main street hours"])
        XCTAssertEqual(evidence.sources.map(\.url), ["https://hardware.example/hours"], "de-duplicated")
        XCTAssertEqual(evidence.searchCount, 1)
        XCTAssertEqual(evidence.sources.first?.provider, "openai")
    }

    /// Shape: docs.x.ai/developers/tools/citations — annotations whose `title` is the citation
    /// number, and a top-level `citations` list of every address seen.
    func testXAICitationNumbersAreNotTitlesAndTheSeenListIsTheFallback() {
        let annotated = ProviderSearchEvidence.responses(json(#"""
        {"output":[{"type":"web_search_call","status":"completed","action":{"type":"search","query":"q"}},
          {"type":"message","content":[{"type":"output_text","text":"x","annotations":[{"type":"url_citation","url":"https://www.site.example/p","title":"1","start_index":0,"end_index":1}]}]}],
         "citations":["https://other.example/z"]}
        """#), provider: .xai)
        XCTAssertEqual(annotated.sources.map(\.url), ["https://www.site.example/p"])
        XCTAssertEqual(annotated.sources.first?.title, "site.example")

        let seenOnly = ProviderSearchEvidence.responses(json(#"""
        {"output":[{"type":"message","content":[{"type":"output_text","text":"x"}]}],"citations":["https://other.example/z"]}
        """#), provider: .xai)
        XCTAssertEqual(seenOnly.sources.map(\.url), ["https://other.example/z"])
    }

    // MARK: - OpenRouter and Groq

    /// Shape: openrouter.ai/docs/guides/features/web-search — `message.annotations[]` with the
    /// fields nested under `url_citation`; openrouter.ai/docs/guides/features/server-tools/web-search
    /// — `usage.server_tool_use_details.web_search_requests`.
    func testOpenRouterAnnotationsAndCount() {
        let message = json(#"""
        {"role":"assistant","content":"Yes.","annotations":[{"type":"url_citation","url_citation":{"url":"https://a.example/1","title":"First","content":"…","start_index":0,"end_index":3}}]}
        """#)
        let evidence = ProviderSearchEvidence.chatMessage(message,
                                                          usage: ["server_tool_use_details": ["web_search_requests": 2]],
                                                          provider: .openrouter)
        XCTAssertEqual(evidence.sources.map(\.title), ["First"])
        XCTAssertEqual(evidence.searchCount, 2)
        let stripped = LLMService.strippingSearchFields(message.merging(["usage": [:], "executed_tools": []]) { $1 })
        XCTAssertNil(stripped["annotations"])
        XCTAssertNil(stripped["usage"])
        XCTAssertNil(stripped["executed_tools"])
        XCTAssertEqual(stripped["content"] as? String, "Yes.")
    }

    /// Shape: console.groq.com/docs/browser-search shows `executed_tools` on the message; its
    /// fields are not documented, so the reader is lenient and only counts what it recognises.
    func testGroqExecutedToolsAreReadLeniently() {
        let message: [String: Any] = ["content": "x 【1†L2-L3】", "executed_tools": [
            ["type": "browser_search", "arguments": #"{"query":"q"}"#,
             "search_results": ["results": [["title": "T", "url": "https://g.example/r"]]]],
            ["type": "python"],
        ]]
        let evidence = ProviderSearchEvidence.chatMessage(message, provider: .groq)
        XCTAssertEqual(evidence.searchCount, 1)
        XCTAssertEqual(evidence.queries, ["q"])
        XCTAssertEqual(evidence.sources.map(\.url), ["https://g.example/r"])
    }

    // MARK: - Gemini

    /// Shape: aistudio.google.com/api-reference/generate-content — `groundingMetadata` with
    /// `webSearchQueries`, `groundingChunks[].web {uri,title}`, `groundingSupports[]` and
    /// `searchEntryPoint {renderedContent, sdkBlob}`.
    func testGeminiGroundingSourcesInCitedOrderAndSuggestions() {
        let blob = Data(#"[["airport shops hours","https://www.google.com/search?q=airport+shops+hours"]]"#.utf8).base64EncodedString()
        let candidate = json(#"""
        {"content":{"parts":[{"text":"Open until 9."}]},
         "groundingMetadata":{
          "webSearchQueries":["airport shops hours"],
          "groundingChunks":[{"web":{"uri":"https://vertexaisearch.cloud.google.com/grounding-api-redirect/AAA","title":"airport.example"}},
                             {"web":{"uri":"https://vertexaisearch.cloud.google.com/grounding-api-redirect/BBB","title":"news.example"}}],
          "groundingSupports":[{"segment":{"startIndex":0,"endIndex":13,"text":"Open until 9."},"groundingChunkIndices":[1,0]}],
          "searchEntryPoint":{"renderedContent":"<div class=\"chip\"><a href=\"https://www.google.com/search?q=airport+shops+hours\">airport shops hours</a></div>","sdkBlob":"\#(blob)"}}}
        """#)
        let evidence = ProviderSearchEvidence.gemini(candidate: candidate)
        XCTAssertEqual(evidence.queries, ["airport shops hours"])
        XCTAssertEqual(evidence.sources.map(\.title), ["news.example", "airport.example"], "the order the answer cites")
        XCTAssertTrue(evidence.sources.first?.url.contains("grounding-api-redirect") == true, "kept as given")
        let suggestions = try! XCTUnwrap(evidence.searchSuggestions)
        XCTAssertTrue(suggestions.renderedContent.hasPrefix("<div class=\"chip\">"), "byte for byte")
        XCTAssertEqual(suggestions.queries, ["airport shops hours"])
        XCTAssertEqual(suggestions.links, [.init(query: "airport shops hours",
                                                 url: "https://www.google.com/search?q=airport+shops+hours")])
        XCTAssertNil(ProviderSearchEvidence.gemini(candidate: ["content": [:]]).searchSuggestions)
    }

    func testSuggestionLinksReadLeniently() {
        XCTAssertEqual(SearchSuggestions.links(fromSDKBlob: nil), [])
        XCTAssertEqual(SearchSuggestions.links(fromSDKBlob: "not base64"), [])
        let objects = Data(#"[{"query":"a","url":"https://www.google.com/search?q=a"},{"query":"b","url":"javascript:alert(1)"}]"#.utf8).base64EncodedString()
        XCTAssertEqual(SearchSuggestions.links(fromSDKBlob: objects).map(\.query), ["a"], "only web addresses")
    }

    // MARK: - Our own tool, bounds, the trace text

    func testOurToolsSourcesLineBecomesTheSameList() {
        let result = "The store closes at 6.\n\nSources: [1] https://hardware.example/hours, [2] https://maps.example/x"
        XCTAssertEqual(ProviderSearchEvidence.ourToolSources(fromResult: result).map(\.url),
                       ["https://hardware.example/hours", "https://maps.example/x"])
        XCTAssertEqual(ProviderSearchEvidence.ourToolSources(fromResult: result).first?.provider, "avenkin")
        XCTAssertEqual(ProviderSearchEvidence.ourToolSources(fromResult: "No results."), [])
    }

    func testEvidenceIsBounded() {
        var evidence = ProviderSearchEvidence()
        for index in 0..<20 {
            evidence.addQuery(String(repeating: "q\(index)", count: 200))
            evidence.addSource(WebSource(title: "t", url: "https://e.example/\(index)", provider: "anthropic"))
        }
        evidence.addSource(WebSource(title: "t", url: "file:///etc/passwd", provider: "anthropic"))
        XCTAssertEqual(evidence.queries.count, ProviderSearchEvidence.maxQueries)
        XCTAssertTrue(evidence.queries.allSatisfy { $0.count <= ProviderSearchEvidence.queryLimit })
        XCTAssertEqual(evidence.sources.count, ProviderSearchEvidence.maxSources)
        XCTAssertFalse(evidence.sources.contains { $0.url.hasPrefix("file:") })
    }

    func testTraceTextNamesPagesAndErrorsNotTheSuggestionsSnippet() {
        var evidence = ProviderSearchEvidence()
        evidence.searchCount = 2
        evidence.errors = ["too_many_requests"]
        evidence.addSource(WebSource(title: "Shops", url: "https://airport.example/shops", provider: "gemini"))
        evidence.searchSuggestions = SearchSuggestions(renderedContent: "<div>SNIPPET</div>")
        let text = evidence.traceText
        XCTAssertTrue(text.contains("searches: 2"))
        XCTAssertTrue(text.contains("errors: too_many_requests"))
        XCTAssertTrue(text.contains("Shops — https://airport.example/shops"))
        XCTAssertFalse(text.contains("SNIPPET"))
    }
}
