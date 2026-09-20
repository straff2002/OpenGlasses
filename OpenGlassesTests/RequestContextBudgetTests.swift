import XCTest
@testable import OpenGlasses

final class RequestContextBudgetTests: XCTestCase {
    private let endpoint = "https://chatgpt.com/backend-api/codex/responses"

    func testEndpointModelAndValidatedCatalogResolution() {
        XCTAssertEqual(RequestContextBudget.resolve(model: "gpt-5.5", endpoint: endpoint).context, 272_000)
        XCTAssertEqual(RequestContextBudget.resolve(model: "unknown", endpoint: endpoint).context, 32_768)
        XCTAssertEqual(RequestContextBudget.resolve(model: "gpt-5.5", endpoint: "https://custom.test/responses", catalogContext: 400_000).context, 32_768)
        XCTAssertEqual(RequestContextBudget.resolve(model: "unknown", endpoint: endpoint, catalogContext: 64_000).context, 64_000)
        XCTAssertEqual(RequestContextBudget.resolve(model: "unknown", endpoint: endpoint, catalogContext: -1).context, 32_768)
        XCTAssertLessThan(RequestContextBudget.resolve(model: "gpt-5.5", endpoint: endpoint).inputAllowance, 272_000)
    }

    func testInstructionsAndSchemasForceCompactionWithOnlyThreeMessages() throws {
        let history: [[String: Any]] = [
            ["role": "user", "content": String(repeating: "old", count: 1_000)],
            ["role": "assistant", "content": "old answer"],
            ["role": "user", "content": "current question"],
        ]
        let tools: [[String: Any]] = [["type": "function", "function": ["name": "lookup", "description": String(repeating: "schema", count: 100), "parameters": ["type": "object"]]]]
        let result = try RequestContextBudget.build(model: "unknown", instructions: String(repeating: "policy", count: 150), history: history, tools: tools, protectedStart: 2, allowance: 2_500)
        XCTAssertEqual(result.omittedMessages, 2)
        XCTAssertGreaterThan(result.estimate.tools, 600)
        XCTAssertLessThanOrEqual(result.estimate.total, 2_500)
        XCTAssertEqual(history.count, 3)
        XCTAssertEqual((result.body["input"] as? [[String: Any]])?.count, 1)
    }

    func testCurrentQuestionInstructionsAndHugeToolAreNeverClipped() {
        let huge = String(repeating: "X", count: 10_000)
        XCTAssertThrowsError(try RequestContextBudget.build(model: "m", instructions: huge,
            history: [["role": "user", "content": "hi"]], tools: nil, protectedStart: 0, allowance: 2_000))
        XCTAssertThrowsError(try RequestContextBudget.build(model: "m", instructions: "policy",
            history: [["role": "user", "content": huge]], tools: nil, protectedStart: 0, allowance: 2_000))
        XCTAssertThrowsError(try RequestContextBudget.build(model: "m", instructions: "policy",
            history: toolExchange(result: huge), tools: nil, protectedStart: 0, allowance: 2_000))
    }

    func testOldToolExchangeRemovedAtomicallyCurrentResultPreserved() throws {
        let old = toolExchange(result: String(repeating: "old data", count: 1_000))
        let current = toolExchange(result: "record saved, evidence id 42")
        let result = try RequestContextBudget.build(model: "m", instructions: "equipment X", history: old + current,
            tools: nil, protectedStart: old.count, allowance: 2_000)
        let input = try XCTUnwrap(result.body["input"] as? [[String: Any]])
        XCTAssertEqual(input.filter { $0["type"] as? String == "function_call" }.count, 1)
        XCTAssertEqual(input.filter { $0["type"] as? String == "function_call_output" }.count, 1)
        XCTAssertEqual(input.last?["output"] as? String, "record saved, evidence id 42")
    }

