import XCTest
@testable import OpenGlasses

/// Plan FC P1 — malformed on-device output, driven through the **real** `sendLocal` turn.
///
/// Why the whole turn and not just the classifier: every failure this plan closes happened at a
/// boundary, not in a helper. Protocol text reached the speaker because the turn stripped only
/// complete frames; a correction never ran because it regenerated against a runtime with nothing
/// loaded; broken markup reached `conversationHistory` because the cleanup ran in one place and the
/// insertion in another. So the fixtures below run the actual turn — selection, load, generation,
/// parsing, tool dispatch, both regenerations, history insertion — over a fake backend, and assert
/// on the four things a wearer can actually observe: the returned (spoken) answer, the preview
/// stream, whether a tool ran, and what was persisted.
///
/// The fake backend is a necessity rather than a shortcut: MLX needs Metal, which the simulator
/// does not have, so a real generation cannot run here at all. It is registered through
/// `LLMService.localTurnOverridesForTesting`, which exists only for this harness.
@MainActor
final class LocalTurnContainmentTests: XCTestCase {

    // MARK: - Fakes

    /// Yields a scripted chunk sequence per generation pass and records what each pass was asked.
    private final class ScriptedBackend: LocalInferenceBackend, @unchecked Sendable {
        let runtime: LocalModelRuntime

        private let lock = NSLock()
        private var _scripts: [[String]]
        private var _requests: [LocalGenerationRequest] = []

        /// 1-based pass number that should fail with `CancellationError` instead of yielding.
        var cancelOnPass: Int?

        init(runtime: LocalModelRuntime, scripts: [[String]]) {
            self.runtime = runtime
            self._scripts = scripts
        }

        var requests: [LocalGenerationRequest] {
            lock.lock(); defer { lock.unlock() }
            return _requests
        }

        var passCount: Int { requests.count }

        private var _loaded: LocalLoadedModel?
        var loadedModel: LocalLoadedModel? {
            lock.lock(); defer { lock.unlock() }
            return _loaded
        }

        func load(_ installation: InstalledLocalModel,
                  configuration: LocalLoadConfiguration) async throws -> LocalLoadedModel {
            let loaded = LocalLoadedModel(id: installation.id,
                                          runtime: runtime,
                                          contextLength: configuration.contextLength,
                                          capabilities: [.text, .toolFriendly])
            lock.lock(); _loaded = loaded; lock.unlock()
            return loaded
        }

        func generate(_ request: LocalGenerationRequest) -> AsyncThrowingStream<String, Error> {
            lock.lock()
            _requests.append(request)
            let pass = _requests.count
            let script = _scripts.isEmpty ? [] : _scripts.removeFirst()
            let cancelHere = cancelOnPass == pass
            lock.unlock()

            return AsyncThrowingStream { continuation in
                guard !cancelHere else {
                    continuation.finish(throwing: CancellationError())
                    return
                }
                for piece in script {
                    request.previewSink?(piece)
                    continuation.yield(piece)
                }
                continuation.finish()
            }
        }

        func cancelGeneration() async {}
        func unload() async { lock.lock(); _loaded = nil; lock.unlock() }
    }

    /// A read-only stand-in for a real safe tool, registered under a name the local prompt offers
    /// so authorization behaves exactly as it does in production.
    private final class RecordingTool: NativeTool {
        let name = "get_datetime"
        let description = "Reports the current date and time."
        var parametersSchema: [String: Any] { ["type": "object"] }
        var executionSemantics: ToolExecutionSemantics { .read() }

        private(set) var invocations: [[String: Any]] = []
        var result = "Monday, 15 September 2026, 9:00 am"

        func execute(args: [String: Any]) async throws -> String {
            invocations.append(args)
            return result
        }
    }

    // MARK: - Harness

    private let modelID = LocalModelID("fixture/local-output-policy")

    private var coordinatorWasEnabled = false
    private var webFallbackWasEnabled = true
    private var ggufWasEnabled = false

    override func setUp() {
        super.setUp()
        coordinatorWasEnabled = Config.localRuntimeCoordinatorEnabled
        webFallbackWasEnabled = Config.localWebSearchFallbackEnabled
        ggufWasEnabled = Config.ggufModelsEnabled
        // The coordinator route is the one a headless test can drive; the direct MLX route needs
        // Metal. Both run the same containment code — it lives above the runtime split.
        Config.localRuntimeCoordinatorEnabled = true
        // No network in a fixture: the web re-ask is a separate, already-tested gate.
        Config.localWebSearchFallbackEnabled = false
    }

    override func tearDown() {
        Config.localRuntimeCoordinatorEnabled = coordinatorWasEnabled
        Config.localWebSearchFallbackEnabled = webFallbackWasEnabled
        Config.ggufModelsEnabled = ggufWasEnabled
        super.tearDown()
    }

