import XCTest
@testable import OpenGlasses

/// Plan MQ P1 — the runtime's parsed tool calls, and the native tool loop, driven through the
/// **real** `sendLocal` turn over a fake backend (the `LocalTurnContainmentTests` harness shape).
///
/// The fake backend yields what mlx-swift-lm's stream does: text, and `.toolCall` events the
/// library's parser took out of it. MLX needs Metal, which the simulator lacks, so this is the only
/// way to run the actual turn — selection, tool choice, dispatch through the router, history.
@MainActor
final class LocalNativeToolTurnTests: XCTestCase {

    // MARK: - Fakes

    /// One generation: its text, and the calls the runtime's parser read.
    struct Pass {
        var text: String = ""
        var calls: [LocalToolCallEvent] = []
        /// What the runtime's fit sent of the tools (Plan MQ P3), or nil for a runtime that fits none.
        var fit: LocalToolFit.Report? = nil
    }

    private final class EventBackend: LocalInferenceBackend, @unchecked Sendable {
        let runtime: LocalModelRuntime
        private let lock = NSLock()
        private var _passes: [Pass]
        private var _requests: [LocalGenerationRequest] = []
        var cancelOnPass: Int?

        init(runtime: LocalModelRuntime, passes: [Pass]) {
            self.runtime = runtime
            self._passes = passes
        }

        var requests: [LocalGenerationRequest] {
            lock.lock(); defer { lock.unlock() }
            return _requests
        }

        private var _loaded: LocalLoadedModel?
        var loadedModel: LocalLoadedModel? {
            lock.lock(); defer { lock.unlock() }
            return _loaded
        }

        func load(_ installation: InstalledLocalModel,
                  configuration: LocalLoadConfiguration) async throws -> LocalLoadedModel {
            let loaded = LocalLoadedModel(id: installation.id, runtime: runtime,
                                          contextLength: configuration.contextLength, capabilities: [.text])
            lock.lock(); _loaded = loaded; lock.unlock()
            return loaded
        }

        private func next(_ request: LocalGenerationRequest) -> (Pass, Bool) {
            lock.lock(); defer { lock.unlock() }
            _requests.append(request)
            let pass = _passes.isEmpty ? Pass() : _passes.removeFirst()
            return (pass, cancelOnPass == _requests.count)
        }

        func generate(_ request: LocalGenerationRequest) -> AsyncThrowingStream<String, Error> {
            let (pass, cancel) = next(request)
            return AsyncThrowingStream { continuation in
                if cancel { continuation.finish(throwing: CancellationError()); return }
                request.previewSink?(pass.text)
                continuation.yield(pass.text)
                continuation.finish()
            }
        }

        func generateEvents(_ request: LocalGenerationRequest) -> AsyncThrowingStream<LocalGenerationEvent, Error> {
            let (pass, cancel) = next(request)
            return AsyncThrowingStream { continuation in
                if cancel { continuation.finish(throwing: CancellationError()); return }
                request.previewSink?(pass.text)
                if let fit = pass.fit { continuation.yield(.toolFit(fit)) }
                continuation.yield(.text(pass.text))
                for call in pass.calls { continuation.yield(.toolCall(call)) }
                continuation.finish()
            }
        }

        func cancelGeneration() async {}
        func unload() async { lock.lock(); _loaded = nil; lock.unlock() }
    }

    private final class RecordingTool: NativeTool {
        let name: String
        let description: String
        let schema: [String: Any]
        var parametersSchema: [String: Any] { schema }
        var executionSemantics: ToolExecutionSemantics { .read() }
        private(set) var invocations: [[String: Any]] = []
        var result: String

        init(name: String, description: String, schema: [String: Any] = ["type": "object"], result: String) {
            self.name = name
            self.description = description
            self.schema = schema
            self.result = result
        }

        func execute(args: [String: Any]) async throws -> String {
            invocations.append(args)
            return result
        }
    }

    // MARK: - Harness

    private static let gemma = LocalModelID("mlx-community/gemma-4-e2b-it-4bit")
    private static let other = LocalModelID("fixture/not-allowlisted")

