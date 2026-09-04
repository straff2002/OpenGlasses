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
    /// Keep the KV cache on the GPU. Off trades speed for headroom.
    let offloadKVCache: Bool

    init(contextTokens: Int, batchTokens: Int, offloadKVCache: Bool = true) {
        self.contextTokens = contextTokens
        self.batchTokens = batchTokens
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

    init(seed: UInt32 = LlamaSamplerOptions.randomSeed,
         temperature: Float = 0.7,
         topK: Int32 = LlamaSamplerOptions.defaultTopK,
         topP: Float = 0.9,
         minP: Float = LlamaSamplerOptions.defaultMinP,
         penaltyWindow: Int32 = LlamaSamplerOptions.defaultPenaltyWindow,
         penaltyRepeat: Float = LlamaSamplerOptions.defaultRepeatPenalty) {
        self.seed = seed
        self.temperature = temperature
        self.topK = topK
        self.topP = topP
        self.minP = minP
        self.penaltyWindow = penaltyWindow
        self.penaltyRepeat = penaltyRepeat
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
                  minP: Self.defaultMinP,
                  penaltyWindow: Self.defaultPenaltyWindow,
                  penaltyRepeat: sampling.repetitionPenalty ?? Self.defaultRepeatPenalty)
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
}