    private struct Harness {
        let service: LLMService
        let backend: ScriptedBackend
        let tool: RecordingTool
        let config: ModelConfig
        var preview = ""
    }

    private func makeHarness(scripts: [[String]],
                             runtime: LocalModelRuntime = .mlx) -> Harness {
        let backend = ScriptedBackend(runtime: runtime, scripts: scripts)
        let coordinator = LocalInferenceCoordinator(backends: [backend])

        let descriptor = LocalModelDescriptor(
            id: modelID,
            displayName: "Fixture",
            runtime: runtime,
            repositoryID: modelID.rawValue,
            revision: "fixture000",
            capabilities: [.text, .toolFriendly],
            contextLength: 4096,
            estimatedWeightsBytes: 1_000,
            estimatedWorkingBytes: 1_000,
            minimumHeadroomBytes: 2_000)
        let installation = InstalledLocalModel(
            descriptor: descriptor,
            storage: .managed(directoryName: modelID.storageComponent),
            installedAt: Date(timeIntervalSince1970: 0))

        let service = LLMService()
        service.localLLMService = LocalLLMService()
        service.localTurnOverridesForTesting = .init(selectedID: modelID,
                                                     installation: installation,
                                                     coordinator: coordinator)
        service.resetConversationHistoryForTesting()

        let registry = NativeToolRegistry(locationService: LocationService())
        let tool = RecordingTool()
        registry.register(tool)
        service.nativeToolRouter = NativeToolRouter(registry: registry)

        let config = ModelConfig(id: "fixture-local", name: "Fixture",
                                 provider: LLMProvider.local.rawValue, apiKey: "",
                                 model: modelID.rawValue, baseURL: "")
        return Harness(service: service, backend: backend, tool: tool, config: config)
    }

    private func run(_ harness: inout Harness,
                     ask: String = "what time is it") async throws -> String {
        var preview = ""
        let answer = try await harness.service.sendLocalForTesting(
            ask, config: harness.config, onToken: { preview += $0 })
        harness.preview = preview
        return answer
    }

    private func lastAssistantTurn(_ harness: Harness) -> String? {
        harness.service.conversationHistorySnapshotForTesting()
            .last { $0.role == "assistant" }?.content
    }

    private let validCall = #"<tool_call>{"name": "get_datetime", "arguments": {"format": "long"}}</tool_call>"#

    // MARK: - Positive control: a valid call still works end to end

    func testValidToolCallRunsOnceAndSpeaksTheCleanFinalAnswer() async throws {
        var harness = makeHarness(scripts: [[validCall], ["It is 9 in the morning."]])
        let answer = try await run(&harness)

        XCTAssertEqual(harness.tool.invocations.count, 1, "the call must run exactly once")
        XCTAssertEqual(harness.tool.invocations.first?["format"] as? String, "long",
                       "arguments reach the tool untouched")
        XCTAssertEqual(answer, "It is 9 in the morning.")
        XCTAssertEqual(harness.backend.passCount, 2, "one generation, one tool-result regeneration")
        XCTAssertEqual(lastAssistantTurn(harness), "It is 9 in the morning.")
        XCTAssertFalse(harness.preview.contains("<tool_call>"))
    }

    func testOrdinaryAnswerIsUntouchedAndNoToolRuns() async throws {
        for sentence in ["Face the window and the light will be behind you.",
                         "The web_search tool accepts a query.",
                         #"A call looks like {"name": "x"} in JSON."#,
                         "今日は晴れです。"] {
            var harness = makeHarness(scripts: [[sentence]])
            let answer = try await run(&harness, ask: "explain")
            XCTAssertEqual(answer, sentence)
            XCTAssertEqual(harness.preview, sentence)
            XCTAssertTrue(harness.tool.invocations.isEmpty)
            XCTAssertEqual(lastAssistantTurn(harness), sentence)
        }
    }

    // MARK: - Malformed output is contained

    /// The shared assertions for every broken-protocol fixture: nothing ran, nothing raw was
    /// spoken, nothing raw was stored.
    private func assertContained(_ harness: Harness, answer: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(harness.tool.invocations.isEmpty, "no tool may run", file: file, line: line)
        for text in [answer, harness.preview, lastAssistantTurn(harness) ?? ""] {
            XCTAssertFalse(text.contains("tool_call"), "raw protocol escaped: \(text)",
                           file: file, line: line)
            XCTAssertFalse(text.contains("\"arguments\""), "raw protocol escaped: \(text)",
                           file: file, line: line)
        }
        XCTAssertFalse(answer.isEmpty, "dead air is not an acceptable outcome", file: file, line: line)
    }

