import XCTest
@testable import OpenGlasses

/// Plan MQ P2 — a GGUF tool turn through the backend and the shipped `LocalToolLoop`, and the KV
/// cache's prefix reuse (H3).
///
/// The fake engine scripts loading, tokenizing, decoding and sampling, and hands every chat call
/// to the real `common/chat` bridge with Gemma 4's template, so a turn is rendered and its calls
/// parsed exactly as on a phone while its "model" says what the test wrote.
final class LlamaCppToolTurnTests: XCTestCase {

    // MARK: - Fake engine

    private final class ChatFakeEngine: LlamaEngine, @unchecked Sendable {
        private let real = LlamaCppEngine()
        private let lock = NSLock()
        private let templateSource: String

        /// What each generation says, piece by piece; one list per generation, in order.
        var replies: [[String]] = []
        /// What `keepPrefix` answers; nil keeps whatever is asked.
        var keepPrefixOverride: Int?
        /// The legacy fixed-list template renders (as for a model that has both); false refuses it,
        /// as llama.cpp's fixed list refuses Gemma 4's.
        var legacyTemplateWorks = true
        var chatTemplatesAvailable = true

        private var _generation = -1
        private var _sampleIndex = 0
        private var _requests: [String] = []
        private var _keepAsked: [Int] = []
        private var _decodes: [(count: Int, position: Int)] = []
        private var _grammarSet = 0
        private var _grammarCleared = 0

        init(templateSource: String) { self.templateSource = templateSource }

        var requests: [String] { lock.lock(); defer { lock.unlock() }; return _requests }
        var keepAsked: [Int] { lock.lock(); defer { lock.unlock() }; return _keepAsked }
        var decodes: [(count: Int, position: Int)] { lock.lock(); defer { lock.unlock() }; return _decodes }
        var grammarSet: Int { lock.lock(); defer { lock.unlock() }; return _grammarSet }
        var grammarCleared: Int { lock.lock(); defer { lock.unlock() }; return _grammarCleared }

        private static let endOfGeneration: LlamaToken = 9_999

        func loadModel(atPath path: String, options: LlamaModelOptions) throws -> LlamaModelHandle {
            LlamaModelHandle(bits: 1)
        }
        func freeModel(_ model: LlamaModelHandle) {}
        func metadataValue(_ model: LlamaModelHandle, key: String) -> String? {
            ["general.architecture": "gemma4", "gemma4.context_length": "8192", "gemma4.block_count": "16",
             "gemma4.embedding_length": "1024", "gemma4.attention.head_count": "16",
             "gemma4.attention.head_count_kv": "4"][key]
        }
        func chatTemplate(_ model: LlamaModelHandle, named name: String?) -> String? { templateSource }
        func trainingContextTokens(_ model: LlamaModelHandle) -> Int { 8192 }
        func vocabularyAddsBOS(_ model: LlamaModelHandle) -> Bool { true }
        func beginningOfSequencePiece(_ model: LlamaModelHandle) -> String? { "<bos>" }
        func isEndOfGeneration(_ model: LlamaModelHandle, token: LlamaToken) -> Bool { token == Self.endOfGeneration }

        func applyChatTemplate(_ template: String, turns: [LlamaChatTurn], addAssistantHeader: Bool) throws -> String {
            guard legacyTemplateWorks else { throw LlamaEngineError.templateFailed }
            var out = ""
            for turn in turns { out += "<|start|>\(turn.role)\n\(turn.content)<|end|>\n" }
            if addAssistantHeader { out += "<|start|>assistant\n" }
            return out
        }

        /// One token per four bytes, numbered from the text's own bytes so that two prompts that
        /// start alike tokenize alike — what prefix reuse needs to see.
        func tokenize(_ model: LlamaModelHandle, text: String, addSpecial: Bool, parseSpecial: Bool) throws -> [LlamaToken] {
            let bytes = Array(text.utf8)
            return stride(from: 0, to: bytes.count, by: 4).map { start in
                let chunk = bytes[start..<min(start + 4, bytes.count)]
                return LlamaToken(chunk.reduce(7) { ($0 &* 31 &+ Int($1)) & 0x3FFF_FFFF })
            }
        }

