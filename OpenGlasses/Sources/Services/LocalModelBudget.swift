import Foundation

/// Pure prompt-budget logic for on-device (MLX) generation (BK P2).
///
/// Replaces the old single model-agnostic `maxPromptTokens = 4096` constant. Three problems it
/// fixes:
///  1. **Model-agnostic cap.** A flat 4096 ignored that different models have different real
///     context windows. The budget is now derived per loaded model from a table (with a
///     conservative default for user-typed / unknown ids).
///  2. **No generation headroom.** The old cap let a prompt fill the *entire* window, so
///     prompt + up to 512 generated tokens overflowed *during* generation — relocating the
///     uncatchable per-token OOM from submit-time to mid-stream. The budget subtracts the
///     generation reserve (and a small safety margin).
///  3. **Hard reject with no recovery.** The caller now uses `historyFittingBudget` to trim
///     oldest history first and only throws when even the minimal prompt (system + current turn)
///     overflows.
///
/// No MLX import — deliberately headless-testable.
enum LocalModelBudget {
    /// Tokens reserved for the model's own output. `LocalLLMService.generate` derives its
    /// `GenerateParameters(maxTokens:)` from `generationReserve(for:)`, so budget and cap
    /// can't drift apart.
    static let generationReserve = 512

    /// Models that always emit chain-of-thought before the answer (LFM2.5's chat template
    /// pre-opens a `<think>` block on every turn). The think tokens spend from the same
    /// generation budget as the spoken answer, so these models get a larger reserve —
    /// 512 could exhaust mid-think and produce an all-reasoning (empty-spoken) turn.
    static let reasoningModelIds: Set<String> = [
        "LiquidAI/LFM2.5-2.6B-MLX-4bit",
    ]

    /// Generation reserve for reasoning models: think block + answer.
    static let reasoningGenerationReserve = 1024

    /// Per-model generation reserve (tokens the model may emit this turn).
    static func generationReserve(for modelId: String?) -> Int {
        guard let modelId, reasoningModelIds.contains(modelId) else { return generationReserve }
        return reasoningGenerationReserve
    }

    /// Small extra cushion for chat-template scaffolding and count drift between our estimate and
    /// the model's actual tokenization.
    static let safetyMargin = 128

    /// Conservative context window (tokens) for an id we don't recognise. Matches the old flat
    /// cap so unknown / user-typed model ids are no worse off than before — but the budget below
    /// still subtracts the generation reserve, closing the mid-stream-overflow hole.
    static let defaultContextWindow = 4096

    /// Effective (memory-safe) context window per known model id. These are intentionally *below*
    /// each model's theoretical maximum: the on-device ceiling is device memory, not the model's
    /// advertised window. An ~8k-token prompt to a 2B model already Jetsam-killed the app on an
    /// iPhone, so larger models stay at the conservative floor and only the tiny models — which
    /// are cheap to prefill — get more room.
    static let contextWindows: [String: Int] = [
        "mlx-community/Qwen2.5-0.5B-Instruct-4bit": 8192,
        "mlx-community/SmolVLM2-500M-Video-Instruct-mlx": 8192,
        "mlx-community/Qwen2.5-3B-Instruct-4bit": 4096,
        "mlx-community/gemma-2-2b-it-4bit": 4096,
        "mlx-community/gemma-4-e2b-it-4bit": 4096,
        "mlx-community/SmolVLM2-2.2B-Instruct-mlx": 4096,
        "LiquidAI/LFM2.5-2.6B-MLX-4bit": 4096,   // 128K advertised; memory is the real ceiling
    ]

    /// Real context window for a model id, or the conservative default for an unknown id.
    static func contextWindow(for modelId: String?) -> Int {
        guard let modelId, let window = contextWindows[modelId] else { return defaultContextWindow }
        return window
    }

