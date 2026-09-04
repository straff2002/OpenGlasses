import XCTest
@testable import OpenGlasses

/// Plan DZ P1/PR3 — the pure decisions the GGUF runtime makes before, during and after a
/// generation: what the file says about itself, how wide a context that buys, whether the template
/// can carry a conversation, and how token bytes become text.
///
/// None of this needs an engine, which is the point: the simulator cannot run a Metal graph, so
/// every rule that *can* be decided without one is decided in a value type and pinned here.
final class LlamaCppRuntimeTests: XCTestCase {

    // MARK: - Metadata, read from the file rather than its name

    private func metadataLookup(_ pairs: [String: String]) -> (String) -> String? {
        { pairs[$0] }
    }

    func testArchitectureAndShapeComeFromMetadataKeys() throws {
        let result = GGUFMetadataValidator.metadata(lookup: metadataLookup([
            "general.architecture": "qwen3",
            "qwen3.context_length": "32768",
            "qwen3.block_count": "28",
            "qwen3.embedding_length": "1024",
            "qwen3.attention.head_count": "16",
            "qwen3.attention.head_count_kv": "8",
        ]))
        let metadata = try XCTUnwrap(try? result.get())
        XCTAssertEqual(metadata.architecture, "qwen3")
        XCTAssertEqual(metadata.trainingContextTokens, 32768)
        XCTAssertEqual(metadata.blockCount, 28)
        XCTAssertEqual(metadata.headCountKV, 8)
    }

    /// The scoped keys are prefixed by whatever `general.architecture` says, so a file that renames
    /// its architecture is read with the new prefix and never with a guessed one.
    func testScopedKeysFollowTheDeclaredArchitecture() throws {
        let result = GGUFMetadataValidator.metadata(lookup: metadataLookup([
            "general.architecture": "llama",
            // Deliberately present under a *different* architecture's prefix. A reader that
            // pattern-matched on a filename would pick these up; this one must not.
            "qwen3.context_length": "32768",
            "llama.context_length": "8192",
        ]))
        let metadata = try XCTUnwrap(try? result.get())
        XCTAssertEqual(metadata.trainingContextTokens, 8192)
    }

    func testMissingArchitectureIsAFault() {
        let result = GGUFMetadataValidator.metadata(lookup: metadataLookup(["llama.block_count": "32"]))
        guard case .failure(let fault) = result else { return XCTFail("expected a fault") }
        XCTAssertEqual(fault, .missingArchitecture)
    }

    func testKVCacheSizeIsNilWhenTheFileDoesNotDescribeItsShape() {
        let partial = GGUFModelMetadata(architecture: "llama",
                                        trainingContextTokens: 4096,
                                        blockCount: 32,
                                        embeddingLength: nil,
                                        headCount: 32,
                                        headCountKV: nil)
        XCTAssertNil(partial.kvCacheBytesPerToken(),
                     "an invented KV size would silently clamp a working model's context")
    }

    func testKVCacheSizeUsesGroupedQueryHeadsWhenDeclared() throws {
        let grouped = GGUFModelMetadata(architecture: "qwen3",
                                        trainingContextTokens: 32768,
                                        blockCount: 28,
                                        embeddingLength: 1024,
                                        headCount: 16,
                                        headCountKV: 8)
        // 2 halves x 28 layers x (1024/16) head dim x 8 KV heads x 2 bytes.
        XCTAssertEqual(try XCTUnwrap(grouped.kvCacheBytesPerToken()), 2 * 28 * 64 * 8 * 2)

        // Absent head_count_kv means multi-head attention, i.e. one KV head per query head.
        let multiHead = GGUFModelMetadata(architecture: "qwen3",
                                          trainingContextTokens: 32768,
                                          blockCount: 28,
                                          embeddingLength: 1024,
                                          headCount: 16,
                                          headCountKV: nil)
        XCTAssertEqual(try XCTUnwrap(multiHead.kvCacheBytesPerToken()), 2 * 28 * 64 * 16 * 2)
    }

    func testAffordableContextIsZeroWhenThereIsNoBudget() {
        let metadata = GGUFModelMetadata(architecture: "llama", trainingContextTokens: 4096,
                                         blockCount: 32, embeddingLength: 4096,
                                         headCount: 32, headCountKV: 8)
        XCTAssertEqual(GGUFMetadataValidator.affordableContextTokens(bytes: 0, metadata: metadata), 0,
                       "no budget means unknown, not zero tokens")
    }

    // MARK: - Context clamping truth table

