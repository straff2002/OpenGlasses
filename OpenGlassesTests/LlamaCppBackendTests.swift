import XCTest
@testable import OpenGlasses

/// Plan DZ P1/PR3 — the GGUF backend's load and generation flows, driven against a fake engine.
///
/// A fake at the `LlamaEngine` seam is the only instrument that can prove these properties here:
/// the simulator cannot run a Metal graph, and the things that most need proving — that a partial
/// load frees what it created in reverse order, that the KV cache is cleared on *every* request,
/// that an over-context prompt never reaches `llama_decode` — are statements about calls made and
/// not made, which no amount of real inference would let you observe.
///
/// What this file therefore does **not** claim: that a real GGUF file loads, that Metal works, or
/// that generated text is correct. Those are device evidence and stay outstanding.
final class LlamaCppBackendTests: XCTestCase {

    // MARK: - Fake engine

    private final class FakeLlamaEngine: LlamaEngine, @unchecked Sendable {

        enum Call: Equatable {
            case loadModel(String)
            case createContext(tokens: Int, batch: Int)
            case createSampler(seed: UInt32, temperature: Float)
            case applyTemplate(addAssistantHeader: Bool)
            case tokenize(addSpecial: Bool, parseSpecial: Bool)
            case clearMemory
            case resetSampler
            case decode(count: Int, position: Int, wantsLogits: Bool)
            case sample
            case setCancelled(Bool)
            case synchronize
            case freeSampler
            case freeContext
            case freeModel
        }

        enum Failure: Hashable {
            case modelLoad, contextCreate, samplerCreate, templateRender, tokenize, decode
        }

        private let lock = NSLock()
        private var _calls: [Call] = []
        private var _turnsByApplication: [[LlamaChatTurn]] = []
        private var _cancelled = false
        private var _allowance = 0
        private var _sampleIndex = 0

        // Configuration
        var metadata: [String: String] = [
            "general.architecture": "llama",
            "llama.context_length": "8192",
            "llama.block_count": "16",
            "llama.embedding_length": "1024",
            "llama.attention.head_count": "16",
            "llama.attention.head_count_kv": "4",
        ]
        var template: String? = "{{ messages }}"
        var trainingContext = 8192
        var contextTokensOverride: Int?
        var batchTokensOverride: Int?
        /// Fixed token count for a rendered prompt. `nil` uses one token per four characters.
        var promptTokenCount: Int?
        /// Bytes each successive sampled token produces. Exhausting the list ends generation.
        var outputPieces: [[UInt8]] = [Array("Hello".utf8), Array(" there".utf8)]
        var failures: Set<Failure> = []
        var vocabularyAddsBOSValue = false
        var bosPieceValue: String?
        /// When true, `sample` waits for an allowance before returning — the hook a cancellation
        /// test uses to stop a generation mid-stream deterministically.
        var gateSamples = false

        private static let endOfGenerationToken: LlamaToken = 9_999

        var calls: [Call] {
            lock.lock(); defer { lock.unlock() }
            return _calls
        }

        /// The turns handed to each `applyChatTemplate` call, in order. The probe exchange the
        /// template validator renders at load is included; generation calls follow it.
        var turnsByApplication: [[LlamaChatTurn]] {
            lock.lock(); defer { lock.unlock() }
            return _turnsByApplication
        }

        func allow(_ samples: Int) {
            lock.lock(); _allowance += samples; lock.unlock()
        }

        private func note(_ call: Call) {
            lock.lock(); _calls.append(call); lock.unlock()
        }

        // Model lifecycle

        func loadModel(atPath path: String, options: LlamaModelOptions) throws -> LlamaModelHandle {
            note(.loadModel(path))
            if failures.contains(.modelLoad) { throw LlamaEngineError.modelLoadFailed }
            return LlamaModelHandle(bits: 1)
        }

        func freeModel(_ model: LlamaModelHandle) { note(.freeModel) }

        // Metadata

        func metadataValue(_ model: LlamaModelHandle, key: String) -> String? { metadata[key] }
        func chatTemplate(_ model: LlamaModelHandle, named name: String?) -> String? { template }
        func trainingContextTokens(_ model: LlamaModelHandle) -> Int { trainingContext }
        func vocabularyAddsBOS(_ model: LlamaModelHandle) -> Bool { vocabularyAddsBOSValue }
        func beginningOfSequencePiece(_ model: LlamaModelHandle) -> String? { bosPieceValue }

