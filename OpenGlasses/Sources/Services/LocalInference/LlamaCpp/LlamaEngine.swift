import Foundation

/// The vendored engine's C ABI, restated in Swift terms (Plan DZ P1/PR3).
///
/// The backend talks to *this*, never to `LlamaCppWrapper` directly. That indirection buys the one
/// thing the simulator cannot give us: the load flow's teardown ordering, the decode partitioning,
/// the over-context refusal and the byte accumulator are all exercised against a fake engine, on a
/// machine where no Metal graph can run. Without the seam those paths would only ever be reachable
/// on a phone, which is where they are least observable.
///
/// Everything here is `Sendable` by construction — handles are opaque bit patterns rather than
/// pointers — because the generation loop deliberately runs off the owning actor (see
/// `LlamaCppLocalInferenceBackend`) so that cancellation can reach it.

typealias LlamaToken = Int32

// MARK: - Handles

/// A live `llama_model`. The bit pattern is the wrapper's handle pointer in the real engine and an
/// arbitrary counter in a fake; nothing outside the engine implementation may interpret it.
struct LlamaModelHandle: Hashable, Sendable {
    let bits: UInt
    init(bits: UInt) { self.bits = bits }
}

struct LlamaContextHandle: Hashable, Sendable {
    let bits: UInt
    init(bits: UInt) { self.bits = bits }
}

struct LlamaSamplerHandle: Hashable, Sendable {
    let bits: UInt
    init(bits: UInt) { self.bits = bits }
}

/// A model's chat templates as llama.cpp's `common/chat` holds them (Plan MQ P2).
struct LlamaChatTemplatesHandle: Hashable, Sendable {
    let bits: UInt
    init(bits: UInt) { self.bits = bits }
}

/// A parser for the completions of one tool-turn render (Plan MQ P2).
struct LlamaChatParserHandle: Hashable, Sendable {
    let bits: UInt
    init(bits: UInt) { self.bits = bits }
}

/// A copy of a context's sequence state, held in host memory (Plan MQ, the Qwen prefix snapshot).
struct LlamaStateSnapshotHandle: Hashable, Sendable {
    let bits: UInt
    init(bits: UInt) { self.bits = bits }
}

/// A saved snapshot and its size.
struct LlamaStateSnapshot: Hashable, Sendable {
    let handle: LlamaStateSnapshotHandle
    let bytes: Int
}

// MARK: - Options

struct LlamaModelOptions: Hashable, Sendable {
    /// Layers placed on the GPU. Negative means all of them.
    var gpuLayers: Int32
    var useMemoryMapping: Bool
    /// Metadata and vocabulary only — no weights.
    var vocabularyOnly: Bool
    /// Validate tensor data while loading. Slower; catches a corrupt file.
    var checkTensors: Bool

    init(gpuLayers: Int32 = -1,
         useMemoryMapping: Bool = true,
         vocabularyOnly: Bool = false,
         checkTensors: Bool = false) {
        self.gpuLayers = gpuLayers
        self.useMemoryMapping = useMemoryMapping
        self.vocabularyOnly = vocabularyOnly
        self.checkTensors = checkTensors
    }
}

struct LlamaContextOptions: Hashable, Sendable {
    let contextTokens: Int
    let batchTokens: Int
    /// The physical batch (`n_ubatch`), capped at `batchTokens`; nil keeps the engine's default.
    let physicalBatchTokens: Int?
    /// Keep the KV cache on the GPU. Off trades speed for headroom.
    let offloadKVCache: Bool

    init(contextTokens: Int, batchTokens: Int, physicalBatchTokens: Int? = nil, offloadKVCache: Bool = true) {
        self.contextTokens = contextTokens
        self.batchTokens = batchTokens
        self.physicalBatchTokens = physicalBatchTokens
        self.offloadKVCache = offloadKVCache
    }
}

/// App-owned sampling parameters. The defaults are conservative and live here rather than in a
/// call site, and per-model overrides arrive through `LocalSamplingConfiguration` from the bundled
/// descriptor — never from a filename.
struct LlamaSamplerOptions: Hashable, Sendable {
    /// The engine's "draw a fresh seed" sentinel. A test injects a real seed instead.
    static let randomSeed: UInt32 = 0xFFFF_FFFF