    func testContextClampsToTheSmallestKnownCeiling() {
        let cases: [(requested: Int, model: Int, policy: Int, memory: Int,
                     expected: Int, binding: LlamaContextConstraint)] = [
            // Nothing clamps: the request is already the tightest.
            (2048, 8192, 4096, 16384, 2048, .requested),
            // The model's trained length wins.
            (32768, 8192, 16384, 65536, 8192, .modelCapability),
            // The descriptor's policy is tighter than the model.
            (32768, 32768, 4096, 65536, 4096, .descriptorPolicy),
            // Memory is the binding constraint.
            (8192, 32768, 16384, 2048, 2048, .memoryBudget),
            // Unknown ceilings (0) are skipped rather than treated as zero.
            (4096, 0, 0, 0, 4096, .requested),
            // A tie reports `requested`: nothing actually clamped the caller.
            (8192, 8192, 8192, 8192, 8192, .requested),
        ]
        for testCase in cases {
            let plan = GGUFMetadataValidator.contextPlan(requested: testCase.requested,
                                                         modelCapability: testCase.model,
                                                         descriptorPolicy: testCase.policy,
                                                         memoryBudgetTokens: testCase.memory)
            XCTAssertEqual(plan.contextTokens, testCase.expected, "\(testCase)")
            XCTAssertEqual(plan.binding, testCase.binding, "\(testCase)")
        }
    }

    func testContextFallsBackWhenNoCeilingIsKnownAtAll() {
        let plan = GGUFMetadataValidator.contextPlan(requested: 0, modelCapability: 0,
                                                     descriptorPolicy: 0, memoryBudgetTokens: 0)
        XCTAssertEqual(plan.contextTokens, LlamaContextPlan.defaultContextTokens)
        XCTAssertTrue(plan.isViable)
    }

    func testAContextClampedBelowOneExchangeIsNotViable() {
        let plan = GGUFMetadataValidator.contextPlan(requested: 8192, modelCapability: 8192,
                                                     descriptorPolicy: 0, memoryBudgetTokens: 64)
        XCTAssertEqual(plan.contextTokens, 64)
        XCTAssertFalse(plan.isViable,
                       "a 64-token window is not a small context, it is an unusable one")
    }

    // MARK: - Over-context arithmetic

    func testPromptAdmissionCountsTheReserveAgainstTheWindow() {
        let fits = LlamaPromptAdmission(promptTokens: 1000, reserveTokens: 512, contextTokens: 2048)
        XCTAssertTrue(fits.fits)
        XCTAssertEqual(fits.overflowTokens, 0)

        // Exactly full is still admissible; one more token is not.
        let exact = LlamaPromptAdmission(promptTokens: 1536, reserveTokens: 512, contextTokens: 2048)
        XCTAssertTrue(exact.fits)

        let over = LlamaPromptAdmission(promptTokens: 1537, reserveTokens: 512, contextTokens: 2048)
        XCTAssertFalse(over.fits)
        XCTAssertEqual(over.overflowTokens, 1)
    }

    // MARK: - Chat template

    /// A template stand-in with the shape real templates have: turn markers around role and
    /// content, and an assistant header when generation is being prompted.
    private func chatMLRenderer(dropSystem: Bool = false,
                                emitAssistantHeader: Bool = true)
        -> (String, [LlamaChatTurn], Bool) throws -> String {
        { _, turns, addAssistant in
            var out = ""
            for turn in turns {
                if dropSystem, turn.role == "system" { continue }
                out += "<|im_start|>\(turn.role)\n\(turn.content)<|im_end|>\n"
            }
            if addAssistant, emitAssistantHeader { out += "<|im_start|>assistant\n" }
            return out
        }
    }

    func testAUsableTemplateIsAcceptedAndReportsItsSystemSupport() throws {
        let result = LlamaCppChatTemplate.validate("{{ messages }}", apply: chatMLRenderer())
        let profile = try XCTUnwrap(try? result.get())
        XCTAssertTrue(profile.rendersSystemRole)
        XCTAssertFalse(profile.mergesSystemIntoFirstUser)
    }

    /// The Gemma shape: the system turn is not rendered at all. That is usable — but only if the
    /// caller knows to merge, which is why it is detected by probe rather than by architecture.
    func testATemplateThatDropsTheSystemRoleIsUsableButFlagged() throws {
        let result = LlamaCppChatTemplate.validate("{{ messages }}",
                                                   apply: chatMLRenderer(dropSystem: true))
        let profile = try XCTUnwrap(try? result.get())
        XCTAssertFalse(profile.rendersSystemRole)
        XCTAssertTrue(profile.mergesSystemIntoFirstUser)
    }

