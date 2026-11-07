import UIKit
import XCTest
@testable import OpenGlasses

/// A conversation that changes provider mid-way sends a history the new provider accepts. The
/// owner's 2026-11-07 Field Assist turn: a ChatGPT turn ran `manual_lookup`, the next question took
/// a glasses frame, the photo turn went to the Vision model on Anthropic, and the ChatGPT turn's
/// `role: "tool"` result was sent raw — `400 messages: Unexpected role "tool"`. The pure converter
/// first, then the real request bodies over a recording transport, both directions.
@MainActor
final class CrossProviderHistoryTests: XCTestCase {

    override func setUp() {
        super.setUp()
        RecordingQueueProtocol.reset()
    }

    override func tearDown() {
        RecordingQueueProtocol.reset()
        super.tearDown()
    }

    // MARK: - Fixtures

    /// The history a ChatGPT Field Assist turn leaves: the question, the assistant's tool call as
    /// the ChatGPT path writes it, the tool's result, and the answer.
    private func chatGPTToolTurn(callID: String = "call_8fK2") -> [[String: Any]] {
        [
            ["role": "user", "content": "What is the Q99 on this unit"],
            ResponsesTranslator.assistantHistoryMessage(
                text: "", toolCalls: [ToolInvocation(id: callID, name: "manual_lookup",
                                                     arguments: ["query": "Q99 error"],
                                                     rawArguments: #"{"query":"Q99 error"}"#)]),
            ["role": "tool", "tool_call_id": callID, "content": "<tool_result>Q99: fixture fault text</tool_result>"],
            ["role": "assistant", "content": "Q99 is the fixture fault."],
        ]
    }

    /// The same exchange as the Anthropic path writes it.
    private func anthropicToolTurn() -> [[String: Any]] {
        [
            ["role": "user", "content": "What does Q99 mean?"],
            ["role": "assistant", "content": [
                ["type": "text", "text": "Checking the manual."],
                ["type": "tool_use", "id": "toolu_01A", "name": "manual_lookup", "input": ["query": "Q99"]],
            ]],
            ["role": "user", "content": [
                ["type": "tool_result", "tool_use_id": "toolu_01A", "content": "Q99: fixture fault text"],
            ]],
            ["role": "assistant", "content": "Q99 is the fixture fault."],
        ]
    }

    private func roles(_ history: [[String: Any]]) -> [String] {
        history.map { $0["role"] as? String ?? "?" }
    }

    private func blocks(_ message: [String: Any]) -> [[String: Any]] {
        message["content"] as? [[String: Any]] ?? []
    }

    /// Every Anthropic `tool_use` is answered, in the very next message (a user message), by a
    /// `tool_result` with its id, results first; no result answers an id that was not called; only
    /// the three roles Anthropic takes; no OpenAI or Gemini keys.
    private func assertValidAnthropic(_ messages: [[String: Any]], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(Set(roles(messages)).isSubset(of: ["user", "assistant", "system"]),
                      "roles: \(roles(messages))", file: file, line: line)
        for (index, message) in messages.enumerated() {
            XCTAssertNil(message["tool_calls"], "no tool_calls at \(index)", file: file, line: line)
            XCTAssertNil(message["tool_call_id"], "no tool_call_id at \(index)", file: file, line: line)
            XCTAssertNil(message["parts"], "no parts at \(index)", file: file, line: line)
            if let text = message["content"] as? String {
                XCTAssertFalse(text.trimmingCharacters(in: .whitespaces).isEmpty, "empty at \(index)", file: file, line: line)
            }
            for block in blocks(message) {
                XCTAssertNotEqual(block["type"] as? String, "image_url", file: file, line: line)
            }
            let uses = blocks(message).filter { $0["type"] as? String == "tool_use" }.compactMap { $0["id"] as? String }
            let results = blocks(message).filter { $0["type"] as? String == "tool_result" }
            if !results.isEmpty {
                XCTAssertEqual(message["role"] as? String, "user", file: file, line: line)
                let firstNonResult = blocks(message).firstIndex { $0["type"] as? String != "tool_result" } ?? results.count
                XCTAssertEqual(firstNonResult, results.count, "results come first at \(index)", file: file, line: line)
                let called = index > 0
                    ? blocks(messages[index - 1]).filter { $0["type"] as? String == "tool_use" }.compactMap { $0["id"] as? String }
                    : []
                for result in results {
                    XCTAssertTrue(called.contains(result["tool_use_id"] as? String ?? ""),
                                  "result \(result["tool_use_id"] ?? "") at \(index) answers a call before it",
                                  file: file, line: line)
                }
            }
            guard !uses.isEmpty else { continue }
            XCTAssertEqual(message["role"] as? String, "assistant", file: file, line: line)
            for id in uses {
                XCTAssertTrue(id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }, id, file: file, line: line)
            }
            XCTAssertLessThan(index + 1, messages.count, "a result follows \(index)", file: file, line: line)
            guard index + 1 < messages.count else { continue }
            let answered = blocks(messages[index + 1]).filter { $0["type"] as? String == "tool_result" }
                .compactMap { $0["tool_use_id"] as? String }
            XCTAssertEqual(Set(answered), Set(uses), "every call at \(index) answered", file: file, line: line)
        }
    }

    /// Every assistant `tool_calls` is answered by `tool` messages for each id before the next
    /// assistant or plain user message; no `tool` message answers an id that was not called; no
    /// Anthropic or Gemini shapes.
    private func assertValidOpenAIChat(_ messages: [[String: Any]], file: StaticString = #filePath, line: UInt = #line) {
        var open: Set<String> = []
        for (index, message) in messages.enumerated() {
            XCTAssertNil(message["parts"], file: file, line: line)
            for block in blocks(message) {
                XCTAssertTrue(["text", "image_url"].contains(block["type"] as? String ?? ""),
                              "block \(block["type"] ?? "") at \(index)", file: file, line: line)
            }
            let role = message["role"] as? String
            if role == "tool" {
                let id = message["tool_call_id"] as? String ?? ""
                XCTAssertTrue(open.remove(id) != nil, "tool \(id) at \(index) answers an open call", file: file, line: line)
                continue
            }
            if role == "assistant" || (role == "user" && message["content"] is String) {
                XCTAssertTrue(open.isEmpty, "unanswered \(open) before \(index)", file: file, line: line)
                open = []
            }
            if role == "assistant", let calls = message["tool_calls"] as? [[String: Any]] {
                for call in calls {
                    open.insert(call["id"] as? String ?? "")
                    let arguments = (call["function"] as? [String: Any])?["arguments"] as? String ?? ""
                    XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(arguments.utf8)),
                                    "arguments are a JSON string", file: file, line: line)
                }
            }
        }
        XCTAssertTrue(open.isEmpty, "unanswered at the end: \(open)", file: file, line: line)
    }

