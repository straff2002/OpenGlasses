import CoreGraphics
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

    /// A model's budget on an explicit window (a native tool turn's, `toolTurnContextWindow`): the
    /// window minus the model's own generation reserve and the margin.
    static func promptBudget(for modelId: String?, contextWindow: Int) -> Int {
        max(minimumBudget, contextWindow - generationReserve(for: modelId) - safetyMargin)
    }

    /// Floor so a tiny/misconfigured window still admits the minimal system + turn prompt.
    static let minimumBudget = 512

    /// The share of the prompt budget tool definitions may take on a downloaded model (Plan MQ P0):
    /// a quarter, so the lean prompt, the job context and the conversation keep the rest. A 4,096
    /// window gives 864 tokens — about five compact definitions.
    static let toolDefinitionShare = 4

    /// Tokens the turn's tool definitions may use together on this model.
    static func toolDefinitionBudget(for modelId: String?) -> Int {
        promptBudget(for: modelId) / toolDefinitionShare
    }

    /// The same on an explicit window (a native tool turn's).
    static func toolDefinitionBudget(for modelId: String?, contextWindow: Int) -> Int {
        promptBudget(for: modelId, contextWindow: contextWindow) / toolDefinitionShare
    }

    /// The share of the prompt budget the open job's context may take on a downloaded model
    /// (Plan MQ P1, `LocalJobContext`): a quarter, beside the tools' quarter, so the lean prompt,
    /// the conversation and the turn keep half. The full `<field_assist_context>` of the Lennox
    /// example vault is more than twice a 4,096 window's whole budget; this is what replaces it.
    static let jobContextShare = 4

    /// Tokens the compact job context may use on this model.
    static func jobContextBudget(for modelId: String?) -> Int {
        promptBudget(for: modelId) / jobContextShare
    }

    // MARK: - Backend-aware load admission (Plan DZ P0 item 6)

    /// Why a load is allowed but constrained.
    enum AdmissionConstraint: Equatable, Sendable {
        /// It fits, but with less than the comfort margin to spare — expect thermal pressure and
        /// a tighter working set.
        case tightHeadroom(spareBytes: Int64)
        /// The requested context window exceeds what this runtime/model policy allows and will be
        /// clamped to `tokens`.
        case contextClamped(to: Int)
    }

    /// Why a load is refused. Typed and actionable — never a bare bool.
    enum AdmissionRefusal: Equatable, Sendable {
        /// Weights plus working set plus reserve exceed what this process may still allocate.
        case insufficientHeadroom(neededBytes: Int64, availableBytes: Int64)
    }

    /// Verdict on loading a model right now.
    enum Admission: Equatable, Sendable {
        case allow
        case allowConstrained(AdmissionConstraint)
        case refuse(AdmissionRefusal)

        var isAllowed: Bool {
            if case .refuse = self { return false }
            return true
        }
    }

    /// Everything the admission rule looks at. Supplied by the caller rather than measured here, so
    /// every tier — including the refusal — is exercised headlessly.
    struct AdmissionInputs: Equatable, Sendable {
        let runtime: LocalModelRuntime
        /// Declared weights on disk. `0` = unknown (not downloaded yet).
        let declaredWeightsBytes: Int64
        /// Context window the caller wants to create.
        let configuredContextTokens: Int
        /// Ceiling the descriptor/policy allows for this model. `0` = no policy ceiling.
        let policyContextTokens: Int
        /// What this process may still allocate. `0` = no per-process budget on this platform.
        let availableProcessBytes: Int64
        /// Extra resident cost of the turn's images, when a multimodal turn is being admitted.
        let imageWorkingSetBytes: Int64
        /// Cushion held back beyond the runtime's own working set.
        let safetyReserveBytes: Int64

        init(runtime: LocalModelRuntime,
             declaredWeightsBytes: Int64,
             configuredContextTokens: Int = 0,
             policyContextTokens: Int = 0,
             availableProcessBytes: Int64,
             imageWorkingSetBytes: Int64 = 0,
             safetyReserveBytes: Int64 = 0) {
            self.runtime = runtime
            self.declaredWeightsBytes = declaredWeightsBytes
            self.configuredContextTokens = configuredContextTokens
            self.policyContextTokens = policyContextTokens
            self.availableProcessBytes = availableProcessBytes
            self.imageWorkingSetBytes = imageWorkingSetBytes
            self.safetyReserveBytes = safetyReserveBytes
        }
    }

    /// Working set a runtime needs beyond the weights themselves.
    ///
    /// Both runtimes use `MemoryHeadroom.workingOverheadBytes` today. It is a function rather than
    /// a constant because the numbers *will* diverge — a GGUF context allocates its KV cache up
    /// front where MLX grows into it — and the divergence must land in one tested place rather
    /// than in whichever call site notices first.
    static func workingSetBytes(for runtime: LocalModelRuntime) -> Int64 {
        switch runtime {
        case .mlx, .llamaCpp: return MemoryHeadroom.workingOverheadBytes
        }
    }

    /// Comfort margin above the bare requirement, below which a load is allowed but flagged.
    static let admissionComfortMarginBytes: Int64 = 512 * 1024 * 1024

    /// Can this model load right now?
    ///
    /// **Deliberately consistent with `MemoryHeadroom.canLoad`, not a replacement for it.** The MLX
    /// load path still calls `canLoad`, and this rule refuses exactly when that one does for the
    /// same inputs (`LocalModelAdmissionTests` pins the agreement). Adding a second, differently
    /// tuned gate to the shipping path is how a plan that promised "no behaviour change" quietly
    /// starts refusing loads that used to work; this is the vocabulary the new runtime needs,
    /// agreeing with the old rule where they overlap.
    ///
    /// Unknown values (≤ 0) skip the gate rather than block, for the reason `MemoryHeadroom`
    /// already documents: refusing on "unknown" bricks the simulator and Mac, which do not need
    /// the guard at all.
    static func admit(_ inputs: AdmissionInputs) -> Admission {
        var constraint: AdmissionConstraint?
        if inputs.policyContextTokens > 0,
           inputs.configuredContextTokens > inputs.policyContextTokens {
            constraint = .contextClamped(to: inputs.policyContextTokens)
        }

        guard inputs.declaredWeightsBytes > 0, inputs.availableProcessBytes > 0 else {
            return constraint.map(Admission.allowConstrained) ?? .allow
        }

        let needed = inputs.declaredWeightsBytes
            + workingSetBytes(for: inputs.runtime)
            + max(0, inputs.imageWorkingSetBytes)
            + max(0, inputs.safetyReserveBytes)
        let spare = inputs.availableProcessBytes - needed
        if spare < 0 {
            return .refuse(.insufficientHeadroom(neededBytes: needed,
                                                 availableBytes: inputs.availableProcessBytes))
        }
        // A context clamp is the more actionable thing to report, so it wins when both apply.
        if let constraint { return .allowConstrained(constraint) }
        if spare < admissionComfortMarginBytes {
            return .allowConstrained(.tightHeadroom(spareBytes: spare))
        }
        return .allow
    }

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
        /// Longest edge (pixels) the photo may reach the processor at. The image is resampled to
        /// fit, aspect preserved — the preprocessing of a full-resolution frame is itself a
        /// multi-hundred-megabyte spike on top of an already-resident multi-gigabyte model.
        let imageLongEdge: Int
        /// There is not enough headroom to attempt an image turn at all. The caller must refuse
        /// out loud rather than start a prefill that ends as a process kill.
        let refusesImage: Bool
    }

    /// Marketing RAM (GB) at or above which a phone carries a full multimodal turn. Below it,
    /// the turn is trimmed. 12 GB is the same tier line the model catalog already draws for the
    /// larger Gemma 4 checkpoint, so there is one notion of "roomy device", not two.
    static let multimodalFullPromptRAMGB: Double = 12

    /// Fraction of the text budget a constrained device allows a multimodal prompt. The image's
    /// soft tokens are not in our token count but are in the model's, so the prompt has to leave
    /// room for them.
    static let constrainedMultimodalBudgetFraction = 0.25

    /// Remaining process allocation below which an image turn is refused rather than attempted.
    ///
    /// Sized from a device kill: a 12 GB iPhone, on the "roomy" tier, with Gemma 4 loaded and the
    /// camera pipeline live, took a photo turn to a 6.2 GB footprint and was terminated for
    /// exceeding the **per-process** limit while frontmost. Marketing RAM never saw it coming,
    /// because marketing RAM is not the constraint — iOS's per-process cap is, and it does not
    /// scale with the box on the shelf.
    static let multimodalRefusalHeadroomBytes: Int64 = 1_024 * 1024 * 1024

    /// Remaining process allocation below which an image turn is trimmed even on a roomy phone.
    static let multimodalFullPromptHeadroomBytes: Int64 = 2_048 * 1024 * 1024

    /// Long edge for a photo on the roomy tier, and on the constrained tier.
    static let fullImageLongEdge = 1_344
    static let constrainedImageLongEdge = 896

    /// Gemma's image prefill materializes logits for every prompt token (262k vocabulary),
    /// alongside activations and attention. Budget for 2 MiB per token and leave 1 GiB for the
    /// image encoder, decoding and the rest of the app. This is an admission estimate, not a
    /// claim about the model's theoretical context window. Check the processor's actual tokens,
    /// including image tokens, before entering the uncatchable Metal allocation path.
    static func gemmaPhotoPrefillBudget(promptBudget: Int, availableBytes: Int64) -> Int {
        guard availableBytes > 0 else { return promptBudget }
        let remaining = max(0, availableBytes - multimodalRefusalHeadroomBytes)
        return min(promptBudget, Int(remaining / (2 * 1024 * 1024)))
    }

    enum PhotoPromptAction: Equatable {
        case generate
        case dropOldestHistory
        case compactSystem
        case refuse
    }

    static func photoPromptAction(tokens: Int, budget: Int, historyCount: Int,
                                  usesCompactSystem: Bool) -> PhotoPromptAction {
        guard tokens > budget else { return .generate }
        if historyCount > 0 { return .dropOldestHistory }
        return usesCompactSystem ? .refuse : .compactSystem
    }

    /// Per-turn plan for an image turn.
    ///
    /// Pure — the caller supplies both the device's RAM and the headroom measured *at turn time*,
    /// so every tier including the refusal is exercised headlessly. Headroom leads: a roomy device
    /// with nothing left to allocate is a constrained device, whatever the spec sheet says.
    ///
    /// `availableBytes <= 0` means "no per-process budget on this platform" (simulator, Mac) and
    /// skips the headroom gate entirely rather than refusing — the same rule `MemoryHeadroom`
    /// follows, for the same reason: refusing on unknown bricks the environments that don't need
    /// the guard.
    static func multimodalTurnPlan(for modelId: String?,
                                   marketingRAMGB: Double,
                                   availableBytes: Int64 = 0) -> MultimodalTurnPlan {
        let full = promptBudget(for: modelId)
        let headroomKnown = availableBytes > 0

        if headroomKnown, availableBytes < multimodalRefusalHeadroomBytes {
            return MultimodalTurnPlan(keepsHistory: false, keepsFullSystemPrompt: false,
                                      promptBudget: minimumBudget,
                                      imageLongEdge: constrainedImageLongEdge,
                                      refusesImage: true)
        }

        let roomyDevice = marketingRAMGB >= multimodalFullPromptRAMGB
        let roomyRightNow = !headroomKnown || availableBytes >= multimodalFullPromptHeadroomBytes
        if roomyDevice && roomyRightNow {
            return MultimodalTurnPlan(keepsHistory: true, keepsFullSystemPrompt: true,
                                      promptBudget: full,
                                      imageLongEdge: fullImageLongEdge,
                                      refusesImage: false)
        }
        return MultimodalTurnPlan(
            keepsHistory: false,
            keepsFullSystemPrompt: false,
            promptBudget: max(minimumBudget, Int(Double(full) * constrainedMultimodalBudgetFraction)),
            imageLongEdge: constrainedImageLongEdge,
            refusesImage: false)
    }

    /// Aspect-preserving size for an image whose long edge must not exceed `maxLongEdge`, or nil
    /// when it already fits and re-sampling would only spend memory to change nothing.
    static func imageSize(width: Int, height: Int, maxLongEdge: Int) -> CGSize? {
        guard width > 0, height > 0, maxLongEdge > 0 else { return nil }
        let longEdge = max(width, height)
        guard longEdge > maxLongEdge else { return nil }
        let scale = Double(maxLongEdge) / Double(longEdge)
        return CGSize(width: max(1, Int((Double(width) * scale).rounded())),
                      height: max(1, Int((Double(height) * scale).rounded())))
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

// MARK: - A larger window for native tool turns (Plan MQ P3)

extension LocalModelBudget {

    /// The window a native tool turn may use instead of the model's ordinary one, by model. Gemma 4
    /// E2B only: the first phone run (2026-11-22, iPhone Air, 12 GB) failed every tool turn on its
    /// 4,096 window while its reading turns peaked at 3.16 GB against a 6.44 GB kill limit, so a
    /// bigger phone has the room; 6,144 adds 2,048 tokens, about a fifth of a Field Assist turn's
    /// definitions and history again. Everything else keeps its ordinary window.
    static let raisedToolTurnWindows: [String: Int] = [
        "mlx-community/gemma-4-e2b-it-4bit": 6_144,
    ]

    /// Nominal RAM a phone needs for the raised window; a 6 GB phone stays on the ordinary one.
    static let raisedToolTurnMinimumRAMGB: Double = 8

    /// The attention layout that sizes a model's KV cache, read from its config.
    struct KVCacheShape: Equatable, Sendable {
        /// Layers that cache every token (full attention), and their K and V width.
        let fullAttentionLayers: Int
        let fullKVHeads: Int
        let fullHeadDim: Int
        /// Layers that cache a sliding window only, and their width and window.
        let slidingLayers: Int
        let slidingKVHeads: Int
        let slidingHeadDim: Int
        let slidingWindow: Int
        /// Bytes per cached element (bf16 / fp16: 2).
        let bytesPerElement: Int

        /// The sliding layers may hold a prefill chunk beyond their window while it is read.
        static let prefillChunk = 512

        /// The cache's bytes with `tokens` in it, from the layout.
        func bytes(tokens: Int) -> Int64 {
            let t = Int64(max(0, tokens))
            let full = Int64(fullAttentionLayers * 2 * fullKVHeads * fullHeadDim * bytesPerElement) * t
            let held = min(t, Int64(slidingWindow + Self.prefillChunk))
            let sliding = Int64(slidingLayers * 2 * slidingKVHeads * slidingHeadDim * bytesPerElement) * held
            return full + sliding
        }

        /// A bound that assumes no sliding window and every cache-holding layer at the
        /// full-attention width: what the memory gate charges, so a config read wrong cannot make
        /// the raise look cheaper than it is.
        func conservativeBytes(tokens: Int) -> Int64 {
            let layers = fullAttentionLayers + slidingLayers
            let width = max(fullKVHeads * fullHeadDim, slidingKVHeads * slidingHeadDim)
            return Int64(layers * 2 * width * bytesPerElement) * Int64(max(0, tokens))
        }
    }

    /// KV layouts for the models whose window can be raised.
    ///
    /// Gemma 4 E2B (`gemma4_text`, read from mlx-swift-lm `4c21c84`'s `Gemma4TextConfiguration`,
    /// whose defaults are E2B's and whose comment names E2B's first KV-shared layer as 15): 35
    /// layers, of which the last 20 reuse an earlier layer's K and V and own no cache
    /// (`num_kv_shared_layers`), so 15 layers cache; `sliding_window_pattern` 5 makes every fifth
    /// layer full attention, so 3 full (one KV head, `global_head_dim` 512) and 12 sliding (one KV
    /// head, `head_dim` 256, window 512); `newCache` builds exactly those 15. That is 6 KB a token
    /// plus 12 MB fixed: 48 MB at 6,144 tokens. The gate charges `conservativeBytes` instead
    /// (all 15 layers at 512 wide, no window): 189 MB.
    static let kvCacheShapes: [String: KVCacheShape] = [
        "mlx-community/gemma-4-e2b-it-4bit": KVCacheShape(
            fullAttentionLayers: 3, fullKVHeads: 1, fullHeadDim: 512,
            slidingLayers: 12, slidingKVHeads: 1, slidingHeadDim: 256, slidingWindow: 512,
            bytesPerElement: 2),
    ]

    /// Why a native tool turn got the window it did.
    enum ToolTurnWindowReason: String, Equatable, Sendable, Codable {
        /// Not a native tool turn, or a model with no raised window: the ordinary window.
        case ordinary
        /// A phone under `raisedToolTurnMinimumRAMGB`.
        case smallPhone
        /// The kill-limit budget would not keep the reserve with the larger cache.
        case memory
        /// The raised window.
        case raised
    }

    struct ToolTurnWindow: Equatable, Sendable {
        let tokens: Int
        let reason: ToolTurnWindowReason
    }

    /// The window a turn is budgeted with. Pure.
    ///
    /// Raised only when every one of these holds: the turn runs native tool calls
    /// (`LocalNativeToolPolicy.usesNativeToolCalls`: the flag on, an allowlisted MLX model; the
    /// caller passes it), the model has a raised window and a known KV layout, the phone has at
    /// least `raisedToolTurnMinimumRAMGB`, and `LocalMemoryBudget.fit` against the kill limit keeps
    /// the plan's reserve after the model, its working set and the conservative cache for the
    /// larger window. `residentWeightsBytes` is 0 when the model is already loaded (its pages are
    /// in the footprint the readings hold). Readings with no per-process limit (simulator, Mac)
    /// are not judged, as `LocalMemoryBudget` never judges them.
    static func toolTurnContextWindow(modelId: String?, nativeToolCalls: Bool, marketingRAMGB: Double,
                                      readings: LocalMemoryBudget.Readings,
                                      residentWeightsBytes: Int64 = 0) -> ToolTurnWindow {
        let ordinary = contextWindow(for: modelId)
        guard nativeToolCalls, let modelId, LocalNativeToolPolicy.isAllowlisted(modelId),
              let raised = raisedToolTurnWindows[modelId.lowercased()], raised > ordinary,
              let shape = kvCacheShapes[modelId.lowercased()] else {
            return ToolTurnWindow(tokens: ordinary, reason: .ordinary)
        }
        guard marketingRAMGB >= raisedToolTurnMinimumRAMGB else {
            return ToolTurnWindow(tokens: ordinary, reason: .smallPhone)
        }
        let fit = LocalMemoryBudget.fit(weightsBytes: residentWeightsBytes,
                                        workingBytes: MemoryHeadroom.workingOverheadBytes
                                            + shape.conservativeBytes(tokens: raised),
                                        backing: .copied, readings: readings)
        guard fit.fits else { return ToolTurnWindow(tokens: ordinary, reason: .memory) }
        return ToolTurnWindow(tokens: raised, reason: .raised)
    }
}