    static let defaultTopK: Int32 = 40
    static let defaultMinP: Float = 0.05
    static let defaultRepeatPenalty: Float = 1.1
    /// Tokens of history the repetition penalty looks back over.
    static let defaultPenaltyWindow: Int32 = 64

    var seed: UInt32
    var temperature: Float
    var topK: Int32
    var topP: Float
    var minP: Float
    var penaltyWindow: Int32
    var penaltyRepeat: Float
    /// Subtracted once from every token already in the penalty window (llama.cpp's
    /// `penalty_present`); 0 is off, the default when an entry names none.
    var penaltyPresence: Float

    init(seed: UInt32 = LlamaSamplerOptions.randomSeed,
         temperature: Float = 0.7,
         topK: Int32 = LlamaSamplerOptions.defaultTopK,
         topP: Float = 0.9,
         minP: Float = LlamaSamplerOptions.defaultMinP,
         penaltyWindow: Int32 = LlamaSamplerOptions.defaultPenaltyWindow,
         penaltyRepeat: Float = LlamaSamplerOptions.defaultRepeatPenalty,
         penaltyPresence: Float = 0) {
        self.seed = seed
        self.temperature = temperature
        self.topK = topK
        self.topP = topP
        self.minP = minP
        self.penaltyWindow = penaltyWindow
        self.penaltyRepeat = penaltyRepeat
        self.penaltyPresence = penaltyPresence
    }

    /// Translate the seam's request-level configuration, filling every value the caller left open
    /// with the app default rather than with whatever the engine happens to ship.
    init(_ sampling: LocalSamplingConfiguration) {
        // Truncating is correct rather than lossy-by-accident: the engine's seed is 32-bit, and a
        // test that pins a seed cares that the *same* input yields the same stream, not that all
        // 64 bits survive.
        self.init(seed: sampling.seed.map { UInt32(truncatingIfNeeded: $0) } ?? Self.randomSeed,
                  temperature: sampling.temperature,
                  topK: sampling.topK.map { Int32(clamping: $0) } ?? Self.defaultTopK,
                  topP: sampling.topP,
                  minP: sampling.minP ?? Self.defaultMinP,
                  penaltyWindow: Self.defaultPenaltyWindow,
                  penaltyRepeat: sampling.repetitionPenalty ?? Self.defaultRepeatPenalty,
                  penaltyPresence: sampling.presencePenalty ?? 0)
    }
}

/// One turn as the chat template sees it. Roles are the template's own vocabulary (`system`,
/// `user`, `assistant`), which is why this is a string and not `LocalChatMessage.Role`.
struct LlamaChatTurn: Hashable, Sendable {
    let role: String
    let content: String

    init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

// MARK: - Errors

/// The wrapper's `OGLlamaStatus`, as a Swift error. One case per status so a caller can act on
/// "the prompt did not fit" differently from "the file would not open".
enum LlamaEngineError: Error, Equatable {
    case invalidArgument
    case modelLoadFailed
    case contextCreateFailed
    case samplerCreateFailed
    case tokenizeFailed
    /// `llama_decode` could not find a KV slot — the batch does not fit the context.
    case contextExhausted
    case decodeFailed
    case noChatTemplate
    case templateFailed
    case cancelled
    case allocationFailed
    /// A completion that does not match the model family's tool-call format (Plan MQ P2).
    case parseFailed
    /// The family's call grammar or its triggers could not be built (Plan MQ P2).
    case grammarFailed
    case unknown(Int32)

    /// Maps a raw status. `0` is success and must never reach here.
    init(status: Int32) {
        switch status {
        case 1: self = .invalidArgument
        case 2: self = .modelLoadFailed
        case 3: self = .contextCreateFailed
        case 4: self = .samplerCreateFailed
        case 5: self = .tokenizeFailed
        case 6: self = .contextExhausted
        case 7: self = .decodeFailed
        case 8: self = .noChatTemplate
        case 9: self = .templateFailed
        case 10: self = .cancelled
        case 11: self = .allocationFailed
        case 12: self = .parseFailed
        case 13: self = .grammarFailed
        default: self = .unknown(status)
        }
    }
}

// MARK: - Engine

/// Model, context, sampler, tokenizer and template, as the backend needs them.
///
/// Deliberately *not* thread-safe by contract — matching the wrapper's own statement that the
/// owning actor is the synchronization. The single exception is `setCancelled`, which the wrapper
/// implements as an atomic precisely so a cancel can reach an in-flight decode.
protocol LlamaEngine: Sendable {