    // MARK: - OpenAI chat shape → Anthropic

    func testTheReportedChatGPTHistoryBecomesAValidAnthropicHistory() {
        let history = chatGPTToolTurn() + [["role": "user", "content": "Look in the vault for a Q99 error"]]
        let (converted, count) = CrossProviderHistory.normalised(history, for: .anthropic)

        XCTAssertEqual(count, 2, "the assistant's call and the tool message")
        assertValidAnthropic(converted)
        XCTAssertEqual(roles(converted), ["user", "assistant", "user", "assistant", "user"])
        let call = blocks(converted[1])
        XCTAssertEqual(call.map { $0["type"] as? String }, ["tool_use"], "no empty text block")
        XCTAssertEqual(call.first?["id"] as? String, "call_8fK2")
        XCTAssertEqual(call.first?["name"] as? String, "manual_lookup")
        XCTAssertEqual((call.first?["input"] as? [String: Any])?["query"] as? String, "Q99 error",
                       "arguments arrive as an object")
        let result = blocks(converted[2])
        XCTAssertEqual(result.first?["tool_use_id"] as? String, "call_8fK2")
        XCTAssertEqual(result.first?["content"] as? String, "<tool_result>Q99: fixture fault text</tool_result>")
        // The messages Anthropic reads as they are, are sent as they are.
        XCTAssertEqual(converted[0]["content"] as? String, "What is the Q99 on this unit")
        XCTAssertEqual(converted[3]["content"] as? String, "Q99 is the fixture fault.")
    }