    func testTemplateFaultsAreTyped() {
        func fault(_ result: Result<LlamaChatTemplateProfile, LlamaChatTemplateFault>)
            -> LlamaChatTemplateFault? {
            guard case .failure(let fault) = result else { return nil }
            return fault
        }

        XCTAssertEqual(fault(LlamaCppChatTemplate.validate(nil, apply: chatMLRenderer())), .absent)
        XCTAssertEqual(fault(LlamaCppChatTemplate.validate("   ", apply: chatMLRenderer())), .absent)
        XCTAssertEqual(fault(LlamaCppChatTemplate.validate("{{ x }}") { _, _, _ in
            throw LlamaEngineError.templateFailed
        }), .renderFailed)
        XCTAssertEqual(fault(LlamaCppChatTemplate.validate("{{ x }}") { _, _, _ in "" }), .emptyRender)
        // Renders something, but the wearer's words never reach the model.
        XCTAssertEqual(fault(LlamaCppChatTemplate.validate("{{ x }}") { _, _, _ in
            "<|im_start|>assistant\n"
        }), .dropsUserContent)
        XCTAssertEqual(
            fault(LlamaCppChatTemplate.validate("{{ x }}",
                                                apply: chatMLRenderer(emitAssistantHeader: false))),
            .noAssistantHeader)
    }

    // MARK: - Prompt assembly

    private let conversation: [LocalChatMessage] = [
        .system("Be brief."),
        .user("First question."),
        .assistant("First answer."),
        .user("Second question."),
    ]

    func testAssemblyKeepsExactlyOneCopyOfEachPriorMessage() {
        let turns = LlamaCppChatTemplate.turns(from: conversation, mergingSystemIntoFirstUser: false)
        XCTAssertEqual(turns, [
            LlamaChatTurn(role: "system", content: "Be brief."),
            LlamaChatTurn(role: "user", content: "First question."),
            LlamaChatTurn(role: "assistant", content: "First answer."),
            LlamaChatTurn(role: "user", content: "Second question."),
        ])
        // The property the exit criterion names, stated as a count rather than as an eyeball:
        // every message appears once and only once.
        for message in conversation {
            XCTAssertEqual(turns.filter { $0.content.contains(message.content) }.count, 1,
                           "\(message.content) must appear exactly once in the assembled prompt")
        }
    }

    func testMergingFoldsSystemTextIntoTheFirstUserTurnWithoutRoleLabels() {
        let turns = LlamaCppChatTemplate.turns(from: conversation, mergingSystemIntoFirstUser: true)
        XCTAssertEqual(turns.count, 3, "the system turn is merged, not appended")
        XCTAssertEqual(turns[0].role, "user")
        XCTAssertEqual(turns[0].content, "Be brief.\n\nFirst question.")
        // A `User:` label inside a turn is how a model starts answering as the wrong speaker.
        XCTAssertFalse(turns.contains { $0.content.contains("User:") || $0.content.contains("Assistant:") })
        XCTAssertEqual(turns.filter { $0.content.contains("First question.") }.count, 1)
    }

    func testSystemTurnsAreHoistedRatherThanDroppedOrLeftMidConversation() {
        let messages: [LocalChatMessage] = [
            .system("One."),
            .user("Hi."),
            .system("Two."),
            .assistant("Hello."),
        ]
        let turns = LlamaCppChatTemplate.turns(from: messages, mergingSystemIntoFirstUser: false)
        XCTAssertEqual(turns.first, LlamaChatTurn(role: "system", content: "One.\n\nTwo."))
        XCTAssertEqual(turns.dropFirst().map(\.role), ["user", "assistant"],
                       "the conversation's own order is untouched")
    }

    func testASystemOnlyPromptBecomesAUserTurnWhenTheTemplateCannotCarryIt() {
        let turns = LlamaCppChatTemplate.turns(from: [.system("Only this.")],
                                               mergingSystemIntoFirstUser: true)
        XCTAssertEqual(turns, [LlamaChatTurn(role: "user", content: "Only this.")])
    }

    func testBlankSystemTextIsNotRendered() {
        let turns = LlamaCppChatTemplate.turns(from: [.system("   "), .user("Hi.")],
                                               mergingSystemIntoFirstUser: false)
        XCTAssertEqual(turns, [LlamaChatTurn(role: "user", content: "Hi.")])
    }

    // MARK: - Special-token handling