    // Model lifecycle
    func loadModel(atPath path: String, options: LlamaModelOptions) throws -> LlamaModelHandle
    func freeModel(_ model: LlamaModelHandle)

    // Metadata — the only source of architecture and chat format
    func metadataValue(_ model: LlamaModelHandle, key: String) -> String?
    func chatTemplate(_ model: LlamaModelHandle, named name: String?) -> String?
    func trainingContextTokens(_ model: LlamaModelHandle) -> Int
    func vocabularyAddsBOS(_ model: LlamaModelHandle) -> Bool
    /// The rendered text of the BOS token, used to tell whether a template already emits one.
    func beginningOfSequencePiece(_ model: LlamaModelHandle) -> String?
    func isEndOfGeneration(_ model: LlamaModelHandle, token: LlamaToken) -> Bool

    // Template and tokenization
    func applyChatTemplate(_ template: String,
                           turns: [LlamaChatTurn],
                           addAssistantHeader: Bool) throws -> String
    func tokenize(_ model: LlamaModelHandle,
                  text: String,
                  addSpecial: Bool,
                  parseSpecial: Bool) throws -> [LlamaToken]
    /// Raw bytes of one token. Bytes, not characters: a token can end mid-UTF-8.
    func tokenBytes(_ model: LlamaModelHandle, token: LlamaToken) -> [UInt8]

    // Context lifecycle
    func createContext(_ model: LlamaModelHandle, options: LlamaContextOptions) throws -> LlamaContextHandle
    func freeContext(_ context: LlamaContextHandle)
    func contextTokens(_ context: LlamaContextHandle) -> Int
    func batchTokens(_ context: LlamaContextHandle) -> Int
    func clearMemory(_ context: LlamaContextHandle)
    func setCancelled(_ context: LlamaContextHandle, _ cancelled: Bool)
    func synchronize(_ context: LlamaContextHandle)
    func decode(_ context: LlamaContextHandle,
                tokens: [LlamaToken],
                position: Int,
                wantsLogitsForLast: Bool) throws

    // Sampling
    func createSampler(_ model: LlamaModelHandle, options: LlamaSamplerOptions) throws -> LlamaSamplerHandle
    func freeSampler(_ sampler: LlamaSamplerHandle)
    func resetSampler(_ sampler: LlamaSamplerHandle)
    func sample(_ sampler: LlamaSamplerHandle, context: LlamaContextHandle) throws -> LlamaToken

    // Prefix reuse (Plan MQ H3)

    /// Keep the first `tokens` positions of the KV cache and drop the rest; returns the positions
    /// kept — `tokens`, or 0 when the cache cannot be cut back there and was cleared instead.
    func keepPrefix(_ context: LlamaContextHandle, tokens: Int) -> Int

    // Prefix snapshots (Plan MQ) — for a model whose cache cannot be cut back

    /// False for a recurrent or hybrid model (Qwen 3.5): `keepPrefix` can never keep anything, so a
    /// shared start is carried by a state snapshot instead.
    func memoryCanTrim(_ model: LlamaModelHandle) -> Bool
    /// Copies the context's sequence state; throws `allocationFailed` past `maximumBytes`.
    func saveState(_ context: LlamaContextHandle, maximumBytes: Int) throws -> LlamaStateSnapshot
    /// Puts a snapshot's state back. False when it could not: the sequence is then empty.
    func restoreState(_ context: LlamaContextHandle, _ snapshot: LlamaStateSnapshotHandle) -> Bool
    func freeState(_ snapshot: LlamaStateSnapshotHandle)

    // Chat templates and tool calls (Plan MQ P2) — llama.cpp's `common/chat`, as JSON text