        func isEndOfGeneration(_ model: LlamaModelHandle, token: LlamaToken) -> Bool {
            token == Self.endOfGenerationToken
        }

        // Template and tokenization

        func applyChatTemplate(_ template: String,
                               turns: [LlamaChatTurn],
                               addAssistantHeader: Bool) throws -> String {
            note(.applyTemplate(addAssistantHeader: addAssistantHeader))
            lock.lock(); _turnsByApplication.append(turns); lock.unlock()
            if failures.contains(.templateRender) { throw LlamaEngineError.templateFailed }
            var out = ""
            for turn in turns { out += "<|start|>\(turn.role)\n\(turn.content)<|end|>\n" }
            if addAssistantHeader { out += "<|start|>assistant\n" }
            return out
        }

        func tokenize(_ model: LlamaModelHandle,
                      text: String,
                      addSpecial: Bool,
                      parseSpecial: Bool) throws -> [LlamaToken] {
            note(.tokenize(addSpecial: addSpecial, parseSpecial: parseSpecial))
            if failures.contains(.tokenize) { throw LlamaEngineError.tokenizeFailed }
            let count = promptTokenCount ?? max(1, text.count / 4)
            return (0..<count).map { LlamaToken($0) }
        }

        func tokenBytes(_ model: LlamaModelHandle, token: LlamaToken) -> [UInt8] {
            let index = Int(token)
            guard index >= 0, index < outputPieces.count else { return [] }
            return outputPieces[index]
        }

        // Context lifecycle

        func createContext(_ model: LlamaModelHandle,
                           options: LlamaContextOptions) throws -> LlamaContextHandle {
            note(.createContext(tokens: options.contextTokens, batch: options.batchTokens))
            if failures.contains(.contextCreate) { throw LlamaEngineError.contextCreateFailed }
            contextTokensOverride = contextTokensOverride ?? options.contextTokens
            batchTokensOverride = batchTokensOverride ?? options.batchTokens
            return LlamaContextHandle(bits: 2)
        }

        func freeContext(_ context: LlamaContextHandle) { note(.freeContext) }
        func contextTokens(_ context: LlamaContextHandle) -> Int { contextTokensOverride ?? 0 }
        func batchTokens(_ context: LlamaContextHandle) -> Int { batchTokensOverride ?? 0 }
        func clearMemory(_ context: LlamaContextHandle) { note(.clearMemory) }
        func synchronize(_ context: LlamaContextHandle) { note(.synchronize) }

        func setCancelled(_ context: LlamaContextHandle, _ cancelled: Bool) {
            note(.setCancelled(cancelled))
            lock.lock(); _cancelled = cancelled; lock.unlock()
        }

        func decode(_ context: LlamaContextHandle,
                    tokens: [LlamaToken],
                    position: Int,
                    wantsLogitsForLast: Bool) throws {
            note(.decode(count: tokens.count, position: position, wantsLogits: wantsLogitsForLast))
            if failures.contains(.decode) { throw LlamaEngineError.decodeFailed }
        }

        // Sampling

        func createSampler(_ model: LlamaModelHandle,
                           options: LlamaSamplerOptions) throws -> LlamaSamplerHandle {
            note(.createSampler(seed: options.seed, temperature: options.temperature))
            if failures.contains(.samplerCreate) { throw LlamaEngineError.samplerCreateFailed }
            return LlamaSamplerHandle(bits: 3)
        }

        func freeSampler(_ sampler: LlamaSamplerHandle) { note(.freeSampler) }

        func resetSampler(_ sampler: LlamaSamplerHandle) {
            note(.resetSampler)
            lock.lock(); _sampleIndex = 0; lock.unlock()
        }