    func testTwoResultsOfOneChatTurnLandInOneUserMessageWithTheToolPhotoInside() {
        let photo = "data:image/jpeg;base64,AAAA"
        let history: [[String: Any]] = [
            ["role": "user", "content": "Check the pressure and take a picture"],
            ["role": "assistant", "content": "Let me check.", "tool_calls": [
                ["id": "call_a", "type": "function", "function": ["name": "manual_lookup", "arguments": "{}"]],
                ["id": "call_b", "type": "function", "function": ["name": "look_closely", "arguments": #"{"reason":"gauge"}"#]],
            ]],
            ["role": "tool", "tool_call_id": "call_a", "content": "Nominal 99 units."],
            ["role": "tool", "tool_call_id": "call_b", "content": "Photo taken."],
            ["role": "user", "content": [
                ["type": "text", "text": ToolResultImage.attachmentCaption(toolName: "look_closely")],
                ["type": "image_url", "image_url": ["url": photo]],
            ]],
            ["role": "assistant", "content": "It reads 98 units."],
        ]
        let converted = CrossProviderHistory.normalisedHistory(history, for: .anthropic)
        assertValidAnthropic(converted)
        XCTAssertEqual(roles(converted), ["user", "assistant", "user", "assistant"])
        XCTAssertEqual(blocks(converted[1]).map { $0["type"] as? String }, ["text", "tool_use", "tool_use"])
        let results = blocks(converted[2])
        XCTAssertEqual(results.compactMap { $0["tool_use_id"] as? String }, ["call_a", "call_b"])
        let withPhoto = results[1]["content"] as? [[String: Any]] ?? []
        XCTAssertEqual(withPhoto.map { $0["type"] as? String }, ["text", "image"], "the photo rides inside its result")
        XCTAssertEqual((withPhoto.last?["source"] as? [String: Any])?["data"] as? String, "AAAA")
    }

    func testAnUnansweredCallGetsTheInterruptedResultAndAnOrphanResultBecomesText() {
        let history: [[String: Any]] = [
            ["role": "user", "content": "q"],
            ["role": "assistant", "content": "", "tool_calls": [
                ["id": "call_x", "type": "function", "function": ["name": "manual_lookup", "arguments": "{}"]],
            ]],
            ["role": "user", "content": "next"],
            // A result whose call the budget left out of this request.
            ["role": "tool", "tool_call_id": "call_gone", "content": "old result"],
            ["role": "assistant", "content": "ok"],
        ]
        let converted = CrossProviderHistory.normalisedHistory(history, for: .anthropic)
        assertValidAnthropic(converted)
        XCTAssertEqual(blocks(converted[2]).first?["content"] as? String, HistoryHygiene.interruptedToolResult)
        let orphan = converted.first { ($0["content"] as? String)?.contains("old result") == true }
        XCTAssertEqual(orphan?["role"] as? String, "user")
        XCTAssertFalse(converted.contains { ($0["content"] as? [[String: Any]])?.contains {
            $0["tool_use_id"] as? String == "call_gone" } == true })
    }

    func testIdsAnthropicWouldRefuseAreRewrittenTheSameWayForCallAndResult() {
        let history: [[String: Any]] = [
            ["role": "user", "content": "q"],
            ["role": "assistant", "content": "", "tool_calls": [
                ["id": "call.1:a", "type": "function", "function": ["name": "t", "arguments": "{}"]],
                ["id": "", "type": "function", "function": ["name": "u", "arguments": "not json"]],
            ]],
            ["role": "tool", "tool_call_id": "call.1:a", "content": "one"],
            ["role": "tool", "tool_call_id": "", "content": "two"],
        ]
        let converted = CrossProviderHistory.normalisedHistory(history, for: .anthropic)
        assertValidAnthropic(converted)
        let uses = blocks(converted[1])
        XCTAssertEqual(uses.first?["id"] as? String, "call_1_a")
        XCTAssertEqual((uses.last?["input"] as? [String: Any])?["arguments"] as? String, "not json",
                       "arguments that are not an object are kept, under a key")
        let results = blocks(converted[2])
        XCTAssertEqual(results.map { $0["content"] as? String }, ["one", "two"])
        XCTAssertEqual(results.last?["tool_use_id"] as? String, uses.last?["id"] as? String,
                       "a result with no id answers the call with none, by position")
    }

    func testAnEmptyChatGPTReplyIsNotSentToAnthropic() {
        let history: [[String: Any]] = [
            ["role": "user", "content": "q"], ["role": "assistant", "content": ""], ["role": "user", "content": "again"],
        ]
        let converted = CrossProviderHistory.normalisedHistory(history, for: .anthropic)
        assertValidAnthropic(converted)
        XCTAssertEqual(roles(converted), ["user", "user"])
    }

    func testResponsesReplayItemsNeverReachAnthropic() {
        var message = ResponsesTranslator.assistantHistoryMessage(text: "Noon.", toolCalls: [],
                                                                  rawOutputItems: [["type": "reasoning"]])
        message["role"] = "assistant"
        let converted = CrossProviderHistory.normalisedHistory([["role": "user", "content": "q"], message], for: .anthropic)
        XCTAssertNil(converted[1][ResponsesTranslator.rawOutputItemsKey])
        XCTAssertEqual(converted[1]["content"] as? String, "Noon.")
    }

    // MARK: - Anthropic → OpenAI chat shape and the Responses input

    func testAnAnthropicHistoryBecomesAValidChatHistory() {
        let history = anthropicToolTurn() + [["role": "user", "content": "and Q98?"]]
        let (converted, count) = CrossProviderHistory.normalised(history, for: .openAIChat)
        XCTAssertEqual(count, 2)
        assertValidOpenAIChat(converted)
        XCTAssertEqual(roles(converted), ["user", "assistant", "tool", "assistant", "user"])
        XCTAssertEqual(converted[1]["content"] as? String, "Checking the manual.")
        let call = (converted[1]["tool_calls"] as? [[String: Any]])?.first
        XCTAssertEqual(call?["id"] as? String, "toolu_01A")
        XCTAssertEqual((call?["function"] as? [String: Any])?["arguments"] as? String, #"{"query":"Q99"}"#)
        XCTAssertEqual(converted[2]["tool_call_id"] as? String, "toolu_01A")
        XCTAssertEqual(converted[2]["content"] as? String, "Q99: fixture fault text")
    }

    func testAnAnthropicPhotoAndAToolResultPhotoBecomeImageURLs() {
        let history: [[String: Any]] = [
            ["role": "user", "content": [
                ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": "QkJC"]],
                ["type": "text", "text": "what is this?"],
            ]],
            ["role": "assistant", "content": [["type": "tool_use", "id": "toolu_2", "name": "look_closely", "input": [:]]]],
            ["role": "user", "content": [["type": "tool_result", "tool_use_id": "toolu_2", "content": [
                ["type": "text", "text": "close-up"],
                ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": "Q0ND"]],
            ]]]],
            ["role": "assistant", "content": "A fixture part."],
        ]
        let converted = CrossProviderHistory.normalisedHistory(history, for: .openAIChat)
        assertValidOpenAIChat(converted)
        XCTAssertEqual(roles(converted), ["user", "assistant", "tool", "user", "assistant"])
        let photo = blocks(converted[0]).first { $0["type"] as? String == "image_url" }
        XCTAssertEqual((photo?["image_url"] as? [String: Any])?["url"] as? String, "data:image/jpeg;base64,QkJC")
        XCTAssertEqual(converted[2]["content"] as? String, "close-up")
        let toolPhoto = blocks(converted[3]).last
        XCTAssertEqual((toolPhoto?["image_url"] as? [String: Any])?["url"] as? String, "data:image/jpeg;base64,Q0ND")
    }

    func testTheChatGPTInputCarriesAnAnthropicExchangeAsACallAndItsOutput() {
        let items = ResponsesTranslator.inputItems(history: anthropicToolTurn())
        XCTAssertEqual(items.map { $0["type"] as? String }, ["message", "message", "function_call",
                                                             "function_call_output", "message"])
        XCTAssertEqual(items[2]["call_id"] as? String, "toolu_01A")
        XCTAssertEqual(items[2]["arguments"] as? String, #"{"query":"Q99"}"#)
        XCTAssertEqual(items[3]["call_id"] as? String, "toolu_01A")
        XCTAssertEqual(items[3]["output"] as? String, "Q99: fixture fault text")
        for item in items where item["type"] as? String == "message" {
            let content = item["content"] as? [[String: Any]] ?? []
            XCTAssertFalse(content.isEmpty, "no empty message")
            XCTAssertFalse(content.contains { ($0["text"] as? String)?.isEmpty == true }, "no empty text")
        }
    }

    func testAnAnthropicTextOnlyReplyReachesChatGPTAsText() {
        // What a finished Anthropic turn can leave once its thinking block is stripped.
        let history: [[String: Any]] = [
            ["role": "user", "content": "q"],
            ["role": "assistant", "content": [["type": "text", "text": "The fixture fault."]]],
        ]
        let items = ResponsesTranslator.inputItems(history: history)
        XCTAssertEqual(items.count, 2)
        let content = items.last?["content"] as? [[String: Any]]
        XCTAssertEqual(content?.first?["text"] as? String, "The fixture fault.")
    }

    // MARK: - Gemini

    func testAGeminiExchangeBecomesAnthropicAndChatExchanges() {
        let history: [[String: Any]] = [
            ["role": "user", "content": "q"],
            ["role": "assistant", "parts": [
                ["text": "Looking.", "thoughtSignature": "sig"],
                ["functionCall": ["name": "manual_lookup", "args": ["query": "Q99"], "id": "g1"]],
            ]],
            ["role": "function", "parts": [
                ["functionResponse": ["name": "manual_lookup", "id": "g1", "response": ["result": "fixture result"]]],
            ]],
            ["role": "assistant", "content": "The fixture result."],
        ]
        let anthropic = CrossProviderHistory.normalisedHistory(history, for: .anthropic)
        assertValidAnthropic(anthropic)
        XCTAssertEqual(blocks(anthropic[2]).first?["content"] as? String, "fixture result")
        let chat = CrossProviderHistory.normalisedHistory(history, for: .openAIChat)
        assertValidOpenAIChat(chat)
        XCTAssertEqual(roles(chat), ["user", "assistant", "tool", "assistant"])
    }

    func testAForeignExchangeReachesGeminiAsText() {
        let converted = CrossProviderHistory.normalisedHistory(chatGPTToolTurn(), for: .gemini)
        XCTAssertFalse(converted.contains { $0["role"] as? String == "tool" || $0["tool_calls"] != nil })
        let call = converted[1]["parts"] as? [[String: Any]]
        XCTAssertEqual(converted[1]["role"] as? String, "model")
        XCTAssertTrue((call?.first?["text"] as? String)?.contains("manual_lookup") == true)
        let result = converted[2]["parts"] as? [[String: Any]]
        XCTAssertEqual(converted[2]["role"] as? String, "user")
        XCTAssertTrue((result?.first?["text"] as? String)?.contains("Q99: fixture fault text") == true)
        XCTAssertTrue((result?.first?["text"] as? String)?.contains("manual_lookup") == true, "named by its call")
    }

    // MARK: - Native histories are untouched

    func testAHistoryAlreadyInTheTargetShapeIsReturnedExactly() {
        let anthropic = anthropicToolTurn()
        let sameAnthropic = CrossProviderHistory.normalised(anthropic, for: .anthropic)
        XCTAssertEqual(sameAnthropic.converted, 0)
        XCTAssertTrue((sameAnthropic.history as NSArray).isEqual(to: anthropic))

        let chat = chatGPTToolTurn()
        let sameChat = CrossProviderHistory.normalised(chat, for: .openAIChat)
        XCTAssertEqual(sameChat.converted, 0)
        XCTAssertTrue((sameChat.history as NSArray).isEqual(to: chat))
        XCTAssertTrue((ResponsesTranslator.inputItems(history: chat) as NSArray)
            .isEqual(to: ResponsesTranslator.inputItems(history: CrossProviderHistory.normalisedHistory(chat, for: .openAIChat))))

        let gemini: [[String: Any]] = [["role": "user", "content": "q"],
                                       ["role": "assistant", "parts": [["functionCall": ["name": "t", "args": [:]]]]],
                                       ["role": "function", "parts": [["functionResponse": ["name": "t", "response": [:]]]]]]
        XCTAssertEqual(CrossProviderHistory.normalised(gemini, for: .gemini).converted, 0)
    }

    func testConvertingTwiceChangesNothingMore() {
        let mixed = chatGPTToolTurn() + anthropicToolTurn()
        for shape in [CrossProviderHistory.Shape.anthropic, .openAIChat, .gemini] {
            let once = CrossProviderHistory.normalisedHistory(mixed, for: shape)
            let twice = CrossProviderHistory.normalised(once, for: shape)
            XCTAssertEqual(twice.converted, 0, "\(shape)")
        }
        assertValidAnthropic(CrossProviderHistory.normalisedHistory(mixed, for: .anthropic))
        assertValidOpenAIChat(CrossProviderHistory.normalisedHistory(mixed, for: .openAIChat))
    }

    func testEveryProviderHasTheShapeItsRequestIsBuiltIn() {
        XCTAssertEqual(CrossProviderHistory.shape(for: .anthropic), .anthropic)
        XCTAssertEqual(CrossProviderHistory.shape(for: .chatgpt), .openAIChat)
        XCTAssertEqual(CrossProviderHistory.shape(for: .openai), .openAIChat)
        XCTAssertEqual(CrossProviderHistory.shape(for: .mistral), .openAIChat)
        XCTAssertEqual(CrossProviderHistory.shape(for: .geminiVertex), .gemini)
        XCTAssertNil(CrossProviderHistory.shape(for: .local))
        XCTAssertNil(CrossProviderHistory.shape(for: .appleOnDevice))
    }

    // MARK: - The real request bodies

    private func service() -> LLMService {
        let s = LLMService()
        s.processingConsent = CloudConsentFixture.conversation()
        let session = RecordingQueueProtocol.session()
        s.streamingSession = session
        s.dataSession = session
        return s
    }

    private func jpeg() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.gray.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }.jpegData(compressionQuality: 0.8)!
    }

    private let anthropicAnswer =
        #"{"content":[{"type":"text","text":"Q99 is the fixture fault."}],"stop_reason":"end_turn","usage":{"input_tokens":10,"output_tokens":5}}"#

    func testTheVisionTurnOnAnthropicAfterAChatGPTToolTurnSendsNoToolRole() async throws {
        RecordingQueueProtocol.queue = [(200, anthropicAnswer)]
        let svc = service()
        svc.seedRawConversationHistoryForTesting(chatGPTToolTurn())
        let config = ModelConfig(id: "vision", name: "vision", provider: LLMProvider.anthropic.rawValue,
                                 apiKey: "test", model: "claude-sonnet-5-5", baseURL: "")
        let reply = try await svc.sendAnthropic("Look in the vault for a Q99 error and tell me what that is",
                                                systemPrompt: "sys", config: config, includeTools: false,
                                                imageData: jpeg())
        XCTAssertEqual(reply, "Q99 is the fixture fault.")

        let messages = try XCTUnwrap(RecordingQueueProtocol.requests.first?.json?["messages"] as? [[String: Any]])
        XCTAssertFalse(RecordingQueueProtocol.requests[0].bodyText.contains(#""role":"tool""#))
        assertValidAnthropic(messages)
        XCTAssertEqual(roles(messages), ["user", "assistant", "user", "assistant", "user"])
        // The stored history keeps the shape each turn was written in.
        XCTAssertEqual(svc.rawConversationHistoryForTesting()[2]["role"] as? String, "tool")
    }

    func testAChatCompletionsTurnAfterAnAnthropicToolTurnSendsNoAnthropicBlocks() async throws {
        RecordingQueueProtocol.queue = [(200, #"{"choices":[{"message":{"role":"assistant","content":"Fine."}}],"usage":{"prompt_tokens":10,"completion_tokens":2}}"#)]
        let svc = service()
        svc.seedRawConversationHistoryForTesting(anthropicToolTurn())
        let config = ModelConfig(id: "ds", name: "ds", provider: LLMProvider.deepseek.rawValue, apiKey: "test",
                                 model: "deepseek-chat", baseURL: "https://api.test/v1")
        _ = try await svc.sendOpenAICompatibleForTesting("and Q98?", config: config, includeTools: false)

        let body = try XCTUnwrap(RecordingQueueProtocol.requests.first)
        XCTAssertFalse(body.bodyText.contains("tool_use"))
        XCTAssertFalse(body.bodyText.contains("tool_result"))
        let messages = try XCTUnwrap(body.json?["messages"] as? [[String: Any]])
        assertValidOpenAIChat(messages.filter { $0["role"] as? String != "system" })
        XCTAssertEqual(roles(messages.filter { $0["role"] as? String != "system" }),
                       ["user", "assistant", "tool", "assistant", "user"])
    }
}