        func tokenBytes(_ model: LlamaModelHandle, token: LlamaToken) -> [UInt8] {
            lock.lock(); defer { lock.unlock() }
            guard _generation >= 0, _generation < replies.count else { return [] }
            let index = Int(token)
            guard index >= 0, index < replies[_generation].count else { return [] }
            return Array(replies[_generation][index].utf8)
        }

        func createContext(_ model: LlamaModelHandle, options: LlamaContextOptions) throws -> LlamaContextHandle {
            LlamaContextHandle(bits: 2)
        }
        func freeContext(_ context: LlamaContextHandle) {}
        func contextTokens(_ context: LlamaContextHandle) -> Int { 4096 }
        func batchTokens(_ context: LlamaContextHandle) -> Int { 512 }
        func clearMemory(_ context: LlamaContextHandle) {}
        func setCancelled(_ context: LlamaContextHandle, _ cancelled: Bool) {}
        func synchronize(_ context: LlamaContextHandle) {}

        func decode(_ context: LlamaContextHandle, tokens: [LlamaToken], position: Int, wantsLogitsForLast: Bool) throws {
            lock.lock(); _decodes.append((tokens.count, position)); lock.unlock()
        }

        func createSampler(_ model: LlamaModelHandle, options: LlamaSamplerOptions) throws -> LlamaSamplerHandle {
            LlamaSamplerHandle(bits: 3)
        }
        func freeSampler(_ sampler: LlamaSamplerHandle) {}

        /// Called once at the start of every generation: the next scripted reply begins.
        func resetSampler(_ sampler: LlamaSamplerHandle) {
            lock.lock(); _generation += 1; _sampleIndex = 0; lock.unlock()
        }

        func sample(_ sampler: LlamaSamplerHandle, context: LlamaContextHandle) throws -> LlamaToken {
            lock.lock(); defer { lock.unlock() }
            let index = _sampleIndex
            _sampleIndex += 1
            guard _generation < replies.count, index < replies[_generation].count else { return Self.endOfGeneration }
            return LlamaToken(index)
        }

        func keepPrefix(_ context: LlamaContextHandle, tokens: Int) -> Int {
            lock.lock(); _keepAsked.append(tokens); lock.unlock()
            return keepPrefixOverride ?? tokens
        }

        // The chat calls are the real bridge's.

        func chatTemplates(_ model: LlamaModelHandle) throws -> LlamaChatTemplatesHandle {
            guard chatTemplatesAvailable else { throw LlamaEngineError.noChatTemplate }
            return try real.chatTemplates(source: templateSource, bosToken: "<bos>", eosToken: "<eos>")
        }
        func chatTemplates(source: String, bosToken: String, eosToken: String) throws -> LlamaChatTemplatesHandle {
            try real.chatTemplates(source: source, bosToken: bosToken, eosToken: eosToken)
        }
        func freeChatTemplates(_ templates: LlamaChatTemplatesHandle) { real.freeChatTemplates(templates) }
        func renderChat(_ templates: LlamaChatTemplatesHandle, requestJSON: String) throws -> String {
            lock.lock(); _requests.append(requestJSON); lock.unlock()
            return try real.renderChat(templates, requestJSON: requestJSON)
        }
        func createChatParser(_ templates: LlamaChatTemplatesHandle, requestJSON: String) throws -> LlamaChatParserHandle {
            try real.createChatParser(templates, requestJSON: requestJSON)
        }
        func freeChatParser(_ parser: LlamaChatParserHandle) { real.freeChatParser(parser) }
        func parseChat(_ parser: LlamaChatParserHandle, text: String, partial: Bool) throws -> String {
            try real.parseChat(parser, text: text, partial: partial)
        }
        func setChatGrammar(_ sampler: LlamaSamplerHandle, model: LlamaModelHandle, renderJSON: String) throws {
            lock.lock(); _grammarSet += 1; lock.unlock()
        }
        func clearGrammar(_ sampler: LlamaSamplerHandle) {
            lock.lock(); _grammarCleared += 1; lock.unlock()
        }
    }