    /// One token's bytes with control tokens rendered when `renderSpecial`: a tool turn needs the
    /// family's call markers (`<|tool_call>`, `<tool_call>`) in the text its parser reads.
    func tokenBytes(_ model: LlamaModelHandle, token: LlamaToken, renderSpecial: Bool) -> [UInt8]
    /// The model's own templates, or `noChatTemplate` when it embeds none.
    func chatTemplates(_ model: LlamaModelHandle) throws -> LlamaChatTemplatesHandle
    /// Templates from Jinja source with no model, for the pure tests.
    func chatTemplates(source: String, bosToken: String, eosToken: String) throws -> LlamaChatTemplatesHandle
    func freeChatTemplates(_ templates: LlamaChatTemplatesHandle)
    /// `LlamaChatRequest` JSON in, `LlamaChatRender` JSON out.
    func renderChat(_ templates: LlamaChatTemplatesHandle, requestJSON: String) throws -> String
    /// A parser for the completions of `requestJSON`'s render. The request, not the render: since
    /// llama.cpp v1.0.0 the family's parser exists only in memory, so it is built from a render.
    func createChatParser(_ templates: LlamaChatTemplatesHandle, requestJSON: String) throws -> LlamaChatParserHandle
    func freeChatParser(_ parser: LlamaChatParserHandle)
    /// A completion as `LlamaChatParsed` JSON; throws `parseFailed` when it is not the family's format.
    func parseChat(_ parser: LlamaChatParserHandle, text: String, partial: Bool) throws -> String
    /// The render's lazy call grammar on the sampler (cleared when the render has none).
    func setChatGrammar(_ sampler: LlamaSamplerHandle, model: LlamaModelHandle, renderJSON: String) throws
    func clearGrammar(_ sampler: LlamaSamplerHandle)
}

/// What an engine without the chat code or prefix reuse does: the plain path Plan DZ shipped. The
/// test doubles that predate Plan MQ P2 rely on these; the real engine implements every one.
extension LlamaEngine {
    func keepPrefix(_ context: LlamaContextHandle, tokens: Int) -> Int {
        clearMemory(context)
        return 0
    }

    func tokenBytes(_ model: LlamaModelHandle, token: LlamaToken, renderSpecial: Bool) -> [UInt8] {
        tokenBytes(model, token: token)
    }

    /// An engine that does not say otherwise is cut back as before (the trim path).
    func memoryCanTrim(_ model: LlamaModelHandle) -> Bool { true }

    func saveState(_ context: LlamaContextHandle, maximumBytes: Int) throws -> LlamaStateSnapshot {
        throw LlamaEngineError.invalidArgument
    }

    func restoreState(_ context: LlamaContextHandle, _ snapshot: LlamaStateSnapshotHandle) -> Bool {
        clearMemory(context)
        return false
    }

    func freeState(_ snapshot: LlamaStateSnapshotHandle) {}

    func chatTemplates(_ model: LlamaModelHandle) throws -> LlamaChatTemplatesHandle {
        throw LlamaEngineError.noChatTemplate
    }

    func chatTemplates(source: String, bosToken: String, eosToken: String) throws -> LlamaChatTemplatesHandle {
        throw LlamaEngineError.noChatTemplate
    }

    func freeChatTemplates(_ templates: LlamaChatTemplatesHandle) {}

    func renderChat(_ templates: LlamaChatTemplatesHandle, requestJSON: String) throws -> String {
        throw LlamaEngineError.templateFailed
    }

    func createChatParser(_ templates: LlamaChatTemplatesHandle, requestJSON: String) throws -> LlamaChatParserHandle {
        throw LlamaEngineError.templateFailed
    }

    func freeChatParser(_ parser: LlamaChatParserHandle) {}

    func parseChat(_ parser: LlamaChatParserHandle, text: String, partial: Bool) throws -> String {
        throw LlamaEngineError.parseFailed
    }

    func setChatGrammar(_ sampler: LlamaSamplerHandle, model: LlamaModelHandle, renderJSON: String) throws {}

    func clearGrammar(_ sampler: LlamaSamplerHandle) {}
}