    func testSpecialTokensAreNotAddedTwiceWhenTheTemplateAlreadyEmittedBOS() {
        XCTAssertFalse(LlamaCppChatTemplate.shouldAddSpecialTokens(
            rendered: "<bos>user\nHi", bosPiece: "<bos>", vocabularyAddsBOS: true))
        XCTAssertTrue(LlamaCppChatTemplate.shouldAddSpecialTokens(
            rendered: "user\nHi", bosPiece: "<bos>", vocabularyAddsBOS: true))
        // A vocabulary that adds no BOS never gets one added on its behalf.
        XCTAssertFalse(LlamaCppChatTemplate.shouldAddSpecialTokens(
            rendered: "user\nHi", bosPiece: "<bos>", vocabularyAddsBOS: false))
        // No BOS piece to compare against: fall back to the vocabulary's own answer.
        XCTAssertTrue(LlamaCppChatTemplate.shouldAddSpecialTokens(
            rendered: "user\nHi", bosPiece: nil, vocabularyAddsBOS: true))
    }

    // MARK: - UTF-8 byte accumulator

    /// Every byte of a multi-byte scalar arriving as its own token — which is exactly what a
    /// byte-level BPE vocabulary does with an emoji.
    func testSplitMultiByteSequencesAreEmittedOnceAndWhole() {
        let text = "café 🙂 naïve"
        var accumulator = LlamaUTF8Accumulator()
        var out = ""
        for byte in Array(text.utf8) {
            out += accumulator.append([byte])
        }
        out += accumulator.flush()
        XCTAssertEqual(out, text)
        XCTAssertFalse(out.contains("\u{FFFD}"), "a split scalar must never surface as a replacement")
    }

    func testBytesAreHeldOnlyUntilTheirSequenceCompletes() {
        var accumulator = LlamaUTF8Accumulator()
        // First two bytes of a three-byte scalar: nothing is emittable yet.
        XCTAssertEqual(accumulator.append([0xE2, 0x82]), "")
        XCTAssertTrue(accumulator.hasPendingBytes)
        XCTAssertEqual(accumulator.append([0xAC]), "€")
        XCTAssertFalse(accumulator.hasPendingBytes)
    }

    func testAsciiTailIsNeverHeldBack() {
        var accumulator = LlamaUTF8Accumulator()
        XCTAssertEqual(accumulator.append(Array("hello".utf8)), "hello")
        XCTAssertFalse(accumulator.hasPendingBytes)
    }

    /// A byte that can never begin a valid sequence must be released rather than accumulated
    /// forever — the stream stalling is a worse failure than one replacement character.
    func testInvalidBytesAreReleasedRatherThanStallingTheStream() {
        var accumulator = LlamaUTF8Accumulator()
        let emitted = accumulator.append([0xFF, 0xFE])
        XCTAssertFalse(emitted.isEmpty)
        XCTAssertFalse(accumulator.hasPendingBytes)
    }

    func testFlushSurfacesATruncatedTrailingSequence() {
        var accumulator = LlamaUTF8Accumulator()
        XCTAssertEqual(accumulator.append([0xF0, 0x9F]), "")
        // One replacement, not two: UTF-8 recovery replaces the whole maximal subpart of an
        // ill-formed sequence, and `0xF0 0x9F` is one such truncated four-byte prefix. What matters
        // is that the tail is reported at all rather than silently dropped.
        XCTAssertEqual(accumulator.flush(), "\u{FFFD}",
                       "a truncated tail is reported, never silently dropped")
    }

    func testChunkedAppendMatchesWholeAppend() {
        let text = "汉字 with 🇳🇿 flags and é"
        var whole = LlamaUTF8Accumulator()
        let expected = whole.append(Array(text.utf8)) + whole.flush()

        var chunked = LlamaUTF8Accumulator()
        var out = ""
        let bytes = Array(text.utf8)
        for start in stride(from: 0, to: bytes.count, by: 3) {
            out += chunked.append(bytes[start..<min(start + 3, bytes.count)])
        }
        out += chunked.flush()
        XCTAssertEqual(out, expected)
        XCTAssertEqual(out, text)
    }

    // MARK: - Stop sequences

    func testAStopSequenceSplitAcrossTokensStillMatchesAndIsNotEmitted() {
        var matcher = LlamaStopSequenceMatcher(stopSequences: ["</tool>"])
        var emitted = ""
        var stopped = false
        for piece in ["Here it is", "<", "/to", "ol", ">", " and more"] {
            let (safe, stop) = matcher.consume(piece)
            emitted += safe
            if stop { stopped = true; break }
        }
        XCTAssertTrue(stopped)
        XCTAssertEqual(emitted, "Here it is")
        XCTAssertFalse(emitted.contains("<"), "no part of the stop sequence may reach the wearer")
    }

