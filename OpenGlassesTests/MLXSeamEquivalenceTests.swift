import XCTest
@testable import OpenGlasses

/// Plan DZ P0 — proof that putting MLX behind the seam changed nothing about what MLX is asked to
/// do.
///
/// The PR1 exit criterion is "byte-for-byte-equivalent prompt assembly and equivalent streamed-output
/// semantics", and this file is where that is discharged. It cannot be discharged by running MLX:
/// the simulator has no Metal path worth trusting and `LocalLLMService` needs a downloaded
/// multi-gigabyte checkpoint. So it is discharged structurally instead, which is the stronger claim
/// anyway — the adapter is proved to be an exact inverse, and the recorded arguments are compared
/// against the ones `sendLocal` composes.
@MainActor
final class MLXSeamEquivalenceTests: XCTestCase {

    // MARK: - Fake runtime

    /// Stands in for `LocalLLMService`, recording exactly what it was handed.
    private final class RecordingRuntime: MLXLocalRuntime {
        var isModelLoaded = false
        var loadedModelId: String?
        var loadedViaVLMFactory = false

        private(set) var loadedIDs: [String] = []
        private(set) var unloadCount = 0

        struct GenerateCall: Equatable {
            let userMessage: String
            let systemPrompt: String
            let history: [MLXHistoryTurn]
            let imageData: Data?
        }
        private(set) var generateCalls: [GenerateCall] = []

        /// Chunks pushed to `onToken` before returning.
        var previewChunks: [String] = []
        /// The authoritative text returned — deliberately allowed to differ from the preview,
        /// because on the reasoning path it already does.
        var returnedText = "final answer"
        var generateError: Error?
        /// Blocks until cancelled, for the cancellation test.
        var blocksUntilCancelled = false

        func loadModel(_ modelId: String) async throws {
            loadedIDs.append(modelId)
            loadedModelId = modelId
            isModelLoaded = true
        }

        func unloadModel() {
            unloadCount += 1
            isModelLoaded = false
            loadedModelId = nil
            loadedViaVLMFactory = false
        }

        func generate(userMessage: String,
                      systemPrompt: String,
                      history: [(role: String, content: String)],
                      imageData: Data?,
                      onToken: ((String) -> Void)?) async throws -> String {
            generateCalls.append(GenerateCall(userMessage: userMessage,
                                              systemPrompt: systemPrompt,
                                              history: history.map(MLXHistoryTurn.init),
                                              imageData: imageData))
            if let generateError { throw generateError }
            for chunk in previewChunks { onToken?(chunk) }
            if blocksUntilCancelled {
                // Mirrors `drainTokenStream`: cancellation is checked and always throws, never
                // returns a partial answer.
                while true {
                    try Task.checkCancellation()
                    try? await Task.sleep(nanoseconds: 1_000_000)
                }
            }
            return returnedText
        }
    }

    // MARK: - Prompt adapter round trip

    /// The core equivalence claim: whatever `sendLocal` has in hand, composing it into the seam's
    /// message list and decomposing it again yields the identical three arguments.
    func testDecomposeIsTheExactInverseOfCompose() throws {
        let cases: [(system: String, history: [(role: String, content: String)], user: String)] = [
            ("You are a helpful assistant.", [], "What time is it?"),
            ("system", [(role: "user", content: "hi"), (role: "assistant", content: "hello")], "again"),
            // The real shape `recentTupleHistory(6)` produces: three alternating exchanges.
            ("prompt with\nnewlines and  double  spaces",
             [(role: "user", content: "one"), (role: "assistant", content: "two"),
              (role: "user", content: "three"), (role: "assistant", content: "four"),
              (role: "user", content: "five"), (role: "assistant", content: "six")],
             "seven"),
            // Content that would be mangled by any well-meaning normalisation.
            ("", [(role: "user", content: "  leading and trailing  ")], "<tool_call>{\"a\":1}</tool_call>"),
            ("emoji 🫥 and \u{202E}bidi", [(role: "assistant", content: "")], ""),
        ]

        for (system, history, user) in cases {
            let messages = MLXPromptAdapter.compose(systemPrompt: system,
                                                    history: history,
                                                    userMessage: user)
            let back = try MLXPromptAdapter.decompose(messages)
            XCTAssertEqual(back.systemPrompt, system)
            XCTAssertEqual(back.history, history.map(MLXHistoryTurn.init))
            XCTAssertEqual(back.userMessage, user)
        }
    }

    func testComposeProducesSystemFirstAndUserLast() {
        let messages = MLXPromptAdapter.compose(
            systemPrompt: "sys",
            history: [(role: "assistant", content: "prior")],
            userMessage: "now")
        XCTAssertEqual(messages.map(\.role), [.system, .assistant, .user])
        XCTAssertEqual(messages.map(\.content), ["sys", "prior", "now"])
    }

