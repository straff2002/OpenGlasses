import XCTest
@testable import OpenGlasses

/// Plan GB P5 — the cacheable prefix. Two turns that differ in time, memory, location, image and
/// manual passages must share the stable head byte for byte; the volatile tail goes after the
/// history; tools and request JSON are byte-stable.
@MainActor
final class PromptPrefixStabilityTests: XCTestCase {

    func testStableHeadIsByteIdenticalAcrossTurns() async {
        let first = await LLMService.promptLayoutForTesting(
            locationContext: "Wellington", memoryContext: "partner = Alex",
            hasImage: false, turn: "what's the supply air spec")
        let second = await LLMService.promptLayoutForTesting(
            locationContext: "Lower Hutt", memoryContext: "partner = Alex; likes tea",
            hasImage: true, turn: "reading 0.28 on the manometer")
        XCTAssertEqual(Array(first.stable.utf8), Array(second.stable.utf8))
        XCTAssertNotEqual(first.volatile, second.volatile)
    }

    func testVolatileBlocksLiveInTheTail() async {
        let layout = await LLMService.promptLayoutForTesting(
            locationContext: "Wellington", memoryContext: "partner = Alex", hasImage: true)
        XCTAssertFalse(layout.stable.contains("CURRENT DATE & TIME"))
        XCTAssertFalse(layout.stable.contains("USER LOCATION"))
        XCTAssertFalse(layout.stable.contains("VISION INPUT"))
        XCTAssertTrue(layout.volatile.contains("CURRENT DATE & TIME"))
        XCTAssertTrue(layout.volatile.contains("USER LOCATION: Wellington"))
        // The safety policy is stable and rejoins the head.
        XCTAssertTrue(layout.stable.hasSuffix(PromptInjectionPolicy.systemPromptPolicy))
        XCTAssertFalse(layout.volatile.contains(PromptInjectionPolicy.systemPromptPolicy))
    }

    func testCombinedKeepsEveryBlockHeadFirst() async {
        let layout = await LLMService.promptLayoutForTesting(locationContext: "Wellington")
        XCTAssertEqual(layout.combined, layout.stable + layout.volatile)
        XCTAssertTrue(layout.combined.contains("USER LOCATION: Wellington"))
    }

    func testSplitHandlesEdges() {
        let policy = "\n\nPOLICY"
        let layout = PromptLayout.split("HEAD" + "\n\nDATE: now" + policy, stableHeadBytes: 4, trailingStable: policy)
        XCTAssertEqual(layout.stable, "HEAD" + policy)
        XCTAssertEqual(layout.volatile, "\n\nDATE: now")
        let noTail = PromptLayout.split("HEAD" + policy, stableHeadBytes: 4, trailingStable: policy)
        XCTAssertEqual(noTail.volatile, "")
        XCTAssertEqual(noTail.stable, "HEAD" + policy)
    }

    // MARK: - Request shapes

    func testChatMessagesPutTheVolatileTailAfterHistory() {
        let history: [[String: Any]] = [["role": "user", "content": "hi"],
                                        ["role": "assistant", "content": "hello"],
                                        ["role": "user", "content": "now"]]
        let messages = PromptLayout.chatMessages(stable: "HEAD", history: history, volatile: "\n\nDATE: 10:41")
        XCTAssertEqual(messages.count, 5)
        XCTAssertEqual(messages.first?["content"] as? String, "HEAD")
        XCTAssertEqual(messages.last?["role"] as? String, "system")
        XCTAssertEqual(messages.last?["content"] as? String, "DATE: 10:41")
        // Two turns: the prefix up to the new history is identical.
        let next = PromptLayout.chatMessages(stable: "HEAD", history: history + [["role": "assistant", "content": "x"]],
                                             volatile: "\n\nDATE: 10:42")
        for index in 0..<history.count + 1 {
            XCTAssertEqual(NSDictionary(dictionary: messages[index]), NSDictionary(dictionary: next[index]))
        }
        XCTAssertEqual(PromptLayout.chatMessages(stable: "HEAD", history: history, volatile: "  ").count, 4)
        XCTAssertEqual(PromptLayout.chatMessages(stable: "HEAD", history: history, volatile: nil).count, 4)
    }

