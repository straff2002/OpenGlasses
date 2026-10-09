import UIKit
import XCTest
@testable import OpenGlasses

/// Plan IE P2 — thinking blocks are whole within a turn and gone after it. The pure pieces first
/// (the strip, the prefix guard), then the real streamed tool loop over a recording transport:
/// what was streamed is what is sent back, signature included; the next turn carries none of it;
/// and a prefix that changes mid-loop drops the blocks rather than replaying them.
@MainActor
final class AnthropicThinkingReplayTests: XCTestCase {

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
                                     apiKey: "test", model: "claude-sonnet-5-5", baseURL: "")

    // MARK: - Fixtures

    /// The blocks the fixture stream below describes, as they must be stored and sent back.
    private let streamedBlocks: [[String: Any]] = [
        ["type": "thinking", "thinking": "Let me check.", "signature": "signature-fixture-one"],
        ["type": "redacted_thinking", "data": "opaque-fixture"],
        ["type": "tool_use", "id": "tu_1", "name": "get_weather", "input": ["city": "Auckland"]],
    ]

    /// A streamed turn that thinks (in two deltas, then its signature), carries a redacted block,
    /// and calls a tool.
    private let thinkingToolTurn = #"""
    data: {"type":"message_start","message":{}}

    data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}

    data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Let me "}}

    data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"check."}}

    data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"signature-fixture-one"}}

    data: {"type":"content_block_stop","index":0}

    data: {"type":"content_block_start","index":1,"content_block":{"type":"redacted_thinking","data":"opaque-fixture"}}

    data: {"type":"content_block_stop","index":1}

    data: {"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"tu_1","name":"get_weather","input":{}}}

    data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"city\":\"Auckland\"}"}}

    data: {"type":"content_block_stop","index":2}

    data: {"type":"message_delta","delta":{"stop_reason":"tool_use"}}

    data: {"type":"message_stop"}

    """#

    private let finalTurn = #"""
    data: {"type":"message_start","message":{}}

    data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}

    data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"signature-fixture-two"}}

    data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}

    data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"It is sunny."}}

    data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}

    data: {"type":"message_stop"}

    """#

    private func messages(inRequest index: Int, file: StaticString = #filePath, line: UInt = #line) throws -> [[String: Any]] {
        let requests = RecordingQueueProtocol.requests
        XCTAssertGreaterThan(requests.count, index, "request \(index) was sent", file: file, line: line)
        return try XCTUnwrap(requests[index].json?["messages"] as? [[String: Any]], file: file, line: line)
    }

    private func blocks(of message: [String: Any]) -> [[String: Any]] {
        message["content"] as? [[String: Any]] ?? []
    }

    private func thinkingBlockCount(_ messages: [[String: Any]]) -> Int {
        messages.flatMap(blocks).filter {
            let type = $0["type"] as? String
            return type == "thinking" || type == "redacted_thinking"
        }.count
    }

    private func equal(_ lhs: [[String: Any]], _ rhs: [[String: Any]]) -> Bool {
        (lhs as NSArray).isEqual(to: rhs)
    }

    private func jpeg() -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
        return renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }.jpegData(compressionQuality: 0.8)!
    }

    // MARK: - Defect B: the stream

    func testStreamAssemblesThinkingTextAndSignatureAndPassesRedactedThrough() async throws {
        RecordingQueueProtocol.queue = [(200, thinkingToolTurn)]
        var tokens = ""
        let (content, stopReason) = try await service().streamAnthropicContent(
            request: URLRequest(url: URL(string: "https://api.test/v1")!), model: "m") { tokens += $0 }

        XCTAssertEqual(stopReason, "tool_use")
        XCTAssertTrue(equal(content, streamedBlocks), "\(content)")
        XCTAssertEqual(tokens, "", "thinking is not the reply: none of it reaches the token sink")
    }

    func testThinkingDeltasNeverReachTheTokenSink() async throws {
        RecordingQueueProtocol.queue = [(200, finalTurn)]
        var tokens: [String] = []
        let (content, _) = try await service().streamAnthropicContent(
            request: URLRequest(url: URL(string: "https://api.test/v1")!), model: "m") { tokens.append($0) }
        XCTAssertEqual(tokens, ["It is sunny."])
        XCTAssertEqual(content.first?["signature"] as? String, "signature-fixture-two")
        XCTAssertEqual(content.first?["thinking"] as? String, "", "an omitted block keeps its empty text")
    }

    // MARK: - Within a turn: replayed exactly as received

    func testStreamedToolLoopReplaysTheAssistantMessageExactlyAsStreamed() async throws {
        RecordingQueueProtocol.queue = [(200, thinkingToolTurn), (200, finalTurn)]
        let svc = service()
        let reply = try await svc.sendAnthropic("what's the weather", systemPrompt: "sys", volatileTail: "tail",
                                                config: config, includeTools: true, imageData: nil,
                                                onToken: { _ in })
        XCTAssertEqual(reply, "It is sunny.")
        XCTAssertEqual(RecordingQueueProtocol.requests.count, 2)

        let second = try messages(inRequest: 1)
        XCTAssertEqual(second.map { $0["role"] as? String }, ["user", "assistant", "user"])
        XCTAssertTrue(equal(blocks(of: second[1]), streamedBlocks),
                      "sent back: \(blocks(of: second[1]))")
        XCTAssertEqual(blocks(of: second[1]).first?["signature"] as? String, "signature-fixture-one")
        XCTAssertEqual(blocks(of: second[2]).first?["tool_use_id"] as? String, "tu_1")

        // Everything the first request sent is sent again unchanged ahead of the new messages.
        let first = try messages(inRequest: 0)
        XCTAssertTrue(equal(Array(second.prefix(first.count)), first))
        let firstBody = try XCTUnwrap(RecordingQueueProtocol.requests[0].json)
        let secondBody = try XCTUnwrap(RecordingQueueProtocol.requests[1].json)
        let firstSystem = try XCTUnwrap(firstBody["system"] as? [[String: Any]])
        let secondSystem = try XCTUnwrap(secondBody["system"] as? [[String: Any]])
        XCTAssertTrue(equal(firstSystem, secondSystem))
        let firstTools = try XCTUnwrap(firstBody["tools"] as? [[String: Any]])
        let secondTools = try XCTUnwrap(secondBody["tools"] as? [[String: Any]])
        XCTAssertTrue(equal(firstTools, secondTools))
    }

    // MARK: - Across turns: gone

    func testTheNextTurnCarriesNoThinkingBlock() async throws {
        RecordingQueueProtocol.queue = [(200, thinkingToolTurn), (200, finalTurn), (200, finalTurn)]
        let svc = service()
        _ = try await svc.sendAnthropic("what's the weather", systemPrompt: "sys", config: config,
                                        includeTools: true, imageData: nil, onToken: { _ in })
        XCTAssertEqual(thinkingBlockCount(try messages(inRequest: 1)), 2, "within the turn they ride")

        _ = try await svc.sendAnthropic("and tomorrow?", systemPrompt: "sys", config: config,
                                        includeTools: true, imageData: nil, onToken: { _ in })
        let third = try messages(inRequest: 2)
        XCTAssertEqual(thinkingBlockCount(third), 0)
        // The exchange itself is all still there: the call, its result, the answer, the new turn.
        XCTAssertEqual(third.map { $0["role"] as? String }, ["user", "assistant", "user", "assistant", "user"])
        XCTAssertEqual(blocks(of: third[1]).map { $0["type"] as? String }, ["tool_use"])
        XCTAssertEqual(third[3]["content"] as? String, "It is sunny.")
        XCTAssertFalse(HistoryHygiene.containsThinking(svc.rawConversationHistoryForTesting()))
    }

    /// A turn that died after its tool call leaves the blocks in the history. The next turn —
    /// here on another model — must not send them.
    func testAnAbandonedTurnsBlocksDoNotReachTheNextTurnOrAnotherModel() async throws {
        // A 400 rather than a 5xx, so the streaming retry does not sit in its backoff.
        RecordingQueueProtocol.queue = [(200, thinkingToolTurn), (400, #"{"type":"error","error":{"type":"invalid_request_error","message":"fixture"}}"#)]
        let svc = service()
        do {
            _ = try await svc.sendAnthropic("what's the weather", systemPrompt: "sys", config: config,
                                            includeTools: true, imageData: nil, onToken: { _ in })
            XCTFail("the second request fails")
        } catch {}
        XCTAssertTrue(HistoryHygiene.containsThinking(svc.rawConversationHistoryForTesting()),
                      "the abandoned turn left its blocks behind")

        RecordingQueueProtocol.reset()
        RecordingQueueProtocol.queue = [(200, #"{"content":[{"type":"text","text":"Fine."}],"stop_reason":"end_turn"}"#)]
        var other = config
        other.model = "claude-opus-5-5"
        _ = try await svc.sendAnthropic("never mind", systemPrompt: "sys", config: other,
                                        includeTools: true, imageData: nil)
        XCTAssertEqual(thinkingBlockCount(try messages(inRequest: 0)), 0)
    }

    // MARK: - A prefix that changes mid-loop

    /// The turn carries a photo. Once the model has answered from it the request copy stops
    /// resending it, so the first message of the second request is not the one the thinking
    /// block was produced over — and the block is dropped, not replayed.
    func testAMidLoopPrefixChangeDropsTheBlocksInsteadOfReplayingThem() async throws {
        RecordingQueueProtocol.queue = [(200, thinkingToolTurn), (200, thinkingToolTurn), (200, finalTurn)]
        let svc = service()
        let reply = try await svc.sendAnthropic("what is this?", systemPrompt: "sys", config: config,
                                                includeTools: true, imageData: jpeg(), onToken: { _ in })
        XCTAssertEqual(reply, "It is sunny.")
        XCTAssertEqual(RecordingQueueProtocol.requests.count, 3)

        let first = try messages(inRequest: 0)
        let second = try messages(inRequest: 1)
        XCTAssertTrue(blocks(of: first[0]).contains { $0["type"] as? String == "image" }, "the photo went once")
        XCTAssertFalse(blocks(of: second[0]).contains { $0["type"] as? String == "image" }, "and was not resent")
        XCTAssertEqual(thinkingBlockCount(second), 0, "the prefix changed, so nothing is replayed")
        XCTAssertEqual(blocks(of: second[1]).map { $0["type"] as? String }, ["tool_use"],
                       "the call itself is kept, and so is its result")
        XCTAssertEqual(blocks(of: second[2]).first?["tool_use_id"] as? String, "tu_1")

        // From there the prefix is stable again: the second round trip's blocks were produced
        // over exactly what the third request sends ahead of them, so they ride.
        let third = try messages(inRequest: 2)
        XCTAssertTrue(equal(Array(third.prefix(second.count)), second))
        XCTAssertEqual(thinkingBlockCount(third), 2)
        XCTAssertTrue(equal(blocks(of: third[3]), streamedBlocks))
    }

    // MARK: - The strip (pure)

    func testStripRemovesThinkingAndKeepsEverythingElseInOrder() {
        let history: [[String: Any]] = [
            ["role": "user", "content": "hello"],
            ["role": "assistant", "content": streamedBlocks],
            ["role": "user", "content": [["type": "tool_result", "tool_use_id": "tu_1", "content": "18 degrees"]]],
            ["role": "assistant", "content": [["type": "thinking", "thinking": "", "signature": "s"],
                                              ["type": "text", "text": "It is 18 degrees."]]],
            ["role": "assistant", "content": "plain"],
        ]
        XCTAssertTrue(HistoryHygiene.containsThinking(history))
        let stripped = HistoryHygiene.stripThinkingBlocks(history)

        XCTAssertFalse(HistoryHygiene.containsThinking(stripped))
        XCTAssertEqual(stripped.count, history.count, "no message is removed")
        XCTAssertEqual(stripped[0]["content"] as? String, "hello")
        XCTAssertTrue(equal(blocks(of: stripped[1]), [streamedBlocks[2]]))
        XCTAssertTrue(equal(blocks(of: stripped[2]), blocks(of: history[2])))
        XCTAssertEqual(blocks(of: stripped[3]).map { $0["type"] as? String }, ["text"])
        XCTAssertEqual(stripped[4]["content"] as? String, "plain")
        XCTAssertTrue(equal(HistoryHygiene.stripThinkingBlocks(stripped), stripped), "idempotent")
    }

    func testStripNeverLeavesAnAssistantMessageEmpty() {
        let history: [[String: Any]] = [
            ["role": "assistant", "content": [["type": "thinking", "thinking": "", "signature": "s"],
                                              ["type": "redacted_thinking", "data": "opaque-fixture"]]],
        ]
        let stripped = HistoryHygiene.stripThinkingBlocks(history)
        XCTAssertEqual(blocks(of: stripped[0]).count, 1)
        XCTAssertEqual(blocks(of: stripped[0]).first?["type"] as? String, "text")
        XCTAssertEqual(blocks(of: stripped[0]).first?["text"] as? String, HistoryHygiene.omittedThinkingPlaceholder)
    }

    func testStripLeavesAHistoryWithoutThinkingUntouched() {
        let history: [[String: Any]] = [
            ["role": "user", "content": "hello"],
            ["role": "assistant", "content": [["type": "text", "text": "hi"]]],
            ["role": "model", "parts": [["text": "another provider's shape"]]],
        ]
        XCTAssertFalse(HistoryHygiene.containsThinking(history))
        XCTAssertTrue(equal(HistoryHygiene.stripThinkingBlocks(history), history))
    }

    // MARK: - The prefix guard (pure)

    func testPrefixGuard() {
        let system: [[String: Any]] = [["type": "text", "text": "head", "cache_control": ["type": "ephemeral"]],
                                       ["type": "text", "text": "tail"]]
        let tools: [[String: Any]] = [["name": "get_weather", "input_schema": ["type": "object"]]]
        let sentMessages: [[String: Any]] = [["role": "user", "content": "one"],
                                             ["role": "assistant", "content": "two"],
                                             ["role": "user", "content": "three"]]
        let sent = ThinkingReplayGuard.record(system: system, tools: tools, messages: sentMessages)
        XCTAssertEqual(sent.messageCount, 3)

        let grown = sentMessages + ([["role": "assistant", "content": streamedBlocks],
                                     ["role": "user", "content": "four"]] as [[String: Any]])
        XCTAssertTrue(ThinkingReplayGuard.prefixUnchanged(since: sent, system: system, tools: tools, messages: grown))
        XCTAssertTrue(ThinkingReplayGuard.prefixUnchanged(since: sent, system: system, tools: tools, messages: sentMessages))

        // The system text: the omission note or the dated tail moved.
        var otherSystem = system
        otherSystem[1]["text"] = "tail, later"
        XCTAssertFalse(ThinkingReplayGuard.prefixUnchanged(since: sent, system: otherSystem, tools: tools, messages: grown))
        // The tools.
        XCTAssertFalse(ThinkingReplayGuard.prefixUnchanged(since: sent, system: system, tools: [], messages: grown))
        // An earlier message rewritten in place.
        var edited = grown
        edited[0]["content"] = "one, edited"
        XCTAssertFalse(ThinkingReplayGuard.prefixUnchanged(since: sent, system: system, tools: tools, messages: edited))
        // An earlier message dropped by the budget: what sits in the span is no longer what was sent.
        XCTAssertFalse(ThinkingReplayGuard.prefixUnchanged(since: sent, system: system, tools: tools,
                                                           messages: Array(grown.dropFirst())))
        // Fewer messages than were sent.
        XCTAssertFalse(ThinkingReplayGuard.prefixUnchanged(since: sent, system: system, tools: tools,
                                                           messages: Array(sentMessages.prefix(2))))
        // The digest is a hash: it holds none of the text.
        XCTAssertFalse(sent.digest.contains("head"))
        XCTAssertEqual(sent.digest.count, 64)
    }
}