        func sample(_ sampler: LlamaSamplerHandle, context: LlamaContextHandle) throws -> LlamaToken {
            note(.sample)
            if gateSamples {
                // Spins rather than blocking on a semaphore so a cancellation can always break the
                // wait; the loop runs on its own task, so only that task is held here.
                while true {
                    lock.lock()
                    let cancelled = _cancelled
                    let permitted = _allowance > 0
                    if permitted { _allowance -= 1 }
                    lock.unlock()
                    if cancelled || permitted { break }
                    Thread.sleep(forTimeInterval: 0.002)
                }
            }
            lock.lock()
            let cancelled = _cancelled
            let index = _sampleIndex
            _sampleIndex += 1
            lock.unlock()
            if cancelled { throw LlamaEngineError.cancelled }
            return index < outputPieces.count ? LlamaToken(index) : Self.endOfGenerationToken
        }
    }

    // MARK: - Fixtures

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gguf-backend-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Writes a stand-in weights file and returns a matching installation record.
    @discardableResult
    private func makeInstallation(id: String = "gguf/test-model",
                                  runtime: LocalModelRuntime = .llamaCpp,
                                  contextLength: Int = 4096,
                                  declaredByteCount: Int64? = nil,
                                  writeWeights: Bool = true,
                                  capabilities: Set<LocalModelCapability> = [.text])
        throws -> InstalledLocalModel {
        let weights = directory.appendingPathComponent("model.gguf")
        let bytes = Data(repeating: 0x47, count: 1024)
        if writeWeights { try bytes.write(to: weights) }
        let file = LocalModelFile(relativePath: "model.gguf",
                                  byteCount: declaredByteCount ?? Int64(bytes.count),
                                  sha256: String(repeating: "a", count: 64),
                                  role: .weights)
        return InstalledLocalModel(
            descriptor: LocalModelDescriptor(id: LocalModelID(id),
                                             displayName: "Test",
                                             runtime: runtime,
                                             repositoryID: id,
                                             revision: "abc123",
                                             files: [file],
                                             capabilities: capabilities,
                                             contextLength: contextLength,
                                             estimatedWeightsBytes: 1_000,
                                             estimatedWorkingBytes: 1_000,
                                             minimumHeadroomBytes: 0),
            storage: .managed(directoryName: LocalModelID(id).storageComponent),
            installedAt: Date(timeIntervalSince1970: 0),
            validatedFiles: [file])
    }

    private func makeBackend(_ engine: FakeLlamaEngine,
                             enabled: Bool = true,
                             availableBytes: Int64 = 0) -> LlamaCppLocalInferenceBackend {
        let root = directory!
        return LlamaCppLocalInferenceBackend(
            engine: engine,
            directoryForInstallation: { _ in root },
            availableProcessBytes: { availableBytes },
            appFootprintBytes: { 0 },
            thermalState: { .nominal },
            monotonicNanoseconds: { 0 },
            isRuntimeEnabled: { enabled })
    }

    private let configuration = LocalLoadConfiguration(contextLength: 4096, batchSize: 512)

    private func request(_ messages: [LocalChatMessage],
                         maxOutputTokens: Int = 64,
                         sampling: LocalSamplingConfiguration = .conservative,
                         stopSequences: [String] = [],
                         images: [LocalImageInput] = []) -> LocalGenerationRequest {
        LocalGenerationRequest(messages: messages,
                               images: images,
                               maxOutputTokens: maxOutputTokens,
                               sampling: sampling,
                               stopSequences: stopSequences)
    }

    private func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> String {
        var text = ""
        for try await chunk in stream { text += chunk }
        return text
    }

    private let oneTurn: [LocalChatMessage] = [.system("Be brief."), .user("Hello?")]

    // MARK: - Load flow

    func testLoadCreatesModelThenContextThenSampler() async throws {
        let engine = FakeLlamaEngine()
        let backend = makeBackend(engine)
        let loaded = try await backend.load(try makeInstallation(), configuration: configuration)

        XCTAssertEqual(loaded.runtime, .llamaCpp)
        XCTAssertFalse(loaded.supportsVision, "the text-only phase never advertises vision")
        let creations = engine.calls.filter {
            if case .loadModel = $0 { return true }
            if case .createContext = $0 { return true }
            if case .createSampler = $0 { return true }
            return false
        }
        XCTAssertEqual(creations.count, 3)
        guard case .loadModel = creations[0], case .createContext = creations[1],
              case .createSampler = creations[2] else {
            return XCTFail("resources must be created model → context → sampler")
        }
    }