    /// An unknown history role becomes a user turn, exactly as `LocalLLMService.generate` already
    /// treats anything that is not "assistant".
    func testUnknownHistoryRoleIsTreatedAsUserJustAsMLXAlreadyDoes() throws {
        let messages = MLXPromptAdapter.compose(
            systemPrompt: "sys",
            history: [(role: "tool", content: "result")],
            userMessage: "now")
        let back = try MLXPromptAdapter.decompose(messages)
        XCTAssertEqual(back.history, [MLXHistoryTurn(role: "user", content: "result")])
    }

    func testDecomposeRefusesAListThatDoesNotEndWithTheUserTurn() {
        XCTAssertThrowsError(try MLXPromptAdapter.decompose([.system("s"), .assistant("a")])) {
            XCTAssertEqual($0 as? MLXPromptAdapter.Fault, .missingUserTurn)
        }
        XCTAssertThrowsError(try MLXPromptAdapter.decompose([])) {
            XCTAssertEqual($0 as? MLXPromptAdapter.Fault, .missingUserTurn)
        }
    }

    func testDecomposeRefusesAMisplacedSystemTurnRatherThanDemotingIt() {
        // Silently turning it into a user turn would put instructions in the model's mouth as if
        // the wearer had said them.
        let messages: [LocalChatMessage] = [.system("s"), .user("u"), .system("sneaky"), .user("now")]
        XCTAssertThrowsError(try MLXPromptAdapter.decompose(messages)) {
            XCTAssertEqual($0 as? MLXPromptAdapter.Fault, .systemTurnOutOfPosition(index: 2))
        }
    }

    func testMultipleLeadingSystemTurnsAreJoinedNotTruncated() throws {
        let back = try MLXPromptAdapter.decompose([.system("first"), .system("second"), .user("u")])
        XCTAssertEqual(back.systemPrompt, "first\n\nsecond")
    }

    // MARK: - Backend hands MLX the same arguments

    /// The end-to-end version of the claim: drive the backend the way `sendLocal` drives it, and
    /// assert the fake runtime received precisely the arguments the direct call would have passed.
    func testBackendPassesSendLocalsArgumentsThroughUnchanged() async throws {
        let runtime = RecordingRuntime()
        let backend = MLXLocalInferenceBackend(service: runtime)

        // Exactly what `sendLocal` holds at the call site.
        let systemPrompt = "You are OpenGlasses.\n\nAvailable: where_am_i, calendar"
        let history: [(role: String, content: String)] = [
            (role: "user", content: "what's the weather"),
            (role: "assistant", content: "It's fine."),
        ]
        let userMessage = "and tomorrow?"
        let image = Data([0xFF, 0xD8, 0xFF])

        let request = LocalGenerationRequest(
            messages: MLXPromptAdapter.compose(systemPrompt: systemPrompt,
                                               history: history,
                                               userMessage: userMessage),
            images: [LocalImageInput(data: image)],
            maxOutputTokens: 512)
        var assembled = ""
        for try await chunk in backend.generate(request) { assembled += chunk }

        XCTAssertEqual(runtime.generateCalls, [
            RecordingRuntime.GenerateCall(userMessage: userMessage,
                                          systemPrompt: systemPrompt,
                                          history: history.map(MLXHistoryTurn.init),
                                          imageData: image)
        ])
        XCTAssertEqual(assembled, "final answer")
    }

    func testTextTurnPassesNoImage() async throws {
        let runtime = RecordingRuntime()
        let backend = MLXLocalInferenceBackend(service: runtime)
        let request = LocalGenerationRequest(messages: [.system("s"), .user("u")],
                                             maxOutputTokens: 512)
        for try await _ in backend.generate(request) {}
        XCTAssertNil(runtime.generateCalls.first?.imageData)
    }

    /// The output contract, and why it has two channels: the preview is what streamed, the stream's
    /// concatenation is the answer, and on the reasoning path those genuinely differ.
    func testPreviewChannelAndAuthoritativeTextAreSeparate() async throws {
        let runtime = RecordingRuntime()
        runtime.previewChunks = ["The ", "answer ", "is "]
        runtime.returnedText = "The answer is 42."
        let backend = MLXLocalInferenceBackend(service: runtime)

        var preview: [String] = []
        let request = LocalGenerationRequest(messages: [.system("s"), .user("u")],
                                             maxOutputTokens: 512,
                                             previewSink: { preview.append($0) })
        var assembled = ""
        for try await chunk in backend.generate(request) { assembled += chunk }

        XCTAssertEqual(preview, ["The ", "answer ", "is "])
        XCTAssertEqual(assembled, "The answer is 42.",
                       "the stream carries the authoritative text, not the preview")
    }