    private var coordinatorWasEnabled = false
    private var webFallbackWasEnabled = true
    private var nativeWasEnabled = false

    override func setUp() {
        super.setUp()
        coordinatorWasEnabled = Config.localRuntimeCoordinatorEnabled
        webFallbackWasEnabled = Config.localWebSearchFallbackEnabled
        nativeWasEnabled = Config.localNativeToolCallsEnabled
        Config.localRuntimeCoordinatorEnabled = true
        Config.localWebSearchFallbackEnabled = false
        Config.localNativeToolCallsEnabled = false
    }

    override func tearDown() {
        Config.localRuntimeCoordinatorEnabled = coordinatorWasEnabled
        Config.localWebSearchFallbackEnabled = webFallbackWasEnabled
        Config.localNativeToolCallsEnabled = nativeWasEnabled
        super.tearDown()
    }

    private struct Harness {
        let service: LLMService
        let backend: EventBackend
        let clock: RecordingTool
        let calculator: RecordingTool
        let config: ModelConfig
    }

    private func makeHarness(model: LocalModelID = gemma, passes: [Pass]) -> Harness {
        let backend = EventBackend(runtime: .mlx, passes: passes)
        let coordinator = LocalInferenceCoordinator(backends: [backend])
        let descriptor = LocalModelDescriptor(
            id: model, displayName: "Fixture", runtime: .mlx, repositoryID: model.rawValue,
            revision: "fixture000", capabilities: [.text], contextLength: 4096,
            estimatedWeightsBytes: 1_000, estimatedWorkingBytes: 1_000, minimumHeadroomBytes: 2_000)
        let installation = InstalledLocalModel(descriptor: descriptor,
                                               storage: .managed(directoryName: model.storageComponent),
                                               installedAt: Date(timeIntervalSince1970: 0))
        let service = LLMService()
        service.localLLMService = LocalLLMService()
        service.localTurnOverridesForTesting = .init(selectedID: model, installation: installation,
                                                     coordinator: coordinator)
        service.resetConversationHistoryForTesting()

        let registry = NativeToolRegistry(locationService: LocationService())
        let clock = RecordingTool(name: "get_datetime", description: "Reports the current date and time.",
                                  result: "Monday, 15 September 2026, 9:00 am")
        let calculator = RecordingTool(
            name: "calculate", description: "Evaluates an arithmetic expression.",
            schema: ["type": "object",
                     "properties": ["expression": ["type": "string", "description": "The expression."],
                                    "precision": ["type": "integer", "description": "Decimal places."]],
                     "required": ["expression"]],
            result: "4")
        registry.register(clock)
        registry.register(calculator)
        service.nativeToolRouter = NativeToolRouter(registry: registry)
        let config = ModelConfig(id: "fixture-local", name: "Fixture", provider: LLMProvider.local.rawValue,
                                 apiKey: "", model: model.rawValue, baseURL: "")
        return Harness(service: service, backend: backend, clock: clock, calculator: calculator, config: config)
    }

    private func ask(_ harness: Harness, _ text: String = "what time is it") async throws -> String {
        try await harness.service.sendLocalForTesting(text, config: harness.config)
    }

    private func lastAssistant(_ harness: Harness) -> String? {
        harness.service.conversationHistorySnapshotForTesting().last { $0.role == "assistant" }?.content
    }

    private let clockCall = LocalToolCallEvent(name: "get_datetime", arguments: [:])

    // MARK: - Flag off: the runtime's calls are no longer dropped

    func testFlagOffAParsedCallRunsThroughTheSingleShot() async throws {
        // A Hermes-format model: the library consumed the `<tool_call>` frame and emitted the call.
        let harness = makeHarness(passes: [Pass(text: "", calls: [clockCall]), Pass(text: "It is 9 in the morning.")])
        let answer = try await ask(harness)
        XCTAssertEqual(harness.clock.invocations.count, 1, "the parsed call runs, where it used to vanish")
        XCTAssertEqual(answer, "It is 9 in the morning.")
        XCTAssertEqual(harness.backend.requests.count, 2, "one generation and the tool-result regeneration")
        XCTAssertTrue(harness.backend.requests.allSatisfy { $0.toolTurn == nil }, "flag off sends no tool turn")
        XCTAssertEqual(lastAssistant(harness), "It is 9 in the morning.")
    }