    /// The exit criterion's teardown property, made observable by failing the last creation step.
    func testAFailedSamplerCreateTearsDownInReverseOrder() async throws {
        let engine = FakeLlamaEngine()
        engine.failures = [.samplerCreate]
        let backend = makeBackend(engine)

        do {
            _ = try await backend.load(try makeInstallation(), configuration: configuration)
            XCTFail("expected the load to fail")
        } catch {
            XCTAssertEqual(error as? LlamaBackendError, .engine(.samplerCreateFailed))
        }
        XCTAssertEqual(engine.calls.suffix(3), [.synchronize, .freeContext, .freeModel],
                       "the accelerator drains first, then resources free in reverse creation order")
        XCTAssertFalse(engine.calls.contains(.freeSampler), "nothing was created to free")
        let resident = await backend.loadedModel
        XCTAssertNil(resident)
    }

    func testAFailedContextCreateFreesOnlyTheModel() async throws {
        let engine = FakeLlamaEngine()
        engine.failures = [.contextCreate]
        let backend = makeBackend(engine)

        do {
            _ = try await backend.load(try makeInstallation(), configuration: configuration)
            XCTFail("expected the load to fail")
        } catch {
            XCTAssertEqual(error as? LlamaBackendError, .engine(.contextCreateFailed))
        }
        XCTAssertEqual(engine.calls.last, .freeModel)
        XCTAssertFalse(engine.calls.contains(.freeContext))
        XCTAssertFalse(engine.calls.contains(.synchronize),
                       "there is no context whose accelerator work needs draining")
    }

    func testAModelWithNoUsableChatTemplateIsRefusedAndUnloaded() async throws {
        let engine = FakeLlamaEngine()
        engine.template = nil
        let backend = makeBackend(engine)

        do {
            _ = try await backend.load(try makeInstallation(), configuration: configuration)
            XCTFail("expected the load to fail")
        } catch {
            XCTAssertEqual(error as? LlamaBackendError, .unsupportedChatTemplate(.absent))
        }
        XCTAssertEqual(engine.calls.last, .freeModel)
        XCTAssertFalse(engine.calls.contains { if case .createContext = $0 { return true }; return false },
                       "a model that cannot chat must not pay for a context")
    }

    func testATemplateThatCannotRenderTheProbeIsRefused() async throws {
        let engine = FakeLlamaEngine()
        engine.failures = [.templateRender]
        let backend = makeBackend(engine)

        do {
            _ = try await backend.load(try makeInstallation(), configuration: configuration)
            XCTFail("expected the load to fail")
        } catch {
            XCTAssertEqual(error as? LlamaBackendError, .unsupportedChatTemplate(.renderFailed))
        }
    }

    func testAFileThatDoesNotDeclareItsArchitectureIsRefused() async throws {
        let engine = FakeLlamaEngine()
        engine.metadata = ["llama.block_count": "16"]
        let backend = makeBackend(engine)

        do {
            _ = try await backend.load(try makeInstallation(), configuration: configuration)
            XCTFail("expected the load to fail")
        } catch {
            XCTAssertEqual(error as? LlamaBackendError, .unsupportedArchitecture)
        }
        XCTAssertEqual(engine.calls.last, .freeModel)
    }

    func testContextIsClampedToTheModelsTrainedLength() async throws {
        let engine = FakeLlamaEngine()
        engine.trainingContext = 2048
        let backend = makeBackend(engine)
        _ = try await backend.load(try makeInstallation(contextLength: 32_768),
                                   configuration: LocalLoadConfiguration(contextLength: 16_384,
                                                                         batchSize: 512))
        XCTAssertTrue(engine.calls.contains(.createContext(tokens: 2048, batch: 512)))
    }

    func testTheBatchNeverExceedsTheContext() async throws {
        let engine = FakeLlamaEngine()
        engine.trainingContext = 768
        let backend = makeBackend(engine)
        _ = try await backend.load(try makeInstallation(contextLength: 768),
                                   configuration: LocalLoadConfiguration(contextLength: 768,
                                                                         batchSize: 4096))
        XCTAssertTrue(engine.calls.contains(.createContext(tokens: 768, batch: 768)))
    }

