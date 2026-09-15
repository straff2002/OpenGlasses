import XCTest
@testable import OpenGlasses

/// Mistral rides the shared OpenAI-compatible request builder, but its request schema is closed:
/// a field it doesn't define is a 422, not an ignored extra. `applyMistralRequestShape` is the
/// one place that bends the shared body to fit, so these pin both halves — what it removes for
/// Mistral, and that no other provider's request changes.
final class MistralRequestShapeTests: XCTestCase {

    private func streamedBody() -> [String: Any] {
        [
            "model": "mistral-medium-latest",
            "max_tokens": 1024,
            "messages": [["role": "user", "content": "hi"]],
            "tools": [["type": "function", "function": ["name": "t", "description": "", "parameters": [:]]]],
            "stream": true,
            "stream_options": ["include_usage": true],
        ]
    }

    func testMistralDropsStreamOptionsAndKeepsEverythingElse() {
        var body = streamedBody()
        LLMService.applyMistralRequestShape(to: &body, provider: .mistral)
        XCTAssertNil(body["stream_options"])
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["model"] as? String, "mistral-medium-latest")
        XCTAssertEqual(body["max_tokens"] as? Int, 1024)
        XCTAssertNotNil(body["messages"])
        XCTAssertNotNil(body["tools"])
        XCTAssertEqual(Set(body.keys), ["model", "max_tokens", "messages", "tools", "stream"])
    }

    func testANonStreamedMistralBodyIsUntouched() {
        var body: [String: Any] = ["model": "mistral-small-latest", "messages": [], "max_tokens": 10]
        LLMService.applyMistralRequestShape(to: &body, provider: .mistral)
        XCTAssertEqual(Set(body.keys), ["model", "messages", "max_tokens"])
    }

    /// Every other provider keeps asking for the final usage chunk — the streamed cost record
    /// depends on it for OpenAI and friends.
    func testOtherProvidersKeepStreamOptions() {
        for provider in LLMProvider.allCases where provider != .mistral {
            var body = streamedBody()
            LLMService.applyMistralRequestShape(to: &body, provider: provider)
            XCTAssertEqual((body["stream_options"] as? [String: Bool])?["include_usage"], true,
                           provider.rawValue)
        }
    }

    // MARK: - Tool-call ids

    private static let openAIStyleID = "call_Xy12AbCdEfGhIjKlMnOpQrSt"

    /// A turn that started on another provider: the parser's `call_0` fallback, a long OpenAI id,
    /// and one id that is already in Mistral's shape.
    private func mixedHistory() -> [[String: Any]] {
        [
            ["role": "user", "content": "What's on my calendar and what's the weather?"],
            ["role": "assistant", "content": NSNull(), "tool_calls": [
                ["id": "call_0", "type": "function", "function": ["name": "calendar", "arguments": "{}"]],
                ["id": Self.openAIStyleID, "type": "function", "function": ["name": "weather", "arguments": "{}"]],
            ]],
            ["role": "tool", "tool_call_id": "call_0", "content": "Dentist at 3pm"],
            ["role": "tool", "tool_call_id": Self.openAIStyleID, "content": "Sunny"],
            ["role": "assistant", "content": "", "tool_calls": [
                ["id": "D681PevKs", "type": "function", "function": ["name": "time", "arguments": "{}"]],
            ]],
            ["role": "tool", "tool_call_id": "D681PevKs", "content": "14:02"],
            ["role": "assistant", "content": "Dentist at 3, sunny."],
        ]
    }

    private func assistantIDs(_ messages: [[String: Any]]) -> [String] {
        messages.flatMap { ($0["tool_calls"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String } }
    }

    private func toolMessageIDs(_ messages: [[String: Any]]) -> [String] {
        messages.filter { $0["role"] as? String == "tool" }.compactMap { $0["tool_call_id"] as? String }
    }

    private func mistralBody(_ messages: [[String: Any]], provider: LLMProvider = .mistral) -> [[String: Any]] {
        var body: [String: Any] = ["model": "mistral-small-2506", "messages": messages]
        LLMService.applyMistralRequestShape(to: &body, provider: provider)
        return body["messages"] as? [[String: Any]] ?? []
    }

    func testForeignIDsBecomeNineAlphanumericsAndStayPaired() {
        let history = mixedHistory()
        let out = mistralBody(history)

        let calls = assistantIDs(out)
        XCTAssertEqual(calls.count, 3)
        for id in calls + toolMessageIDs(out) {
            XCTAssertNotNil(id.range(of: "^[a-zA-Z0-9]{9}$", options: .regularExpression), id)
        }
        // Each tool message still answers the call it answered before.
        XCTAssertEqual(calls, toolMessageIDs(out))
        XCTAssertEqual(Set(calls).count, 3, "two foreign ids collapsed onto one")
        XCTAssertNotEqual(calls[0], "call_0")
        XCTAssertNotEqual(calls[1], Self.openAIStyleID)
        // The outgoing body is a copy: the stored history keeps its original ids.
        XCTAssertEqual(assistantIDs(history), ["call_0", Self.openAIStyleID, "D681PevKs"])
    }

    func testAnAlreadyValidIDIsUnchanged() {
        let out = mistralBody(mixedHistory())
        XCTAssertEqual(assistantIDs(out)[2], "D681PevKs")
        XCTAssertEqual(toolMessageIDs(out)[2], "D681PevKs")

        let onlyValid: [[String: Any]] = [
            ["role": "assistant", "content": NSNull(), "tool_calls": [
                ["id": "abc123XYZ", "type": "function", "function": ["name": "t", "arguments": "{}"]]]],
            ["role": "tool", "tool_call_id": "abc123XYZ", "content": "ok"],
        ]
        XCTAssertTrue(NSArray(array: mistralBody(onlyValid)).isEqual(to: onlyValid))
    }

    func testNormalisationIsDeterministicAndIdempotent() {
        let first = mistralBody(mixedHistory())
        let second = mistralBody(mixedHistory())
        XCTAssertTrue(NSArray(array: first).isEqual(to: second))
        XCTAssertTrue(NSArray(array: mistralBody(first)).isEqual(to: first))
    }

    /// A derived id that happens to equal an id already in the request is re-derived, so two
    /// different calls never end up sharing one.
    func testADerivedIDNeverTakesAnIDAlreadyInTheRequest() {
        let taken = LLMService.mistralToolCallID(deriving: "call_0", salt: 0)
        let history: [[String: Any]] = [
            ["role": "assistant", "content": NSNull(), "tool_calls": [
                ["id": taken, "type": "function", "function": ["name": "a", "arguments": "{}"]],
                ["id": "call_0", "type": "function", "function": ["name": "b", "arguments": "{}"]]]],
            ["role": "tool", "tool_call_id": taken, "content": "a"],
            ["role": "tool", "tool_call_id": "call_0", "content": "b"],
        ]
        let out = mistralBody(history)
        let calls = assistantIDs(out)
        XCTAssertEqual(calls[0], taken)
        XCTAssertNotEqual(calls[1], taken)
        XCTAssertTrue(LLMService.isMistralToolCallID(calls[1]))
        XCTAssertEqual(calls, toolMessageIDs(out))
    }

    func testOtherProvidersKeepTheirToolCallIDs() {
        let history = mixedHistory()
        for provider in LLMProvider.allCases where provider != .mistral {
            XCTAssertTrue(NSArray(array: mistralBody(history, provider: provider)).isEqual(to: history),
                          provider.rawValue)
        }
    }

    func testMessagesWithoutToolCallsAreUnchanged() {
        let history = mixedHistory()
        let out = mistralBody(history)
        XCTAssertEqual(out.count, history.count)
        for index in [0, 6] {
            XCTAssertTrue(NSDictionary(dictionary: out[index]).isEqual(to: history[index]), "message \(index)")
        }
        let plain: [[String: Any]] = [["role": "system", "content": "s"], ["role": "user", "content": "u"]]
        XCTAssertTrue(NSArray(array: mistralBody(plain)).isEqual(to: plain))
    }

    /// Usage still reaches the tracker without the opt-in: Mistral's stream chunks carry `usage`.
    func testMistralStyleUsageChunkIsRecorded() {
        var usage = StreamingUsageAccumulator()
        usage.consumeOpenAI([
            "id": "x", "model": "mistral-medium-latest",
            "choices": [["index": 0, "delta": ["content": ""], "finish_reason": "stop"]],
            "usage": ["prompt_tokens": 12, "completion_tokens": 5, "total_tokens": 17],
        ])
        XCTAssertEqual(usage.tokensIn, 12)
        XCTAssertEqual(usage.tokensOut, 5)
    }
}