    func testFlagOffACallInTheTextStillWinsAndTheTextIsNeverSpoken() async throws {
        let text = #"<tool_call>{"name": "get_datetime", "arguments": {}}</tool_call>"#
        let harness = makeHarness(passes: [Pass(text: text, calls: [LocalToolCallEvent(name: "calculate", arguments: ["expression": "2+2"])]),
                                           Pass(text: "Nine o'clock.")])
        let answer = try await ask(harness)
        XCTAssertEqual(harness.clock.invocations.count, 1)
        XCTAssertTrue(harness.calculator.invocations.isEmpty, "one call per single shot, the text's first")
        XCTAssertEqual(answer, "Nine o'clock.")
    }

    func testFlagOnButNotAllowlistedKeepsTheSingleShot() async throws {
        Config.localNativeToolCallsEnabled = true
        let harness = makeHarness(model: Self.other, passes: [Pass(calls: [clockCall]), Pass(text: "Nine.")])
        _ = try await ask(harness)
        XCTAssertTrue(harness.backend.requests.allSatisfy { $0.toolTurn == nil })
        XCTAssertEqual(harness.clock.invocations.count, 1)
    }

    // MARK: - Flag on, allowlisted: the native loop

    func testNativeTurnDeclaresToolsWritesTheCallBackAndAnswers() async throws {
        Config.localNativeToolCallsEnabled = true
        let harness = makeHarness(passes: [Pass(calls: [clockCall]), Pass(text: "It is nine.")])
        let answer = try await ask(harness)

        XCTAssertEqual(answer, "It is nine.")
        XCTAssertEqual(harness.clock.invocations.count, 1)
        let first = try XCTUnwrap(harness.backend.requests.first?.toolTurn)
        let declared = first.tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        XCTAssertTrue(declared.contains("get_datetime"), "the turn's tools are declared as specs")
        XCTAssertLessThanOrEqual(declared.count, LocalNativeToolPolicy.perTurnLimit)
        XCTAssertTrue(first.thinkingOff)
        XCTAssertEqual(first.turn.map(\.role), [.user])

        let second = try XCTUnwrap(harness.backend.requests.last?.toolTurn)
        XCTAssertEqual(second.turn.map(\.role), [.user, .assistant, .tool], "the call and its result are written back")
        XCTAssertEqual(second.turn[1].toolName, "get_datetime")
        XCTAssertEqual(second.turn[1].toolCallID, second.turn[2].toolCallID)
        XCTAssertTrue(second.turn[2].content.contains("9:00 am"))
        XCTAssertEqual(lastAssistant(harness), "It is nine.")
    }

    func testArgumentsAreCoercedToTheDeclaredTypesBeforeDispatch() async throws {
        Config.localNativeToolCallsEnabled = true
        let call = LocalToolCallEvent(name: "calculate", arguments: ["expression": "2+2", "precision": "2"])
        let harness = makeHarness(passes: [Pass(calls: [call]), Pass(text: "Four.")])
        _ = try await ask(harness, "calculate two plus two")
        XCTAssertEqual(harness.calculator.invocations.first?["precision"] as? Int, 2, "\"2\" reaches the tool as 2")
    }

    func testRefusedArgumentsRunNothingAndGoBackToTheModel() async throws {
        Config.localNativeToolCallsEnabled = true
        let call = LocalToolCallEvent(name: "calculate", arguments: ["expression": "2+2", "precision": "about two"])
        let harness = makeHarness(passes: [Pass(calls: [call]), Pass(text: "Sorry, I could not work that out.")])
        let answer = try await ask(harness, "calculate two plus two")
        XCTAssertTrue(harness.calculator.invocations.isEmpty)
        let result = try XCTUnwrap(harness.backend.requests.last?.toolTurn?.turn.last)
        XCTAssertEqual(result.role, .tool)
        XCTAssertTrue(result.content.contains("Argument 'precision' must be an integer."))
        XCTAssertEqual(answer, "Sorry, I could not work that out.")
    }