    func testReloadingTheResidentModelDoesNotRebuildIt() async throws {
        let engine = FakeLlamaEngine()
        let backend = makeBackend(engine)
        let installation = try makeInstallation()
        _ = try await backend.load(installation, configuration: configuration)
        let before = engine.calls.count
        _ = try await backend.load(installation, configuration: configuration)
        XCTAssertEqual(engine.calls.count, before)
    }

    // MARK: - Load refusals that never reach the engine

    func testWithTheFlagOffNothingTouchesTheEngine() async throws {
        let engine = FakeLlamaEngine()
        let backend = makeBackend(engine, enabled: false)

        do {
            _ = try await backend.load(try makeInstallation(), configuration: configuration)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? LlamaBackendError, .runtimeDisabled)
        }
        XCTAssertTrue(engine.calls.isEmpty,
                      "a disabled runtime must not open a model file, let alone load one")
    }

    func testAnMLXInstallationIsRefusedByRuntime() async throws {
        let engine = FakeLlamaEngine()
        let backend = makeBackend(engine)
        do {
            _ = try await backend.load(try makeInstallation(runtime: .mlx),
                                       configuration: configuration)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? LocalInferenceError, .noBackend(.mlx))
        }
        XCTAssertTrue(engine.calls.isEmpty)
    }

    func testAMissingWeightsFileIsRefusedBeforeTheEngineIsAsked() async throws {
        let engine = FakeLlamaEngine()
        let backend = makeBackend(engine)
        do {
            _ = try await backend.load(try makeInstallation(writeWeights: false),
                                       configuration: configuration)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? LlamaBackendError,
                           .weightsMissing(LocalModelID("gguf/test-model")))
        }
        XCTAssertTrue(engine.calls.isEmpty)
    }

    func testAFileWhoseSizeDisagreesWithTheManifestIsRefused() async throws {
        let engine = FakeLlamaEngine()
        let backend = makeBackend(engine)
        do {
            _ = try await backend.load(try makeInstallation(declaredByteCount: 999_999),
                                       configuration: configuration)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? LlamaBackendError,
                           .installationIncomplete(LocalModelID("gguf/test-model")))
        }
    }

    func testALoadThatDoesNotFitAvailableMemoryIsRefused() async throws {
        let engine = FakeLlamaEngine()
        // A budget far below the runtime's working set: admission must refuse before any file work.
        let backend = makeBackend(engine, availableBytes: 8 * 1024 * 1024)
        do {
            _ = try await backend.load(try makeInstallation(), configuration: configuration)
            XCTFail("expected a refusal")
        } catch {
            guard case .insufficientMemory = (error as? LlamaBackendError) else {
                return XCTFail("expected a typed memory refusal, got \(error)")
            }
        }
        XCTAssertTrue(engine.calls.isEmpty)
    }

    // MARK: - Generation flow

    func testGenerationStreamsTheConcatenatedTokenPieces() async throws {
        let engine = FakeLlamaEngine()
        let backend = makeBackend(engine)
        _ = try await backend.load(try makeInstallation(), configuration: configuration)

        let text = try await collect(backend.generate(request(oneTurn)))
        XCTAssertEqual(text, "Hello there")
    }

    /// The byte accumulator, exercised through the real loop rather than in isolation: each token
    /// carries one byte of a four-byte scalar.
    func testSplitMultiByteTokensReachTheStreamWhole() async throws {
        let engine = FakeLlamaEngine()
        engine.outputPieces = Array("🙂".utf8).map { [$0] } + [Array("!".utf8)]
        let backend = makeBackend(engine)
        _ = try await backend.load(try makeInstallation(), configuration: configuration)

        let text = try await collect(backend.generate(request(oneTurn)))
        XCTAssertEqual(text, "🙂!")
        XCTAssertFalse(text.contains("\u{FFFD}"))
    }

    func testEveryRequestClearsTheKVCacheAndThePenaltyHistory() async throws {
        let engine = FakeLlamaEngine()
        let backend = makeBackend(engine)
        _ = try await backend.load(try makeInstallation(), configuration: configuration)

        _ = try await collect(backend.generate(request(oneTurn)))
        _ = try await collect(backend.generate(request(oneTurn + [.assistant("Hi."), .user("More?")])))

        XCTAssertEqual(engine.calls.filter { $0 == .clearMemory }.count, 2)
        XCTAssertEqual(engine.calls.filter { $0 == .resetSampler }.count, 2)
    }

    /// The exit criterion: "a second turn contains exactly one copy of each prior message". Asserted
    /// on the assembled prompt, because that is where a duplicate would be introduced — the output
    /// looking plausible would prove nothing.
    func testASecondTurnRendersEachPriorMessageExactlyOnce() async throws {
        let engine = FakeLlamaEngine()
        let backend = makeBackend(engine)
        _ = try await backend.load(try makeInstallation(), configuration: configuration)

        _ = try await collect(backend.generate(request(oneTurn)))
        let secondTurn = oneTurn + [.assistant("Hello there"), .user("And again?")]
        _ = try await collect(backend.generate(request(secondTurn)))

        // The last application is the second turn's; the earlier ones are the load-time probe and
        // the first turn.
        let turns = try XCTUnwrap(engine.turnsByApplication.last)
        XCTAssertEqual(turns.map(\.role), ["system", "user", "assistant", "user"])
        for message in secondTurn {
            XCTAssertEqual(turns.filter { $0.content == message.content }.count, 1,
                           "\(message.content) must appear exactly once")
        }
    }

    func testAPromptLongerThanTheBatchIsDecodedInChunks() async throws {
        let engine = FakeLlamaEngine()
        engine.promptTokenCount = 1_100
        let backend = makeBackend(engine)
        _ = try await backend.load(try makeInstallation(), configuration: configuration)

        _ = try await collect(backend.generate(request(oneTurn)))

        let promptDecodes = engine.calls.compactMap { call -> (Int, Int, Bool)? in
            guard case .decode(let count, let position, let wantsLogits) = call else { return nil }
            return (count, position, wantsLogits)
        }.prefix(3)
        XCTAssertEqual(promptDecodes.map(\.0), [512, 512, 76])
        XCTAssertEqual(promptDecodes.map(\.1), [0, 512, 1024])
        XCTAssertEqual(promptDecodes.map(\.2), [false, false, true],
                       "only the final chunk needs logits")
        XCTAssertTrue(promptDecodes.allSatisfy { $0.0 <= 512 })
    }

    func testAnOverContextPromptFailsBeforeAnyDecode() async throws {
        let engine = FakeLlamaEngine()
        engine.trainingContext = 1024
        engine.promptTokenCount = 1_000
        let backend = makeBackend(engine)
        _ = try await backend.load(try makeInstallation(contextLength: 1024),
                                   configuration: LocalLoadConfiguration(contextLength: 1024,
                                                                         batchSize: 512))

        do {
            _ = try await collect(backend.generate(request(oneTurn, maxOutputTokens: 256)))
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? LlamaBackendError,
                           .promptTooLong(promptTokens: 1_000, reserveTokens: 256,
                                          contextTokens: 1024))
        }
        XCTAssertFalse(engine.calls.contains { if case .decode = $0 { return true }; return false },
                       "the refusal must land before the native decode, not inside it")
    }

    func testImagesAreRefusedInTheTextOnlyPhase() async throws {
        let engine = FakeLlamaEngine()
        let backend = makeBackend(engine)
        _ = try await backend.load(try makeInstallation(), configuration: configuration)

        do {
            _ = try await collect(backend.generate(
                request(oneTurn, images: [LocalImageInput(data: Data([0x01]))])))
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? LocalInferenceError, .visionNotAvailable)
        }
    }

    func testGeneratingWithNothingResidentIsRefused() async throws {
        let engine = FakeLlamaEngine()
        let backend = makeBackend(engine)
        do {
            _ = try await collect(backend.generate(request(oneTurn)))
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? LlamaBackendError, .notLoaded)
        }
    }

    func testAStopSequenceEndsGenerationWithoutEmittingIt() async throws {
        let engine = FakeLlamaEngine()
        engine.outputPieces = [Array("Answer".utf8), Array("<|halt|>".utf8), Array(" more".utf8)]
        let backend = makeBackend(engine)
        _ = try await backend.load(try makeInstallation(), configuration: configuration)

        let text = try await collect(backend.generate(request(oneTurn, stopSequences: ["<|halt|>"])))
        XCTAssertEqual(text, "Answer")
    }

    func testOutputIsCappedAtTheRequestedTokenCount() async throws {
        let engine = FakeLlamaEngine()
        engine.outputPieces = (0..<50).map { Array("\($0) ".utf8) }
        let backend = makeBackend(engine)
        _ = try await backend.load(try makeInstallation(), configuration: configuration)

        _ = try await collect(backend.generate(request(oneTurn, maxOutputTokens: 5)))
        XCTAssertEqual(engine.calls.filter { $0 == .sample }.count, 5)
    }

    func testADecodeFailureSurfacesAsATypedEngineError() async throws {
        let engine = FakeLlamaEngine()
        engine.failures = [.decode]
        let backend = makeBackend(engine)
        _ = try await backend.load(try makeInstallation(), configuration: configuration)

        do {
            _ = try await collect(backend.generate(request(oneTurn)))
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? LlamaBackendError, .engine(.decodeFailed))
        }
    }

    // MARK: - Sampling

    func testAPinnedSeedReachesTheSamplerForThatRequest() async throws {
        let engine = FakeLlamaEngine()
        let backend = makeBackend(engine)
        _ = try await backend.load(try makeInstallation(), configuration: configuration)

        _ = try await collect(backend.generate(
            request(oneTurn, sampling: LocalSamplingConfiguration(temperature: 0.1, seed: 4_242))))

        XCTAssertTrue(engine.calls.contains(.createSampler(seed: 4_242, temperature: 0.1)),
                      "a pinned seed is what makes a generation reproducible")
        // The old chain is freed only after the replacement exists.
        let samplerCalls = engine.calls.filter { call in
            if case .createSampler = call { return true }
            return call == .freeSampler
        }
        XCTAssertEqual(samplerCalls.count, 3)
        XCTAssertEqual(samplerCalls.last, .freeSampler)
    }

    func testTheDefaultSamplerIsNotRebuiltForADefaultRequest() async throws {
        let engine = FakeLlamaEngine()
        let backend = makeBackend(engine)
        _ = try await backend.load(try makeInstallation(), configuration: configuration)
        _ = try await collect(backend.generate(request(oneTurn)))

        let creations = engine.calls.filter { if case .createSampler = $0 { return true }; return false }
        XCTAssertEqual(creations.count, 1, "an unchanged sampler must not be rebuilt per turn")
    }

    // MARK: - Cancellation and unload

    func testCancellationStopsDeliveryAndLeavesTheBackendUsable() async throws {
        let engine = FakeLlamaEngine()
        engine.gateSamples = true
        engine.outputPieces = (0..<50).map { Array("\($0) ".utf8) }
        let backend = makeBackend(engine)
        _ = try await backend.load(try makeInstallation(), configuration: configuration)

        engine.allow(1)
        // The stream is held for the whole test: dropping it while iterating would terminate the
        // continuation as `.cancelled` and cancel the very generation this test means to cancel
        // explicitly.
        let stream = backend.generate(request(oneTurn, maxOutputTokens: 50))
        var iterator = stream.makeAsyncIterator()
        let first = try await iterator.next()
        XCTAssertEqual(first, "0 ")

        await backend.cancelGeneration()

        do {
            while try await iterator.next() != nil {}
            XCTFail("expected the stream to end in cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
        XCTAssertTrue(engine.calls.contains(.setCancelled(true)))
        XCTAssertTrue(engine.calls.contains(.setCancelled(false)),
                      "the flag is cleared so the context stays usable for the next turn")
        XCTAssertLessThan(engine.calls.filter { $0 == .sample }.count, 50)
        // The model is still resident: cancelling a turn is not unloading a model.
        let resident = await backend.loadedModel
        XCTAssertNotNil(resident)
    }

    func testUnloadCancelsFirstThenFreesInReverseOrder() async throws {
        let engine = FakeLlamaEngine()
        let backend = makeBackend(engine)
        _ = try await backend.load(try makeInstallation(), configuration: configuration)
        _ = try await collect(backend.generate(request(oneTurn)))

        await backend.unload()

        XCTAssertEqual(engine.calls.suffix(3), [.freeSampler, .freeContext, .freeModel])
        let resident = await backend.loadedModel
        XCTAssertNil(resident)
    }

    func testUnloadingWithNothingResidentIsSafe() async {
        let engine = FakeLlamaEngine()
        let backend = makeBackend(engine)
        await backend.unload()
        XCTAssertTrue(engine.calls.isEmpty)
    }

    // MARK: - Coordinator integration

    /// The residency exit criterion, minus the device: switching runtimes must leave exactly one
    /// allocation, and the outgoing backend must have been torn down before the incoming load.
    func testSwitchingGGUFToMLXToGGUFLeavesOneResidentAllocation() async throws {
        let engine = FakeLlamaEngine()
        let gguf = makeBackend(engine)
        let mlx = RecordingBackend(runtime: .mlx)
        let coordinator = LocalInferenceCoordinator(backends: [gguf, mlx])

        let ggufModel = try makeInstallation(id: "gguf/one")
        let mlxModel = try makeInstallation(id: "mlx/one", runtime: .mlx)

        _ = try await coordinator.load(ggufModel, configuration: configuration)
        _ = try await coordinator.load(mlxModel, configuration: configuration)
        XCTAssertEqual(engine.calls.suffix(3), [.freeSampler, .freeContext, .freeModel],
                       "the GGUF allocation is released before MLX takes residency")
        let afterMLX = await gguf.loadedModel
        XCTAssertNil(afterMLX)

        _ = try await coordinator.load(ggufModel, configuration: configuration)
        XCTAssertEqual(mlx.calls.suffix(2), [.cancel, .unload])
        let resident = await coordinator.loadedModel
        XCTAssertEqual(resident?.id, LocalModelID("gguf/one"))
        let ggufResident = await gguf.loadedModel
        XCTAssertNotNil(ggufResident)
    }

    /// With GGUF off, the MLX route is untouched — the rollback promise, stated as a test.
    func testWithGGUFOffTheMLXRouteIsUnaffected() async throws {
        let engine = FakeLlamaEngine()
        let gguf = makeBackend(engine, enabled: false)
        let mlx = RecordingBackend(runtime: .mlx)
        let coordinator = LocalInferenceCoordinator(backends: [gguf, mlx])

        let loaded = try await coordinator.load(try makeInstallation(id: "mlx/one", runtime: .mlx),
                                                configuration: configuration)
        XCTAssertEqual(loaded.runtime, .mlx)
        XCTAssertTrue(engine.calls.isEmpty)

        do {
            _ = try await coordinator.load(try makeInstallation(id: "gguf/one"),
                                           configuration: configuration)
            XCTFail("expected the disabled runtime to refuse")
        } catch {
            XCTAssertEqual(error as? LlamaBackendError, .runtimeDisabled)
        }
    }

    /// A stand-in for the other runtime. Only its call order matters here.
    private final class RecordingBackend: LocalInferenceBackend, @unchecked Sendable {
        enum Call: Equatable { case load, cancel, unload }

        let runtime: LocalModelRuntime
        private let lock = NSLock()
        private var _calls: [Call] = []
        private var _resident: LocalLoadedModel?

        init(runtime: LocalModelRuntime) { self.runtime = runtime }

        var calls: [Call] {
            lock.lock(); defer { lock.unlock() }
            return _calls
        }

        var loadedModel: LocalLoadedModel? {
            lock.lock(); defer { lock.unlock() }
            return _resident
        }

        func load(_ installation: InstalledLocalModel,
                  configuration: LocalLoadConfiguration) async throws -> LocalLoadedModel {
            lock.lock(); _calls.append(.load); lock.unlock()
            let loaded = LocalLoadedModel(id: installation.id, runtime: runtime,
                                          contextLength: configuration.contextLength,
                                          capabilities: [.text])
            lock.lock(); _resident = loaded; lock.unlock()
            return loaded
        }

        func generate(_ request: LocalGenerationRequest) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { $0.finish() }
        }

        func cancelGeneration() async {
            lock.lock(); _calls.append(.cancel); lock.unlock()
        }

        func unload() async {
            lock.lock(); _calls.append(.unload); _resident = nil; lock.unlock()
        }
    }
}
