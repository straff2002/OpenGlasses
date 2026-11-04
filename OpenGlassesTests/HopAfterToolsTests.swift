import XCTest
@testable import OpenGlasses

/// Plan KL P2: what a hop between models does once a tool has run in the turn — the rule, the
/// ledger the attempts write, the block a carried attempt sends, and the line a turn that ends says.
final class HopAfterToolsTests: XCTestCase {

    // MARK: - The rule

    func testTheRule() {
        XCTAssertEqual(HopAfterTools.decide(toolsRan: .none, overflow: false), .restart)
        XCTAssertEqual(HopAfterTools.decide(toolsRan: .none, overflow: true), .restart)
        XCTAssertEqual(HopAfterTools.decide(toolsRan: .readOnly, overflow: false), .carryForward)
        XCTAssertEqual(HopAfterTools.decide(toolsRan: .changedState, overflow: false), .endTurn)
        // An overflow after any tool keeps today's outcome: the turn ends.
        XCTAssertEqual(HopAfterTools.decide(toolsRan: .readOnly, overflow: true), .endTurn)
        XCTAssertEqual(HopAfterTools.decide(toolsRan: .changedState, overflow: true), .endTurn)
    }

    /// The two overflow rules moved under `HopAfterTools`; what they decide is what they decided.
    func testTheOverflowCasesAreUnchangedInOutcome() {
        XCTAssertEqual(ModelFallbackChain.classify(RequestContextBudget.CapacityError(toolsRanThisTurn: true)),
                       .terminalForTurn)
        XCTAssertEqual(ModelFallbackChain.classify(RequestContextBudget.CapacityError(toolsRanThisTurn: false)),
                       .retryOtherModel)
        XCTAssertEqual(ModelFallbackChain.classify(RequestContextBudget.CapacityError()), .terminalForTurn,
                       "the default still reads as a tool having run")
        XCTAssertEqual(ModelFallbackChain.classify(
            LLMError.contextOverflow(provider: "Apple Intelligence", toolsRan: true)), .terminalForTurn)
        XCTAssertEqual(ModelFallbackChain.classify(
            LLMError.contextOverflow(provider: "Apple Intelligence", toolsRan: false)), .retryOtherModel)
        let providerOverflow = LLMError.apiError(
            provider: "ChatGPT", statusCode: 400,
            message: #"{"error":{"code":"context_length_exceeded","message":"too long"}}"#)
        XCTAssertEqual(ModelFallbackChain.classify(providerOverflow), .terminalForTurn)

        XCTAssertTrue(HopAfterTools.isOverflow(RequestContextBudget.CapacityError(toolsRanThisTurn: false)))
        XCTAssertTrue(HopAfterTools.isOverflow(LLMError.contextOverflow(provider: "x", toolsRan: false)))
        XCTAssertTrue(HopAfterTools.isOverflow(providerOverflow))
        XCTAssertFalse(HopAfterTools.isOverflow(LLMError.invalidResponse("empty")))
        XCTAssertFalse(HopAfterTools.isOverflow(LocalLLMError.promptTooLong(tokens: 5_000, limit: 4_000)))
    }

    func testATurnThatEndedIsTerminalForTheTurn() {
        let ended = HopAfterTools.TurnEnded(tools: ["save note"],
                                            underlying: SafeErrorSummary(LLMError.invalidResponse("empty")))
        XCTAssertEqual(ModelFallbackChain.classify(ended), .terminalForTurn)
    }

    // MARK: - The ledger

    private func ledger(_ calls: [(String, ToolEffect, ToolExecutionOutcome?)]) -> AttemptToolLedger {
        var ledger = AttemptToolLedger()
        for (tool, effect, outcome) in calls {
            let id = ledger.dispatched(tool: tool, arguments: "{}", effect: effect)
            if let outcome { ledger.finished(id, outcome: outcome) }
        }
        return ledger
    }

    func testNothingRanIsNone() {
        XCTAssertEqual(AttemptToolLedger().toolsRan, .none)
        // Refused, or never reached: the router says nothing happened.
        let refused = ledger([("save_note", .localMutation, .rejected(reason: "declined")),
                              ("send_message", .externalMutation, .failedBeforeExecution(reason: "not declared"))])
        XCTAssertEqual(refused.toolsRan, .none)
        XCTAssertNil(refused.carriedBlock(limit: 8_000))
    }

    func testReadOnlyToolsAreReadOnly() {
        let reads = ledger([("get_weather", .readOnly, .completed("Sunny, 18°")),
                            ("get_datetime", .readOnly, .completed("Tuesday"))])
        XCTAssertEqual(reads.toolsRan, .readOnly)
        XCTAssertTrue(reads.changingTools.isEmpty)
    }

    func testAMixedLedgerIsAStateChange() {
        let mixed = ledger([("get_weather", .readOnly, .completed("Sunny")),
                            ("save_note", .localMutation, .completed("Saved")),
                            ("get_datetime", .readOnly, .completed("Tuesday"))])
        XCTAssertEqual(mixed.toolsRan, .changedState)
        XCTAssertEqual(mixed.changingTools, ["save_note"])
        XCTAssertEqual(HopAfterTools.decide(toolsRan: mixed.toolsRan, overflow: false), .endTurn)
        XCTAssertNil(mixed.carriedBlock(limit: 8_000), "a turn that does not hop carries nothing")
    }

    /// A tool that declares nothing about itself gets the conservative default, which writes.
    func testAnUnclassifiedToolCountsAsAStateChange() {
        struct Undeclared: NativeTool {
            let name = "undeclared_stub"
            let description = "declares nothing"
            var parametersSchema: [String: Any] { ["type": "object"] }
            func execute(args: [String: Any]) async throws -> String { "done" }
        }
        let effect = MainActor.assumeIsolated { Undeclared().executionSemantics.effect }
        XCTAssertEqual(effect, ToolExecutionSemantics.conservativeDefault.effect)
        let unclassified = ledger([("get_weather", .readOnly, .completed("Sunny")),
                                   ("undeclared_stub", effect, .completed("done"))])
        XCTAssertEqual(unclassified.toolsRan, .changedState)
        XCTAssertEqual(unclassified.changingTools, ["undeclared_stub"])
    }

    func testACallStillRunningOrUnresolvedCounts() {
        // Dispatched, no outcome yet: the attempt failed while it ran.
        let inFlight = ledger([("save_note", .localMutation, nil)])
        XCTAssertEqual(inFlight.toolsRan, .changedState)
        let unknown = ledger([("get_weather", .readOnly, .outcomeUnknown(operationID: "op", message: "still checking"))])
        XCTAssertEqual(unknown.toolsRan, .readOnly)
        XCTAssertNil(unknown.carriedBlock(limit: 8_000), "an unresolved read has no result to carry")
    }

    func testAResetKeepsIdsCounting() {
        var ledger = AttemptToolLedger()
        let first = ledger.dispatched(tool: "save_note", arguments: "{}", effect: .localMutation)
        ledger.reset()
        let second = ledger.dispatched(tool: "get_weather", arguments: "{}", effect: .readOnly)
        XCTAssertNotEqual(first, second)
        // The earlier turn's call finishing late never lands on this turn's entry.
        ledger.finished(first, outcome: .completed("late"))
        XCTAssertNil(ledger.calls.first?.result)
    }

    // MARK: - The carried block

    func testTheBlockNamesEachToolItsArgumentsAndItsResult() throws {
        var ledger = AttemptToolLedger()
        let weather = ledger.dispatched(tool: "get_weather", arguments: #"{"city":"Paris"}"#, effect: .readOnly)
        ledger.finished(weather, outcome: .completed("Sunny, 18 degrees"))
        let lookup = ledger.dispatched(tool: ToolLookupTool.toolName, arguments: "{}", effect: .readOnly)
        ledger.finished(lookup, outcome: .completed("definitions"))
        let again = ledger.dispatched(tool: "get_weather", arguments: #"{"city":"Paris"}"#, effect: .readOnly)
        ledger.finished(again, outcome: .completed("Sunny, 19 degrees"))

        let block = try XCTUnwrap(ledger.carriedBlock(limit: 8_000, excluding: [ToolLookupTool.toolName]))
        XCTAssertTrue(block.text.hasPrefix(AttemptToolLedger.header))
        XCTAssertTrue(block.text.contains("do not call these tools again"))
        XCTAssertTrue(block.text.contains(#"- get_weather {"city":"Paris"}: Sunny, 19 degrees"#),
                      "the latest of identical calls")
        XCTAssertFalse(block.text.contains("18 degrees"))
        XCTAssertFalse(block.text.contains("definitions"), "the lookup tool's output is not carried")
        XCTAssertEqual(block.carried, 1)
        XCTAssertEqual(block.omitted, 0)
    }

    func testTheBlockIsBoundedAndItsEnvelopeAlwaysCloses() throws {
        var ledger = AttemptToolLedger()
        for city in ["Paris", "Rome", "Oslo"] {
            let id = ledger.dispatched(tool: "web_search", arguments: #"{"query":"\#(city)"}"#, effect: .readOnly)
            ledger.finished(id, outcome: .completed(String(repeating: "\(city) ", count: 300)))
        }
        let wrap: (String, String) -> String = { PromptInjectionPolicy.wrap(toolName: $0, content: $1) }
        let block = try XCTUnwrap(ledger.carriedBlock(limit: 3_000, wrap: wrap))
        XCTAssertEqual(block.carried, 2, "one whole, one cut")
        XCTAssertEqual(block.cut, 1)
        XCTAssertEqual(block.omitted, 1)
        XCTAssertTrue(block.text.contains("[cut short to fit"))
        XCTAssertTrue(block.text.contains("1 more result did not fit"))
        XCTAssertFalse(block.text.contains("Oslo"))
        XCTAssertEqual(block.text.components(separatedBy: "</untrusted_tool_output>").count - 1, 2,
                       "every carried result closes its envelope")
        XCTAssertLessThanOrEqual(block.text.count, 3_000 + 120)

        // Room for nothing but the header: nothing is carried.
        XCTAssertNil(ledger.carriedBlock(limit: AttemptToolLedger.header.count + 50))
    }

    func testCapturedSizesAreBounded() {
        var ledger = AttemptToolLedger()
        let id = ledger.dispatched(tool: "web_search", arguments: String(repeating: "a", count: 5_000), effect: .readOnly)
        ledger.finished(id, outcome: .completed(String(repeating: "b", count: 50_000)))
        XCTAssertEqual(ledger.calls[0].arguments.count, HopAfterTools.capturedArgumentsLimit)
        XCTAssertEqual(ledger.calls[0].result?.count, HopAfterTools.capturedResultLimit)
    }

    func testCanonicalArguments() {
        XCTAssertEqual(AttemptToolLedger.canonicalArguments(["b": 1, "a": "x"]), #"{"a":"x","b":1}"#)
        XCTAssertEqual(AttemptToolLedger.canonicalArguments(json: #"{"b":1,"a":"x"}"#), #"{"a":"x","b":1}"#)
        XCTAssertEqual(AttemptToolLedger.canonicalArguments(json: ""), "{}")
    }

    // MARK: - What the turn says

    func testAStateChangingToolEndsTheTurnWithItsLine() {
        let one = HopAfterTools.TurnEnded(tools: ["save note"], underlying: SafeErrorSummary(LLMError.invalidResponse("x")))
        XCTAssertEqual(ModelSwitchNarrator.exhaustionPhrase(lastError: one),
                       "I couldn't get a response — save note had already run, so I didn't run it again on another model.")
        let two = HopAfterTools.TurnEnded(tools: ["save note", "set timer"], underlying: one.underlying)
        XCTAssertEqual(ModelSwitchNarrator.exhaustionReason(lastError: two),
                       "save note and set timer had already run, so I didn't run them again on another model")
        XCTAssertEqual(SpokenErrorPolicy.photoFailureLine(for: two, photoCaptured: true, narrateModelFailures: true),
                       "I took the photo, but couldn't get an answer about it — save note and set timer had already run, so I didn't run them again on another model.")
    }

    func testSpokenNames() {
        XCTAssertEqual(HopAfterTools.spokenToolName("save_note", isNative: true), "save note")
        XCTAssertEqual(HopAfterTools.spokenToolName("server__create_issue", isNative: false), "a connected tool")
        XCTAssertEqual(HopAfterTools.spokenList(["a", "b", "c", "d", "e"]), "a, b and 3 other tools")
        XCTAssertEqual(HopAfterTools.spokenList(["a", "b", "c"]), "a, b and c")
    }

    @MainActor func testTheSummaryAndTheBannerOfATurnThatEnded() {
        let ended = HopAfterTools.TurnEnded(tools: ["save note"],
                                            underlying: SafeErrorSummary(LLMError.apiError(provider: "Groq", statusCode: 503, message: nil)))
        let summary = SafeErrorSummary(ended)
        XCTAssertEqual(summary.description, "stoppedAfterTools(serverError)#503")
        XCTAssertEqual(AppState.plainReason(summary.description),
                       "the AI stopped after a tool had already done something, so it wasn't run again on another model")
    }

    // MARK: - The hop's log line

    /// Every hop's `cascadeSwitched` carries the error it was from, as its safe summary, next to
    /// the class — one representative error per class the chain hops on, and the turn-ending ones.
    func testTheLoggedErrorTokenForEachFailureClass() {
        let cases: [(Error, ModelFallbackChain.FailureClass, String)] = [
            (LLMError.invalidResponse("empty"), .retryOtherModel, "badServerResponse(invalidResponse)"),
            (LLMError.apiError(provider: "Groq", statusCode: 429, message: nil), .retryOtherModel, "rateLimited(http)#429"),
            (URLError(.timedOut), .retryOtherModel, "timedOut(URLError)#-1001"),
            (LocalLLMError.promptTooLong(tokens: 5_000, limit: 4_000), .needsBiggerWindow, "promptTooLong"),
            (LLMError.missingAPIKey("ChatGPT account not connected"), .terminalForCandidate, "unknown(missingAPIKey)"),
            (LLMError.modelDeclined(provider: "Claude"), .terminalForCandidate, "modelDeclined(refusal)"),
            (RequestContextBudget.CapacityError(toolsRanThisTurn: false), .retryOtherModel, "contextTooLarge(beforeTools)"),
            (LLMError.contextOverflow(provider: "Apple Intelligence", toolsRan: false), .retryOtherModel,
             "contextOverflow(beforeTools)"),
            (RequestContextBudget.CapacityError(toolsRanThisTurn: true), .terminalForTurn, "contextTooLarge(afterTools)"),
            (HopAfterTools.TurnEnded(tools: ["save note"], underlying: SafeErrorSummary(LLMError.invalidResponse("x"))),
             .terminalForTurn, "stoppedAfterTools(badServerResponse)"),
        ]
        for (error, failure, token) in cases {
            XCTAssertEqual(ModelFallbackChain.classify(error), failure, "\(error)")
            let line = PrivacyEventEncoder.encode(LLMService.logCascadeSwitch(to: "groq-b", failure: failure, error: error))
            XCTAssertTrue(line.contains("cascadeSwitched"), line)
            XCTAssertTrue(line.contains(PrivacyToken.caseName(of: failure)?.description ?? "?"), line)
            XCTAssertTrue(line.contains("error=\(SafeErrorSummary(error).description)"), line)
            XCTAssertTrue(SafeErrorSummary(error).description.contains(token), "\(SafeErrorSummary(error))")
            XCTAssertFalse(line.contains("ChatGPT account not connected"), "the error's sentence is never logged")
        }
        // The photo pre-switch threw nothing, and logs no error.
        let preSwitch = PrivacyEventEncoder.encode(LLMService.logCascadeSwitch(to: "claude", failure: .visionUnavailable,
                                                                              error: nil))
        XCTAssertTrue(preSwitch.contains("visionUnavailable"), preSwitch)
        XCTAssertFalse(preSwitch.contains("error="), preSwitch)
    }

    // MARK: - The chain

    private let chain = [
        ModelFallbackChain.Candidate(id: "a", isLocalMLX: false, supportsVision: false, contextTokens: 1_000_000),
        ModelFallbackChain.Candidate(id: "b", isLocalMLX: false, supportsVision: false, contextTokens: 1_000_000),
    ]
    private let needs = ModelFallbackChain.TurnNeeds(requiresVision: false, isBackgrounded: false)

    func testAThrowBeforeTheHopEndsTheTurnWithoutSwitching() async {
        var attempted: [String] = []
        var switches = 0
        do {
            _ = try await ModelCascade.run(
                candidates: chain, needs: needs, maxAttempts: 4,
                beforeHop: { error in throw HopAfterTools.TurnEnded(tools: ["save note"], underlying: SafeErrorSummary(error)) },
                onSwitch: { _, _, _, _ in switches += 1 },
                attempt: { candidate in
                    attempted.append(candidate.id)
                    throw LLMError.invalidResponse("empty")
                })
            XCTFail("the turn ends")
        } catch {
            XCTAssertTrue(error is HopAfterTools.TurnEnded)
        }
        XCTAssertEqual(attempted, ["a"])
        XCTAssertEqual(switches, 0)
    }

    func testTheHopIsAskedOnlyWhenOneWouldHappen() async throws {
        var asked = 0
        // Terminal for the turn: no hop, so nothing is asked.
        do {
            _ = try await ModelCascade.run(candidates: chain, needs: needs, maxAttempts: 4,
                                           beforeHop: { _ in asked += 1 },
                                           attempt: { _ in throw LLMError.invalidConfiguration("bad") })
        } catch {}
        XCTAssertEqual(asked, 0)
        // A hop that happens is asked about once, and goes ahead when nothing is thrown.
        let reply = try await ModelCascade.run(
            candidates: chain, needs: needs, maxAttempts: 4, beforeHop: { _ in asked += 1 },
            attempt: { candidate in
                if candidate.id == "a" { throw LLMError.invalidResponse("empty") }
                return "answered"
            })
        XCTAssertEqual(reply, "answered")
        XCTAssertEqual(asked, 1)
    }
}

/// Plan KL P2 through the real `LLMService`: two Groq models over a recording transport, with a
/// read-only and a state-changing stub tool in the registry. The first model runs a tool and then
/// fails; what the second model is sent, or whether it is asked at all, is the rule at work.
@MainActor
final class HopAfterToolsTurnTests: XCTestCase {
    private var savedModels: [ModelConfig] = []
    private var activeID = ""
    private var cascade = false
    private var agent = false
    private var fallbackOrder: [String] = []
    private var definitionsMode: String?
    private var journalDirectory: URL!

    private final class Spy { var writes = 0, reads = 0 }
    private let spy = Spy()

    private struct ReadingStub: NativeTool {
        let name = "stub_reading"
        let description = "Reads a meter."
        let spy: Spy
        var parametersSchema: [String: Any] {
            ["type": "object", "properties": ["meter": ["type": "string"]]]
        }
        var executionSemantics: ToolExecutionSemantics { .read() }
        func execute(args: [String: Any]) async throws -> String {
            spy.reads += 1
            return "Meter \(args["meter"] as? String ?? "?") reads 42 kPa"
        }
    }

    private struct WritingStub: NativeTool {
        let name = "stub_write"
        let description = "Files a reading."
        let spy: Spy
        var parametersSchema: [String: Any] { ["type": "object", "properties": [String: Any]()] }
        var executionSemantics: ToolExecutionSemantics { .local() }
        func execute(args: [String: Any]) async throws -> String {
            spy.writes += 1
            return "Filed"
        }
    }

    override func setUp() {
        super.setUp()
        savedModels = Config.savedModels
        activeID = Config.activeModelId
        cascade = Config.modelCascadeEnabled
        agent = Config.agentModeEnabled
        fallbackOrder = Config.modelFallbackOrder
        definitionsMode = UserDefaults.standard.string(forKey: "toolDefinitionsMode")
        Config.modelCascadeEnabled = true
        Config.setAgentModeEnabled(false)
        Config.modelFallbackOrder = []
        // Every definition rides on every request, so the stubs are declared from the first round.
        UserDefaults.standard.set(ToolDefinitionsMode.never.rawValue, forKey: "toolDefinitionsMode")
        Config.setSavedModels([
            ModelConfig(id: "groq-a", name: "Groq A", provider: LLMProvider.groq.rawValue,
                        apiKey: "gsk_test_a", model: "qwen/qwen3.8-27b", baseURL: LLMProvider.groq.defaultBaseURL),
            ModelConfig(id: "groq-b", name: "Groq B", provider: LLMProvider.groq.rawValue,
                        apiKey: "gsk_test_b", model: "llama-3.3-70b-versatile", baseURL: LLMProvider.groq.defaultBaseURL),
        ])
        Config.setActiveModelId("groq-a")
        journalDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hop-after-tools-\(UUID().uuidString)", isDirectory: true)
        RecordingQueueProtocol.reset()
    }

    override func tearDown() {
        Config.setSavedModels(savedModels)
        Config.setActiveModelId(activeID)
        Config.modelCascadeEnabled = cascade
        Config.setAgentModeEnabled(agent)
        Config.modelFallbackOrder = fallbackOrder
        if let definitionsMode {
            UserDefaults.standard.set(definitionsMode, forKey: "toolDefinitionsMode")
        } else {
            UserDefaults.standard.removeObject(forKey: "toolDefinitionsMode")
        }
        try? FileManager.default.removeItem(at: journalDirectory)
        RecordingQueueProtocol.reset()
        super.tearDown()
    }

    private func service() -> LLMService {
        let service = LLMService()
        service.processingConsent = CloudConsentFixture.conversation(origins: ["https://api.groq.com"])
        let session = RecordingQueueProtocol.session()
        service.dataSession = session
        service.streamingSession = session
        let registry = NativeToolRegistry(locationService: LocationService())
        registry.register(ReadingStub(spy: spy))
        registry.register(WritingStub(spy: spy))
        let router = NativeToolRouter(registry: registry)
        router.operationJournal = ProtectedOperationJournal(directory: journalDirectory)
        service.nativeToolRouter = router
        return service
    }

    private func toolCall(_ name: String, arguments: String = "{}") -> String {
        let call: [String: Any] = ["choices": [["message": [
            "role": "assistant", "content": NSNull(),
            "tool_calls": [["id": "call_1", "type": "function",
                            "function": ["name": name, "arguments": arguments]]]]]]]
        return String(decoding: try! JSONSerialization.data(withJSONObject: call), as: UTF8.self)
    }

    private let answer = #"{"choices":[{"message":{"role":"assistant","content":"It reads 42 kPa."}}]}"#
    private let outage = #"{"error":{"message":"Service unavailable","type":"server_error"}}"#

    private func systemText(_ request: RecordingQueueProtocol.Recorded) -> String {
        let messages = request.json?["messages"] as? [[String: Any]] ?? []
        return messages.filter { $0["role"] as? String == "system" }.compactMap { $0["content"] as? String }
            .joined(separator: "\n")
    }

    private func roles(_ request: RecordingQueueProtocol.Recorded) -> [String] {
        (request.json?["messages"] as? [[String: Any]] ?? []).compactMap { $0["role"] as? String }
    }

    func testReadOnlyResultsAreCarriedIntoTheNextModelsRequest() async throws {
        let llm = service()
        RecordingQueueProtocol.queue = [(200, toolCall("stub_reading", arguments: #"{"meter":"suction"}"#)),
                                        (503, outage), (200, answer)]
        var hops: [ModelFallbackChain.FailureClass] = []
        let reply = try await llm.sendMessageCascading("What does the suction meter read?",
                                                       onModelSwitch: { _, _, failure, _ in hops.append(failure) })
        XCTAssertEqual(reply, "It reads 42 kPa.")
        XCTAssertEqual(hops, [.retryOtherModel])
        XCTAssertEqual(spy.reads, 1, "the reading is not taken again")
        let requests = RecordingQueueProtocol.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertFalse(systemText(requests[0]).contains(AttemptToolLedger.header))
        let carried = systemText(requests[2])
        XCTAssertTrue(carried.contains(AttemptToolLedger.header), carried.suffix(600).description)
        XCTAssertTrue(carried.contains(#"- stub_reading {"meter":"suction"}: Meter suction reads 42 kPa"#))
        XCTAssertEqual(roles(requests[2]).filter { $0 == "user" }.count, 1, "from the pre-turn history, one user turn")
        XCTAssertFalse(roles(requests[2]).contains("tool"), "the first model's tool exchange is not replayed")
    }

    func testAStateChangingToolEndsTheTurnInsteadOfHopping() async throws {
        let llm = service()
        RecordingQueueProtocol.queue = [(200, toolCall("stub_write")), (503, outage), (200, answer)]
        var hops = 0
        do {
            _ = try await llm.sendMessageCascading("File the reading.", onModelSwitch: { _, _, _, _ in hops += 1 })
            XCTFail("the turn ends after the write")
        } catch let ended as HopAfterTools.TurnEnded {
            XCTAssertEqual(ended.tools, ["stub write"])
            XCTAssertEqual(ended.underlying.category, .serverError)
            XCTAssertEqual(ModelSwitchNarrator.exhaustionPhrase(lastError: ended),
                           "I couldn't get a response — stub write had already run, so I didn't run it again on another model.")
        }
        XCTAssertEqual(hops, 0, "no other model was asked")
        XCTAssertEqual(spy.writes, 1, "the reading was filed once")
        XCTAssertEqual(RecordingQueueProtocol.requests.count, 2)
    }

    func testAHopBeforeAnyToolRanStartsTheTurnAgainAsItDid() async throws {
        let llm = service()
        RecordingQueueProtocol.queue = [(503, outage), (200, answer)]
        let reply = try await llm.sendMessageCascading("What does the suction meter read?")
        XCTAssertEqual(reply, "It reads 42 kPa.")
        let requests = RecordingQueueProtocol.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertFalse(systemText(requests[1]).contains(AttemptToolLedger.header), "nothing to carry")
    }

    func testTheNextTurnCarriesNothing() async throws {
        let llm = service()
        RecordingQueueProtocol.queue = [(200, toolCall("stub_reading", arguments: #"{"meter":"suction"}"#)),
                                        (503, outage), (200, answer), (200, answer)]
        _ = try await llm.sendMessageCascading("What does the suction meter read?")
        _ = try await llm.sendMessageCascading("Thanks.")
        let last = try XCTUnwrap(RecordingQueueProtocol.requests.last)
        XCTAssertFalse(systemText(last).contains(AttemptToolLedger.header))
    }
}