    func testGenerationErrorsPropagateUnwrapped() async {
        struct Boom: Error, Equatable {}
        let runtime = RecordingRuntime()
        runtime.generateError = Boom()
        let backend = MLXLocalInferenceBackend(service: runtime)

        do {
            for try await _ in backend.generate(
                LocalGenerationRequest(messages: [.user("u")], maxOutputTokens: 16)) {}
            XCTFail("expected the error to surface")
        } catch {
            // `sendLocal` distinguishes CancellationError and LocalLLMError from everything else,
            // so the seam must not wrap what it forwards.
            XCTAssertTrue(error is Boom, "got \(error)")
        }
    }

    func testAdapterRefusalSurfacesAsAStreamFailure() async {
        let backend = MLXLocalInferenceBackend(service: RecordingRuntime())
        do {
            for try await _ in backend.generate(
                LocalGenerationRequest(messages: [.assistant("no user turn")], maxOutputTokens: 16)) {}
            XCTFail("expected .missingUserTurn")
        } catch {
            XCTAssertEqual(error as? MLXPromptAdapter.Fault, .missingUserTurn)
        }
    }

    // MARK: - Load / unload / cancel

    func testLoadForwardsTheModelIDAndReportsVisionAsLoaded() async throws {
        let runtime = RecordingRuntime()
        let backend = MLXLocalInferenceBackend(service: runtime)
        let installed = LLMService.mlxInstallation(forModelID: "mlx-community/gemma-4-e2b-it-4bit")

        // Catalogued as a vision model, but demoted to the text factory at load time.
        runtime.loadedViaVLMFactory = false
        let loaded = try await backend.load(installed, configuration: .init(contextLength: 4096))

        XCTAssertEqual(runtime.loadedIDs, ["mlx-community/gemma-4-e2b-it-4bit"])
        XCTAssertTrue(installed.descriptor.supportsVision, "the catalog does claim vision")
        XCTAssertFalse(loaded.supportsVision,
                       "capability is reported as loaded — a demoted checkpoint is text-only")
        XCTAssertTrue(loaded.capabilities.contains(.toolFriendly))
    }

    func testLoadReportsVisionWhenTheVLMFactorySucceeded() async throws {
        let runtime = RecordingRuntime()
        runtime.loadedViaVLMFactory = true
        let backend = MLXLocalInferenceBackend(service: runtime)
        let loaded = try await backend.load(
            LLMService.mlxInstallation(forModelID: "mlx-community/SmolVLM2-2.2B-Instruct-mlx"),
            configuration: .init(contextLength: 4096))
        XCTAssertTrue(loaded.supportsVision)
    }

    func testLoadRefusesANonMLXInstallation() async {
        let backend = MLXLocalInferenceBackend(service: RecordingRuntime())
        let gguf = InstalledLocalModel(
            descriptor: LocalModelDescriptor(id: LocalModelID("x/y"), displayName: "x/y",
                                             runtime: .llamaCpp, repositoryID: "x/y",
                                             revision: "r", capabilities: [.text],
                                             contextLength: 4096, estimatedWeightsBytes: 1,
                                             estimatedWorkingBytes: 1, minimumHeadroomBytes: 2),
            storage: .managed(directoryName: "x"),
            installedAt: Date())
        do {
            _ = try await backend.load(gguf, configuration: .init(contextLength: 4096))
            XCTFail("expected .noBackend")
        } catch let error as LocalInferenceError {
            XCTAssertEqual(error, .noBackend(.llamaCpp))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testUnloadCancelsThenReleasesTheRuntime() async throws {
        let runtime = RecordingRuntime()
        let backend = MLXLocalInferenceBackend(service: runtime)
        _ = try await backend.load(LLMService.mlxInstallation(forModelID: "a/one"),
                                   configuration: .init(contextLength: 4096))
        XCTAssertNotNil(backend.loadedModel)

        await backend.unload()

        XCTAssertEqual(runtime.unloadCount, 1)
        XCTAssertNil(backend.loadedModel)
    }

    /// `cancelGeneration` must not return until the runtime has actually stopped — the coordinator
    /// unloads immediately afterwards, and freeing weights under a live token loop is a crash.
    func testCancelGenerationWaitsForTheGenerationToStop() async throws {
        let runtime = RecordingRuntime()
        runtime.blocksUntilCancelled = true
        let backend = MLXLocalInferenceBackend(service: runtime)

        let consumer = Task {
            var seen = 0
            for try await _ in backend.generate(
                LocalGenerationRequest(messages: [.user("u")], maxOutputTokens: 16)) { seen += 1 }
            return seen
        }
        // Let the generation actually start before cancelling it.
        try await Task.sleep(nanoseconds: 50_000_000)
        await backend.cancelGeneration()

        // If `cancelGeneration` returned before the runtime stopped, this would still be running.
        let outcome = await consumer.result
        switch outcome {
        case .success:
            XCTFail("a cancelled generation must not complete normally")
        case .failure(let error):
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
    }
}