    /// Maximum tokenized-prompt length for a model: its window minus its generation reserve and a
    /// safety margin. Never returns less than a small floor so a mis-entered window can't produce a
    /// zero/negative budget that rejects every prompt.
    static func promptBudget(for modelId: String?) -> Int {
        max(minimumBudget,
            contextWindow(for: modelId) - generationReserve(for: modelId) - safetyMargin)
    }

    /// Budget from an explicit window (unit-test entry point).
    static func promptBudget(contextWindow: Int) -> Int {
        max(minimumBudget, contextWindow - generationReserve - safetyMargin)
    }

    /// Floor so a tiny/misconfigured window still admits the minimal system + turn prompt.
    static let minimumBudget = 512

    // MARK: - Multimodal (image) turns

    /// What survives a multimodal turn on this device.
    ///
    /// A text prefill is chunked, so a fat prompt costs time rather than a memory spike. A
    /// *multimodal* prefill is one unchunked forward: the whole prompt plus the image's soft
    /// tokens are resident together, and that is what Jetsam-kills a small-RAM phone mid-Metal.
    /// The mitigation is real, but it is a small-device mitigation — a 12 GB phone has the
    /// headroom and should keep its configured prompt, its tools and its history.
    struct MultimodalTurnPlan: Equatable {
        /// Keep prior turns in the prompt. Off on the constrained tier: history tokens compete
        /// with the image's soft tokens in the same unchunked pass.
        let keepsHistory: Bool
        /// Keep the wearer's full configured system prompt (persona, tool block, house style).
        /// Off on the constrained tier, which falls back to `Config.compactVisionTurnPrompt`.
        let keepsFullSystemPrompt: Bool
        /// Tokenized-prompt ceiling for the turn.
        let promptBudget: Int
    }

    /// Marketing RAM (GB) at or above which a phone carries a full multimodal turn. Below it,
    /// the turn is trimmed. 12 GB is the same tier line the model catalog already draws for the
    /// larger Gemma 4 checkpoint, so there is one notion of "roomy device", not two.
    static let multimodalFullPromptRAMGB: Double = 12

    /// Fraction of the text budget a constrained device allows a multimodal prompt. The image's
    /// soft tokens are not in our token count but are in the model's, so the prompt has to leave
    /// room for them.
    static let constrainedMultimodalBudgetFraction = 0.25

    /// Per-device plan for an image turn. Pure — the caller supplies the device's RAM, so this
    /// is exercised headlessly at both tiers.
    static func multimodalTurnPlan(for modelId: String?, marketingRAMGB: Double) -> MultimodalTurnPlan {
        let full = promptBudget(for: modelId)
        guard marketingRAMGB < multimodalFullPromptRAMGB else {
            return MultimodalTurnPlan(keepsHistory: true, keepsFullSystemPrompt: true, promptBudget: full)
        }
        return MultimodalTurnPlan(
            keepsHistory: false,
            keepsFullSystemPrompt: false,
            promptBudget: max(minimumBudget, Int(Double(full) * constrainedMultimodalBudgetFraction)))
    }

    /// Trim conversation history so the tokenized prompt fits `budget`, dropping the **oldest**
    /// turns first (the current user turn and system prompt are never dropped). Pure: the caller
    /// injects `tokenCount`, which tokenizes a candidate history the same way the model will.
    ///
    /// Returns the history to actually feed the model. Throws `promptTooLong` only when even an
    /// empty history (system + current turn alone) exceeds the budget — genuine overflow that P2b's
    /// cascade will later route to a bigger-window model.
    static func historyFittingBudget(
        history: [(role: String, content: String)],
        budget: Int,
        tokenCount: (_ history: [(role: String, content: String)]) throws -> Int
    ) throws -> [(role: String, content: String)] {
        var kept = history
        while true {
            let count = try tokenCount(kept)
            if count <= budget { return kept }
            if kept.isEmpty {
                throw LocalLLMError.promptTooLong(tokens: count, limit: budget)
            }
            kept = Array(kept.dropFirst())   // drop the oldest exchange and re-measure
        }
    }
}