    // MARK: - Fixtures

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gguf-tool-turn-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private static func gemmaTemplate() throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ChatTemplates/google-gemma-4-31B-it.jinja"), encoding: .utf8)
    }

    private func loadedBackend(_ engine: ChatFakeEngine) async throws -> LlamaCppLocalInferenceBackend {
        let weights = directory.appendingPathComponent("model.gguf")
        try Data(repeating: 0x47, count: 1024).write(to: weights)
        let file = LocalModelFile(relativePath: "model.gguf", byteCount: 1024,
                                  sha256: String(repeating: "a", count: 64), role: .weights)
        let id = "ggml-org/gemma-4-E2B-it-GGUF#gemma-4-E2B-it-Q4_0.gguf"
        let installation = InstalledLocalModel(
            descriptor: LocalModelDescriptor(id: LocalModelID(id), displayName: "Test", runtime: .llamaCpp,
                                             repositoryID: "ggml-org/gemma-4-E2B-it-GGUF", revision: "abc123",
                                             files: [file], capabilities: [.text], contextLength: 4096,
                                             estimatedWeightsBytes: 1_000, estimatedWorkingBytes: 1_000,
                                             minimumHeadroomBytes: 0),
            storage: .managed(directoryName: LocalModelID(id).storageComponent),
            installedAt: Date(timeIntervalSince1970: 0),
            validatedFiles: [file])
        let root = directory!
        let backend = LlamaCppLocalInferenceBackend(
            engine: engine, directoryForInstallation: { _ in root }, availableProcessBytes: { 0 },
            appFootprintBytes: { 0 }, thermalState: { .nominal }, monotonicNanoseconds: { 0 },
            isRuntimeEnabled: { true }, recordDiagnostics: { _ in })
        _ = try await backend.load(installation, configuration: LocalLoadConfiguration(contextLength: 4096))
        return backend
    }

    private static let readingSpec = OnDeviceToolSchema.localToolSpec(
        name: "reading", description: "Log a measured value on the open job.",
        parameters: ["type": "object",
                     "properties": ["value": ["type": "number", "description": "The value."],
                                    "unit": ["type": "string", "enum": ["psi", "kPa"]]],
                     "required": ["value"]])

    /// One pass of the loop, the way `LLMService.sendLocal` sends it through the coordinator.
    private func generate(_ backend: LlamaCppLocalInferenceBackend, history: [LocalToolLoop.Message],
                          request: LocalToolLoop.GenerationRequest) async throws -> LocalToolLoop.Generation {
        let toolTurn = LocalToolTurn.forLoopPass(history: history, request: request,
                                                 toolSpecs: [Self.readingSpec],
                                                 compactToolSpecs: [Self.readingSpec],
                                                 fallbackInstructions: "\nUse <tool_call>.")
        let flat = LocalToolTranscript.flattened(request.messages)
        let seam = LocalGenerationRequest(
            messages: MLXPromptAdapter.compose(systemPrompt: "You are Avenkin.", history: Array(flat.dropLast()),
                                               userMessage: flat.last?.content ?? ""),
            maxOutputTokens: 128, toolTurn: toolTurn)
        var text = ""
        var calls: [LocalToolCallEvent] = []
        var fit: LocalToolFit.Report?
        var stats: LocalGenerationStats?
        for try await event in backend.generateEvents(seam) {
            switch event {
            case .text(let chunk): text += chunk
            case .toolCall(let call): calls.append(call)
            case .toolFit(let report): fit = report
            case .stats(let report): stats = report
            }
        }
        return LocalToolLoop.Generation(text: text, toolCalls: calls, stats: stats, toolFit: fit)
    }

    private func configuration() -> LocalToolLoop.Configuration {
        var configuration = LocalToolLoop.Configuration()
        configuration.assistantName = "Avenkin"
        return configuration
    }

    // MARK: - The tool turn reaches LocalToolLoop

    func testAGemmaCallParsedByCommonChatRunsThroughTheLoop() async throws {
        let engine = ChatFakeEngine(templateSource: try Self.gemmaTemplate())
        engine.replies = [
            ["<|tool_call>", "call:reading{", "unit:<|\"|>psi<|\"|>,", "value:60}", "<tool_call|>"],
            ["Logged ", "60 psi on the low side."],
        ]
        let backend = try await loadedBackend(engine)
        var executed: [LocalToolLoop.Call] = []
        let outcome = try await LocalToolLoop.run(
            history: [], userMessage: "Log 60 psi on the low side", configuration: configuration(),
            generateTurn: { request in try await self.generate(backend, history: [], request: request) },
            execute: { call in
                executed.append(call)
                return LocalToolLoop.ExecutionResult(text: "Logged 60 psi, low side.")
            })

        XCTAssertEqual(executed.map(\.name), ["reading"])
        XCTAssertEqual(executed.first?.canonicalArguments, #"{"unit":"psi","value":60}"#)
        XCTAssertEqual(outcome.text, "Logged 60 psi on the low side.")
        XCTAssertEqual(outcome.endReason, .answered)

        // The second pass carried the call and its result back in the roles the template reads.
        let second = try XCTUnwrap(engine.requests.last)
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(second.utf8)) as? [String: Any])
        let roles = (request["messages"] as? [[String: Any]])?.compactMap { $0["role"] as? String }
        XCTAssertEqual(roles, ["system", "user", "assistant", "tool"])
        XCTAssertGreaterThan(engine.grammarSet, 0, "the family's lazy grammar went on the sampler")
    }

    func testTheGenerationReportsItsFitAndItsStats() async throws {
        let engine = ChatFakeEngine(templateSource: try Self.gemmaTemplate())
        engine.replies = [["All ", "good."]]
        let backend = try await loadedBackend(engine)
        let generation = try await generate(backend, history: [], request: LocalToolLoop.GenerationRequest(
            messages: [.user("How's it going?")], toolsOffered: true, purpose: .initial, round: 0))
        XCTAssertEqual(generation.text, "All good.")
        XCTAssertEqual(generation.toolCalls, [])
        XCTAssertEqual(generation.toolFit?.keptNames, ["reading"], "the dispatcher learns what was declared")
        XCTAssertEqual(generation.stats?.generatedTokens, 2)
        XCTAssertEqual(generation.stats?.tokenCap, 128)
        XCTAssertFalse(generation.stats?.isCut ?? true)
    }

    func testAMalformedCallIsNeverRun() async throws {
        let engine = ChatFakeEngine(templateSource: try Self.gemmaTemplate())
        // Cut off by the cap mid-arguments, then a plain answer on the correction.
        engine.replies = [["<|tool_call>", "call:reading{", "value:"], ["Sorry, say that again?"]]
        let backend = try await loadedBackend(engine)
        let generation = try await generate(backend, history: [], request: LocalToolLoop.GenerationRequest(
            messages: [.user("Log 60 psi")], toolsOffered: true, purpose: .initial, round: 0))
        XCTAssertEqual(generation.toolCalls, [], "half a call never reaches the dispatcher")
    }

    func testWithToolsWithheldNoGrammarIsApplied() async throws {
        let engine = ChatFakeEngine(templateSource: try Self.gemmaTemplate())
        engine.replies = [["Done."]]
        let backend = try await loadedBackend(engine)
        _ = try await generate(backend, history: [], request: LocalToolLoop.GenerationRequest(
            messages: [.user("Log 60 psi")], toolsOffered: false, purpose: .final, round: 0))
        XCTAssertEqual(engine.grammarSet, 0)
        XCTAssertGreaterThan(engine.grammarCleared, 0)
        let request = try XCTUnwrap(engine.requests.last)
        XCTAssertFalse(request.contains("\"tools\""), "withheld tools are not rendered")
    }

    func testAModelOnlyCommonChatCanRenderStillLoadsAndAnswers() async throws {
        let engine = ChatFakeEngine(templateSource: try Self.gemmaTemplate())
        engine.legacyTemplateWorks = false   // llama.cpp's fixed list does not know Gemma 4's template
        engine.replies = [["Hello", " there."]]
        let backend = try await loadedBackend(engine)
        var text = ""
        for try await chunk in backend.generate(LocalGenerationRequest(
            messages: [.system("Be brief."), .user("Hi?")], maxOutputTokens: 64)) { text += chunk }
        XCTAssertEqual(text, "Hello there.")
        XCTAssertFalse(engine.requests.isEmpty, "rendered by common/chat")
    }

    func testWithoutCommonChatAToolTurnFallsBackToTheHermesInstruction() async throws {
        let engine = ChatFakeEngine(templateSource: try Self.gemmaTemplate())
        engine.chatTemplatesAvailable = false
        engine.replies = [["Okay."]]
        let backend = try await loadedBackend(engine)
        let generation = try await generate(backend, history: [], request: LocalToolLoop.GenerationRequest(
            messages: [.user("Log 60 psi")], toolsOffered: true, purpose: .initial, round: 0))
        XCTAssertEqual(generation.text, "Okay.")
        XCTAssertEqual(generation.toolFit?.keptNames, ["reading"], "not fitted: the instruction is text")
        XCTAssertTrue(engine.requests.isEmpty)
    }

    // MARK: - Prefix reuse (Plan MQ H3)

    func testTheSecondRoundOfALoopPrefillsOnlyWhatIsNew() async throws {
        let engine = ChatFakeEngine(templateSource: try Self.gemmaTemplate())
        engine.replies = [
            ["<|tool_call>", "call:reading{value:60}", "<tool_call|>"],
            ["Logged."],
        ]
        let backend = try await loadedBackend(engine)
        _ = try await LocalToolLoop.run(
            history: [], userMessage: "Log 60 psi", configuration: configuration(),
            generateTurn: { request in try await self.generate(backend, history: [], request: request) },
            execute: { _ in LocalToolLoop.ExecutionResult(text: "Logged 60 psi.") })

        XCTAssertEqual(engine.keepAsked.first, 0, "nothing cached before the first generation")
        let second = try XCTUnwrap(engine.keepAsked.dropFirst().first)
        XCTAssertGreaterThan(second, 0, "the round after the call keeps the shared start")
        // The second prompt's prefill starts where the cache left off, not at 0.
        XCTAssertTrue(engine.decodes.contains { $0.position == second && $0.count > 1 },
                      "prefill resumes at the kept prefix")
        XCTAssertEqual(engine.decodes.filter { $0.position == 0 }.count, 1, "only the first prompt read from 0")
    }

    func testACacheThatCannotBeCutBackIsReadFromTheStart() async throws {
        let engine = ChatFakeEngine(templateSource: try Self.gemmaTemplate())
        engine.keepPrefixOverride = 0   // a recurrent model's state, say
        engine.replies = [["One."], ["Two."]]
        let backend = try await loadedBackend(engine)
        for turn in ["First?", "Second?"] {
            _ = try await generate(backend, history: [], request: LocalToolLoop.GenerationRequest(
                messages: [.user(turn)], toolsOffered: false, purpose: .initial, round: 0))
        }
        XCTAssertGreaterThan(engine.keepAsked.last ?? 0, 0, "the shared start was asked for")
        XCTAssertEqual(engine.decodes.filter { $0.position == 0 }.count, 2, "and both prompts prefilled from 0")
    }

    func testAnUnloadLeavesNothingToReuse() async throws {
        let engine = ChatFakeEngine(templateSource: try Self.gemmaTemplate())
        engine.replies = [["One."], ["Two."]]
        let backend = try await loadedBackend(engine)
        _ = try await generate(backend, history: [], request: LocalToolLoop.GenerationRequest(
            messages: [.user("First?")], toolsOffered: false, purpose: .initial, round: 0))
        await backend.unload()
        _ = try await loadedBackendReload(backend)
        _ = try await generate(backend, history: [], request: LocalToolLoop.GenerationRequest(
            messages: [.user("First?")], toolsOffered: false, purpose: .initial, round: 0))
        XCTAssertEqual(engine.keepAsked.last, 0, "an unloaded cache is not trusted")
    }

    private func loadedBackendReload(_ backend: LlamaCppLocalInferenceBackend) async throws -> LocalLoadedModel {
        let file = LocalModelFile(relativePath: "model.gguf", byteCount: 1024,
                                  sha256: String(repeating: "a", count: 64), role: .weights)
        let id = "ggml-org/gemma-4-E2B-it-GGUF#gemma-4-E2B-it-Q4_0.gguf"
        return try await backend.load(InstalledLocalModel(
            descriptor: LocalModelDescriptor(id: LocalModelID(id), displayName: "Test", runtime: .llamaCpp,
                                             repositoryID: "ggml-org/gemma-4-E2B-it-GGUF", revision: "abc123",
                                             files: [file], capabilities: [.text], contextLength: 4096,
                                             estimatedWeightsBytes: 1_000, estimatedWorkingBytes: 1_000,
                                             minimumHeadroomBytes: 0),
            storage: .managed(directoryName: LocalModelID(id).storageComponent),
            installedAt: Date(timeIntervalSince1970: 0), validatedFiles: [file]),
                                      configuration: LocalLoadConfiguration(contextLength: 4096))
    }

    // MARK: - Prefix reuse, pure (Plan MQ H3)

    func testTheReusablePrefixIsTheSharedStartLessTheTokenTheSamplerNeeds() {
        XCTAssertEqual(LlamaPromptCache.reusablePrefix(cached: [], prompt: [1, 2, 3]), 0)
        XCTAssertEqual(LlamaPromptCache.reusablePrefix(cached: [1, 2, 3, 9, 9], prompt: [1, 2, 3, 4, 5]), 3)
        XCTAssertEqual(LlamaPromptCache.reusablePrefix(cached: [1, 2, 3], prompt: [1, 2, 3, 4]), 3,
                       "a prompt that extends the cache keeps all of it")
        XCTAssertEqual(LlamaPromptCache.reusablePrefix(cached: [1, 2, 3], prompt: [1, 2, 3]), 2,
                       "an identical prompt still decodes its last token, for the logits")
        XCTAssertEqual(LlamaPromptCache.reusablePrefix(cached: [7, 2, 3], prompt: [1, 2, 3]), 0)
    }

    /// User and assistant messages, alternating, `exchanges` of each.
    private func conversation(exchanges: Int) -> [LocalToolLoop.Message] {
        (0..<exchanges).flatMap { [LocalToolLoop.Message.user("u\($0)"), .assistant("a\($0)")] }
    }

    func testTheBatchTrimDropsAQuarterOfTheRoomAtATime() throws {
        // 100 tokens of system and turn, 10 a message; budget 300, so the room is 200 and a batch 50.
        let count: ([LocalToolLoop.Message]) -> Int = { 100 + $0.count * 10 }
        let fits = conversation(exchanges: 10)   // 300 tokens: fits exactly
        XCTAssertEqual(LocalModelBudget.historyFittingBudgetInBatches(
            history: fits, budget: 300, startsExchange: { $0.role == .user }, tokenCount: count)?.count, 20)

        let over = conversation(exchanges: 11)   // 320: 20 over, so one batch of 50 goes
        let kept = try XCTUnwrap(LocalModelBudget.historyFittingBudgetInBatches(
            history: over, budget: 300, startsExchange: { $0.role == .user }, tokenCount: count))
        XCTAssertEqual(over.count - kept.count, 6, "50 tokens, rounded up to a whole exchange: three exchanges")
        XCTAssertEqual(kept.first?.role, .user, "the kept history starts an exchange")
        XCTAssertLessThanOrEqual(count(kept), 300)
    }

    func testTheTrimmedStartStaysPutUntilAnotherBatchHasGrown() throws {
        // The conversation grows by one exchange a turn; the first message kept must not move every turn.
        let count: ([LocalToolLoop.Message]) -> Int = { 100 + $0.count * 10 }
        var starts: [String] = []
        for exchanges in 11...16 {
            let history = conversation(exchanges: exchanges)
            let kept = try XCTUnwrap(LocalModelBudget.historyFittingBudgetInBatches(
                history: history, budget: 300, startsExchange: { $0.role == .user }, tokenCount: count))
            starts.append(kept.first?.content ?? "")
        }
        XCTAssertEqual(starts, ["u3", "u3", "u5", "u5", "u5", "u8"],
                       "the start moves a batch at a time, not an exchange at a time")

        // The one-at-a-time trim the MLX path uses moves it every turn.
        var singleStarts: [String] = []
        for exchanges in 11...13 {
            let history = conversation(exchanges: exchanges).map { (role: $0.role.rawValue, content: $0.content) }
            let kept = try LocalModelBudget.historyFittingBudget(history: history, budget: 300) { 100 + $0.count * 10 }
            singleStarts.append(kept.first?.content ?? "")
        }
        XCTAssertEqual(Set(singleStarts).count, 3)
    }

    func testNothingFitsWhenTheTurnAloneIsOverBudget() {
        XCTAssertNil(LocalModelBudget.historyFittingBudgetInBatches(
            history: conversation(exchanges: 2), budget: 50, startsExchange: { $0.role == .user },
            tokenCount: { 100 + $0.count }))
    }

}