    func testMalformedJSONInsideTagsIsNotExecutedAndNotSpoken() async throws {
        var harness = makeHarness(scripts: [[#"<tool_call>{"name": "get_datetime", "arguments": }</tool_call>"#]])
        let answer = try await run(&harness)
        assertContained(harness, answer: answer)
        XCTAssertEqual(answer, LLMService.localMissMessage)
        XCTAssertEqual(lastAssistantTurn(harness), LLMService.localMissMessage)
        XCTAssertEqual(harness.backend.passCount, 1, "a broken frame is not retried in a loop")
    }

    func testUnterminatedFrameIsNotExecutedAndNotSpoken() async throws {
        var harness = makeHarness(scripts: [[#"<tool_call>{"name": "get_we"#]])
        let answer = try await run(&harness)
        assertContained(harness, answer: answer)
        XCTAssertEqual(answer, LLMService.localMissMessage)
    }

    func testOrphanCloseTagIsNotSpoken() async throws {
        var harness = makeHarness(scripts: [["The time is not available.</tool_call>"]])
        let answer = try await run(&harness)
        assertContained(harness, answer: answer)
        XCTAssertEqual(answer, "The time is not available.", "the prose survives, the tag does not")
    }

    func testBareCallObjectIsNeverExecuted() async throws {
        var harness = makeHarness(scripts: [[#"{"name": "get_datetime", "arguments": {}}"#]])
        let answer = try await run(&harness)
        assertContained(harness, answer: answer)
        XCTAssertEqual(answer, LLMService.localMissMessage)
    }

    func testMixedProseAndBrokenProtocolKeepsTheProse() async throws {
        var harness = makeHarness(scripts: [[#"It is about nine. <tool_call>{"name": "get_datetime""#]])
        let answer = try await run(&harness)
        assertContained(harness, answer: answer)
        XCTAssertEqual(answer, "It is about nine.")
        XCTAssertEqual(lastAssistantTurn(harness), "It is about nine.")
    }

    func testTagsSplitAcrossChunksNeverReachThePreviewButStillParse() async throws {
        var harness = makeHarness(scripts: [
            ["Sure. ", "<tool_", "call>{\"na", "me\": \"get_datetime\", \"arguments\": {}}", "</tool_", "call>"],
            ["It is nine."],
        ])
        let answer = try await run(&harness)

        XCTAssertFalse(harness.preview.contains("<tool_call>"), "preview: \(harness.preview)")
        XCTAssertFalse(harness.preview.contains("tool_"), "preview: \(harness.preview)")
        XCTAssertEqual(harness.preview.trimmingCharacters(in: .whitespaces), "Sure.")
        XCTAssertEqual(harness.tool.invocations.count, 1,
                       "the classifier still sees the whole call, chunking notwithstanding")
        XCTAssertEqual(answer, "It is nine.")
    }

    func testSecondToolCallInTheToolResultRegenerationIsNotExecuted() async throws {
        var harness = makeHarness(scripts: [
            [validCall],
            [#"<tool_call>{"name": "get_datetime", "arguments": {}}</tool_call>"#],
        ])
        let answer = try await run(&harness)

        XCTAssertEqual(harness.tool.invocations.count, 1, "one tool round trip per turn, still")
        XCTAssertEqual(answer, LLMService.localMissMessage)
        XCTAssertFalse(answer.contains("tool_call"))
        XCTAssertEqual(lastAssistantTurn(harness), LLMService.localMissMessage)
        XCTAssertEqual(harness.backend.passCount, 2, "no third generation")
    }

    func testProseAfterAToolResultSurvivesASecondFrame() async throws {
        var harness = makeHarness(scripts: [
            [validCall],
            [#"It is nine in the morning. <tool_call>{"name": "get_datetime", "arguments": {}}</tool_call>"#],
        ])
        let answer = try await run(&harness)
        XCTAssertEqual(answer, "It is nine in the morning.")
        XCTAssertEqual(harness.tool.invocations.count, 1)
    }

    // MARK: - History hygiene

    func testABrokenTurnDoesNotPolluteTheNextOne() async throws {
        var harness = makeHarness(scripts: [
            [#"<tool_call>{"name": "get_datetime", "arguments": }</tool_call>"#],
            ["It is nine in the morning."],
        ])
        _ = try await run(&harness)
        let second = try await run(&harness, ask: "and now?")

        XCTAssertEqual(second, "It is nine in the morning.", "a normal turn succeeds after a failure")
        let stored = harness.service.conversationHistorySnapshotForTesting()
        XCTAssertFalse(stored.contains { $0.content.contains("tool_call") },
                       "no stored turn may carry protocol text")
        // What the second pass was actually shown. The system turn is excluded on purpose: the
        // local tool instructions legitimately quote the protocol's exact format.
        let carriedHistory = (harness.backend.requests.last?.messages ?? [])
            .filter { $0.role != .system }
            .map(\.content)
            .joined(separator: "\n")
        XCTAssertFalse(carriedHistory.contains("<tool_call>"),
                       "the model must not be shown its own broken protocol back: \(carriedHistory)")
    }

    func testOlderMalformedAssistantTurnsAreSanitizedOutOfTheModelsContext() {
        let harness = makeHarness(scripts: [])
        harness.service.resetConversationHistoryForTesting([
            (role: "user", content: "what time is it"),
            (role: "assistant", content: #"<tool_call>{"name": "get_we"#),
            (role: "user", content: #"why did you print {"name": "x", "arguments": {}}?"#),
            (role: "assistant", content: "Sorry about that. It is nine."),
        ])
        let view = harness.service.localHistoryViewForTesting()

        XCTAssertFalse(view.contains { $0.content.contains("<tool_call>") })
        XCTAssertEqual(view.filter { $0.role == "assistant" }.map(\.content),
                       ["Sorry about that. It is nine."],
                       "the truncated assistant turn is dropped entirely")
        XCTAssertTrue(view.contains { $0.content.contains(#"{"name": "x", "arguments": {}}"#) },
                      "a user's own words are never rewritten")
    }

    // MARK: - Cancellation

    func testCancellationDuringTheFinalGenerationPropagatesUnwrapped() async {
        var harness = makeHarness(scripts: [["never yielded"]])
        harness.backend.cancelOnPass = 1
        do {
            _ = try await run(&harness)
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            XCTAssertTrue(harness.service.conversationHistorySnapshotForTesting()
                .allSatisfy { $0.role != "assistant" },
                          "a cancelled turn appends no answer")
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
    }

    func testCancellationDuringTheCorrectiveRegenerationPropagatesUnwrapped() async {
        var harness = makeHarness(scripts: [["Let me check that for you."], ["unused"]])
        harness.backend.cancelOnPass = 2
        do {
            _ = try await run(&harness)
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            XCTAssertEqual(harness.backend.passCount, 2, "the correction was attempted, then cancelled")
            XCTAssertTrue(harness.service.conversationHistorySnapshotForTesting()
                .allSatisfy { $0.role != "assistant" })
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
    }

    func testCancellationDuringTheToolResultRegenerationPropagatesUnwrapped() async {
        var harness = makeHarness(scripts: [[validCall], ["unused"]])
        harness.backend.cancelOnPass = 2
        do {
            _ = try await run(&harness)
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            XCTAssertEqual(harness.tool.invocations.count, 1, "the tool had already run")
            XCTAssertTrue(harness.service.conversationHistorySnapshotForTesting()
                .allSatisfy { $0.role != "assistant" })
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
    }

    // MARK: - Runtime routing

    func testCorrectiveRegenerationRunsOnTheTurnsRuntimeNotTheMLXService() async throws {
        // The announce-without-action correction used to call `LocalLLMService.generate` directly,
        // which on this route has nothing loaded — so the correction silently never happened.
        var harness = makeHarness(scripts: [["Let me check that for you."], ["It is nine."]])
        let answer = try await run(&harness)

        XCTAssertEqual(harness.backend.passCount, 2, "the correction ran on the selected runtime")
        XCTAssertEqual(answer, "It is nine.")
        let correction = harness.backend.requests.last?.messages.last?.content ?? ""
        XCTAssertTrue(correction.contains("you did not call a tool"), "correction: \(correction)")
    }

    func testCorrectedCallIsExecutedExactlyOnce() async throws {
        var harness = makeHarness(scripts: [
            ["I'll check the time for you."],
            [validCall],
            ["It is nine."],
        ])
        let answer = try await run(&harness)
        XCTAssertEqual(harness.tool.invocations.count, 1)
        XCTAssertEqual(answer, "It is nine.")
        XCTAssertEqual(harness.backend.passCount, 3, "first, correction, tool result — and no more")
    }

    func testGGUFRuntimeTakesTheSameContainedPath() async throws {
        Config.ggufModelsEnabled = true
        // A GGUF installation has no direct MLX route at all, so every pass of the turn must go
        // through the coordinator — which is exactly what the shared generation function ensures.
        var harness = makeHarness(scripts: [
            [#"Checking. <tool_call>{"name": "get_datetime", "arguments""#],
        ], runtime: .llamaCpp)
        let answer = try await run(&harness)

        assertContained(harness, answer: answer)
        XCTAssertEqual(answer, "Checking.")
        XCTAssertEqual(harness.backend.runtime, .llamaCpp)
    }

    func testGGUFValidCallRunsAndRegeneratesOnTheSameBackend() async throws {
        Config.ggufModelsEnabled = true
        var harness = makeHarness(scripts: [[validCall], ["It is nine."]], runtime: .llamaCpp)
        let answer = try await run(&harness)
        XCTAssertEqual(harness.tool.invocations.count, 1)
        XCTAssertEqual(answer, "It is nine.")
        XCTAssertEqual(harness.backend.passCount, 2)
    }
}
