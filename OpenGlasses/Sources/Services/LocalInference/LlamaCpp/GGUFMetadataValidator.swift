import Foundation

/// What a GGUF file says about itself, and the arithmetic that turns it into a context window.
///
/// Every value here comes from the file's own key/value metadata. Plan DZ's non-goal is explicit —
/// "Guessing chat templates, architecture, capability, context, or projector compatibility from
/// names" — so there is no filename parsing anywhere in this file, and none is wanted: a repack of
/// the same weights under a different name must resolve to the same architecture.
///
/// Pure, so the whole clamping truth table and the over-context refusal are exercised headlessly.

/// The architectural facts needed to size a context.
struct GGUFModelMetadata: Equatable, Sendable {
    /// `general.architecture`, e.g. `llama`, `qwen3`, `gemma3`. Also the prefix of every
    /// architecture-scoped key.
    let architecture: String
    /// `<arch>.context_length` — what the model was trained for. `0` when the file omits it.
    let trainingContextTokens: Int
    /// `<arch>.block_count` — transformer layers.
    let blockCount: Int?
    /// `<arch>.embedding_length`.
    let embeddingLength: Int?
    /// `<arch>.attention.head_count`.
    let headCount: Int?
    /// `<arch>.attention.head_count_kv`. Absent means multi-head attention, i.e. equal to
    /// `headCount` — that is the GGUF convention, not an assumption of ours.
    let headCountKV: Int?

    /// Bytes one token of KV cache costs, or `nil` when the file does not describe its own shape
    /// well enough to say.
    ///
    /// `2` for the K and V halves, times layers, times the per-layer KV width, times the element
    /// size. Returning `nil` rather than a guess matters: an invented number would silently clamp
    /// a working model's context, and a wrong clamp is indistinguishable from a broken model.
    func kvCacheBytesPerToken(bytesPerElement: Int = 2) -> Int64? {
        guard let blockCount, blockCount > 0,
              let embeddingLength, embeddingLength > 0,
              let headCount, headCount > 0 else { return nil }
        let kvHeads = headCountKV ?? headCount
        guard kvHeads > 0 else { return nil }
        let headDimension = embeddingLength / headCount
        guard headDimension > 0 else { return nil }
        return Int64(2 * blockCount * headDimension * kvHeads * bytesPerElement)
    }
}

/// Why a file's metadata cannot be trusted to configure a runtime.
enum GGUFMetadataFault: Error, Equatable, Sendable {
    /// No `general.architecture`. Without it there is no architecture-scoped key to read, and the
    /// file is not a GGUF this runtime can configure.
    case missingArchitecture
}

/// Which of the four ceilings actually decided the context length.
enum LlamaContextConstraint: String, Equatable, Sendable {
    /// Nothing clamped the caller — the requested window was already the smallest.
    case requested
    /// The model's own trained context length.
    case modelCapability
    /// The bundled descriptor's policy for this model.
    case descriptorPolicy
    /// What the KV cache can afford in the memory left to this process.
    case memoryBudget
}

/// The context window a load will actually create, and why.
struct LlamaContextPlan: Equatable, Sendable {
    /// Used when no ceiling is known at all — every input was unset. Small enough to be safe on
    /// any device that can hold the weights, large enough for a real turn.
    static let defaultContextTokens = 4096
    /// Below this a context cannot hold a system prompt and one exchange, so a load that clamps
    /// here is refused rather than created and immediately found useless.
    static let minimumViableContextTokens = 512

    let contextTokens: Int
    let binding: LlamaContextConstraint

    var isViable: Bool { contextTokens >= Self.minimumViableContextTokens }
}

/// The preflight that keeps an oversized prompt away from `llama_decode`.
struct LlamaPromptAdmission: Equatable, Sendable {
    let promptTokens: Int
    /// Tokens held back for the answer.
    let reserveTokens: Int
    let contextTokens: Int

    var fits: Bool { promptTokens + reserveTokens <= contextTokens }
    /// How many tokens over the window the request is. `0` when it fits.
    var overflowTokens: Int { max(0, promptTokens + reserveTokens - contextTokens) }
}

enum GGUFMetadataValidator {

    /// GGUF's architecture key. The one key whose name is not architecture-scoped.
    static let architectureKey = "general.architecture"

    /// Read the architectural facts through a key lookup — the engine's metadata accessor in
    /// production, a dictionary in tests.
    static func metadata(lookup: (String) -> String?) -> Result<GGUFModelMetadata, GGUFMetadataFault> {
        guard let architecture = lookup(architectureKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !architecture.isEmpty else {
            return .failure(.missingArchitecture)
        }
        func scoped(_ suffix: String) -> Int? {
            lookup("\(architecture).\(suffix)").flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        return .success(GGUFModelMetadata(
            architecture: architecture,
            trainingContextTokens: scoped("context_length") ?? 0,
            blockCount: scoped("block_count"),
            embeddingLength: scoped("embedding_length"),
            headCount: scoped("attention.head_count"),
            headCountKV: scoped("attention.head_count_kv")))
    }

    /// How many tokens of KV cache `bytes` buys. `0` means "no memory-derived ceiling" — either
    /// the budget is unknown (simulator, Mac) or the file did not describe its own shape.
    static func affordableContextTokens(bytes: Int64, metadata: GGUFModelMetadata) -> Int {
        guard bytes > 0, let perToken = metadata.kvCacheBytesPerToken(), perToken > 0 else { return 0 }
        return Int(bytes / perToken)
    }

    /// Clamp to the smallest of the ceilings that are known (Plan DZ load step 5). A ceiling of
    /// `0` or less is *unknown*, not *zero*, and is skipped — refusing on unknown would brick the
    /// simulator, exactly as `MemoryHeadroom` already argues for its own gate.
    ///
    /// Ties resolve toward `.requested`: if the caller asked for precisely the model's trained
    /// length, nothing clamped them and saying otherwise would be reporting a constraint that did
    /// no work.
    static func contextPlan(requested: Int,
                            modelCapability: Int,
                            descriptorPolicy: Int,
                            memoryBudgetTokens: Int) -> LlamaContextPlan {
        var resolved: Int?
        var binding: LlamaContextConstraint = .requested

        func consider(_ candidate: Int, _ constraint: LlamaContextConstraint) {
            guard candidate > 0 else { return }
            guard let current = resolved else {
                resolved = candidate
                binding = constraint
                return
            }
            if candidate < current {
                resolved = candidate
                binding = constraint
            }
        }

        consider(requested, .requested)
        consider(modelCapability, .modelCapability)
        consider(descriptorPolicy, .descriptorPolicy)
        consider(memoryBudgetTokens, .memoryBudget)

        guard let resolved else {
            return LlamaContextPlan(contextTokens: LlamaContextPlan.defaultContextTokens,
                                    binding: .requested)
        }
        return LlamaContextPlan(contextTokens: resolved, binding: binding)
    }
}