    func testTextIsHeldBackOnlyAsFarAsAStopSequenceCouldReach() {
        var matcher = LlamaStopSequenceMatcher(stopSequences: ["END"])
        // Two characters could still turn out to be the start of "END", so they wait.
        XCTAssertEqual(matcher.consume("hello").emit, "hel")
        XCTAssertEqual(matcher.flush(), "lo")
    }

    func testWithNoStopSequencesEverythingIsEmittedImmediately() {
        var matcher = LlamaStopSequenceMatcher(stopSequences: [])
        XCTAssertEqual(matcher.consume("streaming").emit, "streaming")
        XCTAssertFalse(matcher.hasStopped)
    }

    func testTheEarliestStopSequenceWins() {
        var matcher = LlamaStopSequenceMatcher(stopSequences: ["ZZZ", "B"])
        let (emit, stop) = matcher.consume("aaBccZZZ")
        XCTAssertTrue(stop)
        XCTAssertEqual(emit, "aa")
    }

    func testEmptyStopSequencesAreIgnoredRatherThanMatchingEverywhere() {
        var matcher = LlamaStopSequenceMatcher(stopSequences: [""])
        let (emit, stop) = matcher.consume("text")
        XCTAssertFalse(stop)
        XCTAssertEqual(emit, "text")
    }

    // MARK: - Sampling defaults and seed injection

    func testConservativeDefaultsAreAppOwned() {
        let options = LlamaSamplerOptions(.conservative)
        XCTAssertEqual(options.temperature, 0.7)
        XCTAssertEqual(options.topP, 0.9)
        XCTAssertEqual(options.topK, LlamaSamplerOptions.defaultTopK)
        XCTAssertEqual(options.penaltyRepeat, LlamaSamplerOptions.defaultRepeatPenalty)
        XCTAssertEqual(options.penaltyWindow, LlamaSamplerOptions.defaultPenaltyWindow)
        XCTAssertEqual(options.seed, LlamaSamplerOptions.randomSeed,
                       "production draws a fresh seed; only a test pins one")
    }

    func testASuppliedSeedReachesTheSampler() {
        let pinned = LlamaSamplerOptions(LocalSamplingConfiguration(seed: 4242))
        XCTAssertEqual(pinned.seed, 4242)
        XCTAssertNotEqual(pinned.seed, LlamaSamplerOptions.randomSeed)
    }

    func testPerModelOverridesReplaceTheDefaultsTheyName() {
        let overridden = LlamaSamplerOptions(LocalSamplingConfiguration(
            temperature: 0.2, topP: 0.5, topK: 10, repetitionPenalty: 1.3, seed: 7))
        XCTAssertEqual(overridden.temperature, 0.2)
        XCTAssertEqual(overridden.topK, 10)
        XCTAssertEqual(overridden.penaltyRepeat, 1.3)
        // Untouched values keep the app default rather than whatever the engine ships.
        XCTAssertEqual(overridden.minP, LlamaSamplerOptions.defaultMinP)
    }

    // MARK: - ABI constants restated in Swift

    /// `OG_LLAMA_NOT_FOUND` is `#define OG_LLAMA_NOT_FOUND INT32_MIN`, and a macro defined through
    /// another macro's arithmetic does not survive the Clang importer — so `LlamaCppEngine` writes
    /// the value out. This is what stops the two from drifting apart silently: a header that
    /// changed the sentinel would keep compiling while every "key absent" answer became a size.
    func testTheNotFoundSentinelStillMatchesTheVendoredHeader() throws {
        let header = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Vendor/LlamaCpp/Sources/LlamaCppWrapper/include/LlamaCppWrapper.h")
        let text = try String(contentsOf: header, encoding: .utf8)
        XCTAssertTrue(text.contains("#define OG_LLAMA_NOT_FOUND INT32_MIN"),
                      "the header's sentinel changed; LlamaCppEngine.notFound must change with it")
        XCTAssertEqual(LlamaCppEngine.notFound, Int32.min)
    }

    // MARK: - Engine status mapping

    func testEveryEngineStatusMapsToItsOwnCase() {
        let expected: [Int32: LlamaEngineError] = [
            1: .invalidArgument, 2: .modelLoadFailed, 3: .contextCreateFailed,
            4: .samplerCreateFailed, 5: .tokenizeFailed, 6: .contextExhausted,
            7: .decodeFailed, 8: .noChatTemplate, 9: .templateFailed,
            10: .cancelled, 11: .allocationFailed,
        ]
        for (status, error) in expected {
            XCTAssertEqual(LlamaEngineError(status: status), error)
        }
        XCTAssertEqual(LlamaEngineError(status: 99), .unknown(99))
    }
}