    func testACallToAToolTheTurnDidNotOfferIsNotRun() async throws {
        Config.localNativeToolCallsEnabled = true
        let harness = makeHarness(passes: [Pass(calls: [LocalToolCallEvent(name: "send_message", arguments: ["to": "x"])]),
                                           Pass(text: "I can't send messages here.")])
        let answer = try await ask(harness, "text Sam")
        let result = try XCTUnwrap(harness.backend.requests.last?.toolTurn?.turn.last)
        XCTAssertTrue(result.content.hasPrefix("Error: the tool 'send_message' is not available"))
        XCTAssertEqual(answer, "I can't send messages here.")
    }

    /// Plan MQ P3: the runtime fitted the definitions and dropped a tool for room. The model never
    /// saw it declared, so a call to it is answered as not offered and runs nothing.
    func testACallToAToolTheFitDroppedIsNotRun() async throws {
        Config.localNativeToolCallsEnabled = true
        let harness = makeHarness(passes: [Pass(text: "", calls: [clockCall],
                                                fit: .init(offered: 2, keptNames: ["calculate"], compact: true,
                                                           contextWindow: 4_096)),
                                           Pass(text: "I can't check the time just now.")])
        let answer = try await ask(harness)
        XCTAssertTrue(harness.clock.invocations.isEmpty, "the dropped tool is not run")
        let result = try XCTUnwrap(harness.backend.requests.last?.toolTurn?.turn.last)
        XCTAssertEqual(result.role, .tool)
        XCTAssertEqual(result.content, LocalToolLoop.unofferedToolMessage(name: "get_datetime", offered: ["calculate"]))
        XCTAssertEqual(answer, "I can't check the time just now.")
    }

    /// The turn hands the runtime both definitions of every tool, in priority order, and the window.
    func testTheNativeTurnCarriesCompactDefinitionsInTheSameOrder() async throws {
        Config.localNativeToolCallsEnabled = true
        let harness = makeHarness(passes: [Pass(text: "Nine.")])
        _ = try await ask(harness)
        let turn = try XCTUnwrap(harness.backend.requests.first?.toolTurn)
        XCTAssertEqual(turn.compactTools.count, turn.tools.count)
        XCTAssertEqual(turn.compactTools.compactMap(LocalToolFit.name(of:)), turn.toolNames)
        XCTAssertNotNil(turn.contextWindow, "a native turn names its window")
    }

    func testARepeatedCallEndsTheLoopAndTheAnswerStands() async throws {
        Config.localNativeToolCallsEnabled = true
        let harness = makeHarness(passes: [Pass(calls: [clockCall]),
                                           Pass(text: "", calls: [clockCall]),
                                           Pass(text: "It is nine.")])
        let answer = try await ask(harness)
        XCTAssertEqual(harness.clock.invocations.count, 1, "the repeat is not run")
        XCTAssertEqual(answer, "It is nine.")
        XCTAssertEqual(harness.backend.requests.last?.toolTurn?.tools.count, 0, "the last answer has tools withheld")
    }

    func testProtocolOnlyOutputIsAnHonestMissAndNeverSpoken() async throws {
        Config.localNativeToolCallsEnabled = true
        let harness = makeHarness(passes: [Pass(text: #"<tool_call>{"name": "get_datetime", "arguments": }"#)])
        let answer = try await ask(harness)
        XCTAssertEqual(answer, LLMService.localMissMessage)
        XCTAssertFalse((lastAssistant(harness) ?? "").contains("tool_call"))
        XCTAssertTrue(harness.service.lastLocalTurnMissed)
    }

    func testABargeInDuringTheLoopCancelsUnwrapped() async throws {
        Config.localNativeToolCallsEnabled = true
        let harness = makeHarness(passes: [Pass(calls: [clockCall]), Pass(text: "nine")])
        harness.backend.cancelOnPass = 2
        do {
            _ = try await ask(harness)
            XCTFail("expected cancellation")
        } catch is CancellationError {
            XCTAssertEqual(harness.clock.invocations.count, 1)
        }
    }
}