    func testAnthropicBreakpointSitsOnTheUntimestampedHead() {
        let blocks = PromptLayout.anthropicSystem(stable: "HEAD", volatile: "\n\nDATE: now")
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0]["text"] as? String, "HEAD")
        XCTAssertNotNil(blocks[0]["cache_control"])
        XCTAssertNil(blocks[1]["cache_control"])
        XCTAssertEqual(PromptLayout.anthropicSystem(stable: "HEAD", volatile: nil).count, 1)
    }

    func testCacheKeyIsStableAndContentFree() {
        let tools = Data(#"[{"a":1}]"#.utf8)
        let a = PromptPrefixDigest.cacheKey(model: "gpt-5.5", stable: "HEAD", tools: tools)
        XCTAssertEqual(a, PromptPrefixDigest.cacheKey(model: "gpt-5.5", stable: "HEAD", tools: tools))
        XCTAssertNotEqual(a, PromptPrefixDigest.cacheKey(model: "gpt-6-sol", stable: "HEAD", tools: tools))
        XCTAssertNotEqual(a, PromptPrefixDigest.cacheKey(model: "gpt-5.5", stable: "HEAD2", tools: tools))
        XCTAssertTrue(a.hasPrefix("og-"))
        XCTAssertEqual(a.count, 35)
        XCTAssertFalse(a.contains("HEAD"))
    }

    func testSortedKeysMakeEqualBodiesByteIdentical() throws {
        var one: [String: Any] = [:]
        for key in ["model", "messages", "max_tokens", "tools", "stream", "reasoning_effort"] { one[key] = key }
        var two: [String: Any] = [:]
        for key in ["reasoning_effort", "stream", "tools", "max_tokens", "messages", "model"] { two[key] = key }
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: one, options: [.sortedKeys]),
                       try JSONSerialization.data(withJSONObject: two, options: [.sortedKeys]))
    }

    func testRequestBuildersSortKeysAndSendTheCacheKey() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OpenGlasses/Sources/Services/LLMService.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(source.contains(#"body["prompt_cache_key"] = PromptPrefixDigest.cacheKey("#))
        XCTAssertTrue(source.contains("PromptLayout.chatMessages(stable: system.stable, history: historySlice"))
        XCTAssertTrue(source.contains("PromptLayout.anthropicSystem(stable: system.stable, volatile: system.volatile)"))
        XCTAssertGreaterThanOrEqual(source.components(separatedBy: "withJSONObject: body, options: [.sortedKeys]").count - 1, 3)
    }

    // MARK: - Tool guidance

    func testToolDescriptionsDropWhenSchemasAreAttached() {
        for provider in [LLMProvider.anthropic, .openai, .gemini, .chatgpt] {
            XCTAssertTrue(LLMService.toolSchemasAttached(provider: provider, customEndpointRejectsTools: false), "\(provider)")
        }
        XCTAssertTrue(LLMService.toolSchemasAttached(provider: .custom, customEndpointRejectsTools: false))
        XCTAssertFalse(LLMService.toolSchemasAttached(provider: .custom, customEndpointRejectsTools: true))
        XCTAssertFalse(LLMService.toolSchemasAttached(provider: .local, customEndpointRejectsTools: false))
    }

    func testDeclaredToolNamesAreSorted() {
        XCTAssertEqual(ToolDeclarations.declarableNames(["web_search", "capture_photo", "get_weather"],
                                                        isEnabled: { _ in true }, hipaaMode: false, hipaaDisabled: []),
                       ["capture_photo", "get_weather", "web_search"])
    }
}