    func testHistoricalImagesOmittedWithoutChangingAttachmentsOrCurrentPhoto() throws {
        let photo: [String: Any] = ["role": "user", "content": [
            ["type": "text", "text": "nameplate"],
            ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + String(repeating: "A", count: 20_000)]],
        ]]
        let history = Array(repeating: photo, count: 8)
        let result = try RequestContextBudget.build(model: "m", instructions: "policy", history: history,
            tools: nil, protectedStart: 7, allowance: 12_000)
        XCTAssertEqual(result.omittedMessages, 0)
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: result.body), as: UTF8.self)
        XCTAssertEqual(encoded.components(separatedBy: "input_image").count - 1, 1)
        XCTAssertGreaterThan(RequestContextBudget.estimate(ResponsesTranslator.requestBody(
            model: "m", instructions: "policy", history: history, tools: nil)).total, 12_000)
        XCTAssertLessThan(result.estimate.total, 12_000)
    }

    func testHundredTurnsProduceBoundedRequestsAndRetainFreshState() throws {
        var history: [[String: Any]] = []
        var compactions = 0
        for turn in 0..<100 {
            let boundary = history.count
            history.append(["role": "user", "content": "Turn \(turn): " + String(repeating: "readout ", count: 80)])
            let snapshot = "Active equipment ABC; fuse reported good; corrected reading 24 V; next pending step \(turn)."
            let selected = try RequestContextBudget.build(model: "m", instructions: snapshot, history: history,
                tools: nil, protectedStart: boundary, allowance: 4_000)
            XCTAssertLessThanOrEqual(selected.estimate.total, 4_000)
            XCTAssertTrue((selected.body["instructions"] as? String)?.contains(snapshot) == true)
            if selected.omittedMessages > 0 { compactions += 1 }
            history.append(["role": "assistant", "content": "Please check the next connection."])
        }
        XCTAssertGreaterThan(compactions, 90)
        XCTAssertEqual(history.count, 200)
    }

    func testOverflowClassificationDoesNotConfuseAuthQuotaOrOther400s() {
        XCTAssertTrue(RequestContextBudget.isOverflow(code: "context_length_exceeded", message: "arbitrary localized message"))
        XCTAssertFalse(RequestContextBudget.isOverflow(code: "insufficient_quota", message: "maximum context length"))
        XCTAssertFalse(RequestContextBudget.isOverflow(error: LLMError.apiError(provider: "ChatGPT", statusCode: 401, message: "Exceeded model context window size")))
        XCTAssertFalse(RequestContextBudget.isOverflow(error: LLMError.apiError(provider: "ChatGPT", statusCode: 400, message: "Invalid tool schema")))
        XCTAssertTrue(RequestContextBudget.isOverflow(error: LLMError.apiError(provider: "ChatGPT", statusCode: 400, message: #"{"error":{"code":"context_length_exceeded","message":"too big"}}"#)))
    }

    private func toolExchange(result: String) -> [[String: Any]] {
        [["role": "user", "content": "record it"],
         ["role": "assistant", "content": "", "tool_calls": [["id": "c", "type": "function", "function": ["name": "record", "arguments": "{}"]]]],
         ["role": "tool", "tool_call_id": "c", "content": result]]
    }
}

@MainActor
final class ResponsesContextRecoveryTests: XCTestCase {
    override func setUp() {
        super.setUp()
        SSEQueueProtocol.queue = []
    }

    func testStructuredStreamOverflowPreservedWithoutEnglishMessage() async {
        SSEQueueProtocol.queue = [(200, "data: {\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"context_length_exceeded\",\"message\":\"too big\"}}}\n\n")]
        let service = LLMService()
        service.streamingSession = SSEQueueProtocol.session()
        do {
            _ = try await service.streamResponsesTurn(request: URLRequest(url: URL(string: "https://test.invalid")!), onToken: nil)
            XCTFail("expected error")
        } catch { XCTAssertTrue(RequestContextBudget.isOverflow(error: error)) }
    }

    func testRetriesOnlyFailedRequestPreservingCompletedToolPairAndOneUserTurn() async throws {
        let service = LLMService()
        service.streamingSession = SSEQueueProtocol.session()
        SSEQueueProtocol.queue = [
            (400, #"{"error":{"code":"context_length_exceeded","message":"too large"}}"#),
            (200, "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"recovered\",\"output\":[]}}\n\n"),
        ]
        let recovery = LLMService.ResponsesContextRecovery()
        let history: [[String: Any]] = [
            ["role": "user", "content": String(repeating: "old", count: 1_000)],
            ["role": "assistant", "content": "old answer"],
            ["role": "user", "content": "save measurement"],
            ["role": "assistant", "content": "", "tool_calls": [["id": "saved", "function": ["name": "record", "arguments": "{}"]]]],
            ["role": "tool", "tool_call_id": "saved", "content": "saved 24 V"],
        ]
        var resets = 0
        let result = try await service.budgetedResponsesTurn(request: URLRequest(url: URL(string: "https://test.invalid")!),
            model: "m", history: history, tools: nil, protectedStart: 2,
            limit: .init(context: 32_768, provenance: "fixture"), recovery: recovery,
            instructions: { "equipment ABC" }, onToken: nil, onStreamReset: { resets += 1 })
        XCTAssertEqual(result["id"] as? String, "recovered")
        XCTAssertTrue(recovery.attempted)
        XCTAssertTrue(SSEQueueProtocol.queue.isEmpty)
        XCTAssertGreaterThanOrEqual(resets, 2)
        XCTAssertEqual(history.count, 5)
        let rebuilt = try RequestContextBudget.build(model: "m", instructions: "equipment ABC", history: history,
            tools: nil, protectedStart: 2, allowance: try XCTUnwrap(recovery.allowance))
        let items = try XCTUnwrap(rebuilt.body["input"] as? [[String: Any]])
        XCTAssertEqual(items.filter { $0["role"] as? String == "user" }.count, 1)
        XCTAssertEqual(items.filter { $0["type"] as? String == "function_call" }.count, 1)
        XCTAssertEqual(items.last?["output"] as? String, "saved 24 V")
    }

    func testSecondOverflowExitsAndSharedRecoveryNeverRetriesNextToolRequest() async {
        let service = LLMService()
        service.streamingSession = SSEQueueProtocol.session()
        let error = #"{"error":{"code":"context_length_exceeded","message":"too large"}}"#
        SSEQueueProtocol.queue = [(400, error), (400, error), (400, error)]
        let recovery = LLMService.ResponsesContextRecovery()
        let history: [[String: Any]] = [["role": "user", "content": String(repeating: "old", count: 1_000)], ["role": "user", "content": "now"]]
        for _ in 0..<2 {
            do {
                _ = try await service.budgetedResponsesTurn(request: URLRequest(url: URL(string: "https://test.invalid")!),
                    model: "m", history: history, tools: nil, protectedStart: 1,
                    limit: .init(context: 32_768, provenance: "fixture"), recovery: recovery,
                    instructions: { "policy" }, onToken: nil, onStreamReset: nil)
                XCTFail("expected overflow")
            } catch { XCTAssertTrue(RequestContextBudget.isOverflow(error: error)) }
        }
        XCTAssertTrue(SSEQueueProtocol.queue.isEmpty)
    }

    func testFieldInstructionsReplaceOrRemoveStaleEquipment() {
        let original = "Safety rules\n<field_assist_context>old equipment</field_assist_context>\nother instructions"
        let changed = LLMService.replacingFieldInstructions(original, fresh: "new equipment; current step 3")
        XCTAssertFalse(changed.contains("old equipment"))
        XCTAssertTrue(changed.contains("Safety rules"))
        XCTAssertTrue(changed.contains("current step 3"))
        XCTAssertFalse(LLMService.replacingFieldInstructions(changed, fresh: nil).contains("new equipment"))
    }

    func testCatalogCannotCarryAcrossAccountsOrAnonymousSignIn() {
        let data = Data(#"{"models":[{"slug":"test","context_window":64000}]}"#.utf8)
        ChatGPTContextCatalog.update(data: data, accountID: "account-a")
        XCTAssertEqual(ChatGPTContextCatalog.context(model: "test", accountID: "account-a"), 64_000)
        XCTAssertNil(ChatGPTContextCatalog.context(model: "test", accountID: "account-b"))
        ChatGPTContextCatalog.update(data: data, accountID: nil)
        XCTAssertNil(ChatGPTContextCatalog.context(model: "test", accountID: nil))
        XCTAssertNil(ChatGPTContextCatalog.context(model: "test", accountID: "account-a"))
    }

    func testOverflowAfterDispatchDoesNotExecuteActionAgain() async throws {
        let service = LLMService()
        service.streamingSession = SSEQueueProtocol.session()
        SSEQueueProtocol.queue = [
            (200, "data: {\"type\":\"response.completed\",\"response\":{\"output\":[{\"type\":\"function_call\",\"call_id\":\"save\",\"name\":\"record\",\"arguments\":\"{}\"}]}}\n\n"),
            (400, #"{"error":{"code":"context_length_exceeded","message":"too large"}}"#),
            (200, "data: {\"type\":\"response.completed\",\"response\":{\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"Saved 24 V\"}]}]}}\n\n"),
        ]
        var history: [[String: Any]] = [
            ["role": "user", "content": String(repeating: "historical ", count: 1_000)],
            ["role": "assistant", "content": "old answer"],
            ["role": "user", "content": "Save my reading"],
        ]
        var executions = 0
        let recovery = LLMService.ResponsesContextRecovery()
        let adapter = ProviderLoopAdapter(label: "ChatGPT",
            dispatcher: .init(execute: { _, _, _, _ in executions += 1; return .completed("saved 24 V") }, onStatus: { _ in }),
            performTurn: {
                let response = try await service.budgetedResponsesTurn(
                    request: URLRequest(url: URL(string: "https://test.invalid")!), model: "m", history: history,
                    tools: nil, protectedStart: 2, limit: .init(context: 32_768, provenance: "fixture"),
                    recovery: recovery, instructions: { "Active equipment ABC" }, onToken: nil, onStreamReset: nil)
                let parsed = ResponsesTranslator.parseOutput(response)
                return AssistantTurn(text: parsed.text, toolCalls: parsed.toolCalls)
            }, appendAssistantToolCall: { turn in
                history.append(ResponsesTranslator.assistantHistoryMessage(text: turn.text, toolCalls: turn.toolCalls))
            }, appendToolResults: { outcomes in
                for result in outcomes {
                    history.append(["role": "tool", "tool_call_id": result.invocation.id ?? "", "content": "saved 24 V"])
                }
            }, finalize: { $0.text })
        let result = try await runToolLoop(maxIterations: 5, adapter: adapter, setStatus: { _ in })
        XCTAssertEqual(result, "Saved 24 V")
        XCTAssertEqual(executions, 1)
        XCTAssertTrue(recovery.attempted)
        XCTAssertEqual(history.filter { $0["role"] as? String == "tool" }.count, 1)
        XCTAssertTrue(SSEQueueProtocol.queue.isEmpty)
        XCTAssertEqual(ModelFallbackChain.classify(RequestContextBudget.CapacityError()), .terminalForTurn)
        XCTAssertEqual(ModelFallbackChain.classify(LLMError.apiError(provider: "ChatGPT", statusCode: 200,
            message: #"{"code":"context_length_exceeded","message":"too big"}"#)), .terminalForTurn)
    }
}
