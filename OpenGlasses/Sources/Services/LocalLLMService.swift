import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import MLXVLM
import Tokenizers
import UIKit

/// Manages on-device LLM inference via Apple's MLX framework.
/// Handles model downloading, loading, generation, and lifecycle.
@MainActor
final class LocalLLMService: ObservableObject {
    @Published var isModelLoaded = false
    @Published var downloadProgress: Double = 0
    @Published var isDownloading = false
    @Published var isGenerating = false
    @Published var isLoadingModel = false   // a model is being loaded into memory right now
    @Published var loadedModelId: String?
    @Published var downloadingModelId: String?

    private var modelContainer: ModelContainer?
    private var activeDownloadTask: Task<Void, Error>?

    /// Chain-of-thought stripped from the last generation (reasoning models only; nil
    /// otherwise). Surfaced by LLMService for the prompt inspector — never spoken.
    private(set) var lastReasoning: String?

    /// Injectable download primitive (BK P5) so a test can drive a fake download — and its
    /// cancellation — without touching the network. `nil` ⇒ the real `HubClient` path. Reports
    /// fractional progress; throws (e.g. `CancellationError`) to abort.
    var downloadFunction: ((_ modelId: String, _ onProgress: @escaping (Double) -> Void) async throws -> Void)?

    /// Set when the app enters the background during a generation so the token loop
    /// can stop before submitting the next Metal command buffer (forbidden in the
    /// background — see `generate`).
    private var enteredBackgroundDuringGeneration = false

    /// HubClient configured to store models in Application Support (persistent, not purgeable).
    private let hub: HubClient = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        var modelsDir = appSupport.appendingPathComponent("LocalModels", isDirectory: true)
        try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)

        // Multi-GB re-downloadable weights must not ride along in iCloud backups (they bloat the
        // user's backup and iOS review flags re-fetchable data that isn't excluded).
        var noBackup = URLResourceValues()
        noBackup.isExcludedFromBackup = true
        try? modelsDir.setResourceValues(noBackup)

        // Once per process, never per instance: throwaway LocalLLMService() constructions
        // (e.g. a view listing downloaded models) must not re-run the sweep while the primary
        // service has a download in flight — its live safetensors IS a CFNetworkDownload temp.
        _ = LocalLLMService.sweepOrphanedDownloadTempsOnce

        return HubClient(cache: HubCache(cacheDirectory: modelsDir))
    }()

    /// Sweep orphaned download temps: an interrupted multi-GB pull strands its
    /// CFNetworkDownload_*.tmp in the sandbox tmp dir (several GB observed in the field).
    /// Static-once: at FIRST touch in a process no download can be in flight, so everything
    /// matching is garbage; later touches (new instances) are no-ops.
    private static let sweepOrphanedDownloadTempsOnce: Void = {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        guard let items = try? FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: [.fileSizeKey]) else { return }
        var freed: Int64 = 0
        for item in items where item.lastPathComponent.hasPrefix("CFNetworkDownload_") {
            freed += Int64((try? item.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            try? FileManager.default.removeItem(at: item)
        }
        if freed > 0 {
            PrivacyLog.localModel(.tempsSwept, megabytes: Int(freed / 1_048_576))
        }
    }()

    // MARK: - Recommended Models

    /// Compatibility projection of the bundled catalog (Plan DZ P0 item 4).
    ///
    /// The list itself now lives in `LocalModelCatalog`, which owns both the display copy and the
    /// runtime facts a second backend needs. This accessor keeps every existing call site — the
    /// model picker, the agentic-features sheet, the download-size estimate — working unchanged.
    /// `LocalModelCatalogTests` pins the projection against the exact list this used to hold.
    static let recommendedModels: [RecommendedModel] = LocalModelCatalog.entries.map {
        RecommendedModel(
            id: $0.descriptor.id.rawValue,
            name: $0.descriptor.displayName,
            estimatedSize: $0.estimatedSize,
            hasVision: $0.descriptor.supportsVision,
            hasToolCalling: $0.descriptor.supportsTools,
            notes: $0.notes,
            minimumRAMGB: $0.minimumRAMGB
        )
    }

    /// Model IDs whose checkpoints declare a vision tree, attempted through `VLMModelFactory`.
    ///
    /// Gemma 4 history: the VLM factory used to fatally trap on 1-D tokens (talk-button
    /// crash); mlx-swift-lm 3.31.4 made that catchable — but a device test (2026-07-15)
    /// showed the e2b 4-bit quant failing VLM weight mapping (`keyNotFound(language_model…
    /// k_norm.weight, Gemma4RMSNormZeroShift)`). That is fixed upstream — KV-shared layers
    /// must not declare `k_proj`/`v_proj` — and the fix is pinned in `project.base.yml`, so
    /// the Gemma 4 checkpoints load as the VLMs they are and vision works.
    ///
    /// The demotion path in `loadModel` stays as the safety net: a checkpoint that still
    /// fails weight mapping loads as a perfectly good text model, and image turns are refused
    /// honestly by the vision guard in LLMService rather than answered blind.
    /// Compatibility projection of `LocalModelCatalog.visionCapableModelIDs`, which is now the
    /// single asserted source (Plan DZ P0). Same set, same behaviour.
    nonisolated static var visionModelIds: Set<String> { LocalModelCatalog.visionCapableModelIDs }

    /// Models whose VLM load failed weight mapping this run and were demoted to the text
    /// factory. In-memory: a re-uploaded checkpoint gets a fresh chance next launch.
    private(set) var visionDemotedModelIds: Set<String> = []

    /// True when the LOADED model went through `VLMModelFactory` — the single source of
    /// truth for everything factory-dependent (token batch shape, image input). Must track
    /// the factory that actually succeeded, not the id's nominal capability: a demoted
    /// Gemma fed a (1, L) batch dies in the text factory's chunked prefill (uncatchable).
    private(set) var loadedViaVLMFactory = false

    /// Whether the currently loaded model supports vision (as actually loaded).
    var isVisionModel: Bool { isModelLoaded && loadedViaVLMFactory }

    /// Vision capability by model id — architectural claim, usable before load.
    nonisolated static func isVisionCapable(modelId: String) -> Bool {
        visionModelIds.contains(modelId)
    }

    /// Vision usability by model id, demotion-aware. Prefer this over the static check
    /// when a service instance is in hand: after a VLM→text demotion the architectural
    /// claim is true but images would be silently dropped.
    func isVisionUsable(modelId: String) -> Bool {
        if loadedModelId == modelId, isModelLoaded { return loadedViaVLMFactory }
        return Self.visionModelIds.contains(modelId) && !visionDemotedModelIds.contains(modelId)
    }

    // MARK: - Model Management

    /// Download a model from HuggingFace without loading into memory.
    /// Only one download runs at a time — call cancelDownload() first if needed.
    func downloadModel(_ modelId: String) async throws {
        // BK P5: a second download while one is live is refused with a VISIBLE error (was a silent
        // `return`, which let a second multi-GB download start over the same shared progress state).
        guard !isDownloading else {
            throw LocalLLMError.alreadyDownloading
        }
        isDownloading = true
        downloadingModelId = modelId
        downloadProgress = 0
        // A multi-GB pull dies when iOS auto-locks the screen (the app suspends and the transfer
        // is torn down), so keep the display awake for the duration. Restored in the defer on
        // every exit path — completion, cancel, or error. No other feature owns this flag.
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            UIApplication.shared.isIdleTimerDisabled = false
            isDownloading = false
            downloadingModelId = nil
            activeDownloadTask = nil
        }

        // The hub's progress callback is per-FILE (a fresh 0→1 fraction each file), and a model
        // is mostly one giant safetensors — so the fraction sits at 0 for the whole pull, then
        // jumps to done. For catalog models (known expected size) poll the bytes actually on
        // disk instead, as the SINGLE progress writer; unknown/custom ids keep the hub fraction.
        let expectedBytes = Self.expectedDownloadBytes(for: modelId)
        let downloadStart = Date()
        var progressPoller: Task<Void, Never>?
        if let expectedBytes, expectedBytes > 0 {
            progressPoller = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    let bytes = self.onDiskDownloadBytes(for: modelId, since: downloadStart)
                    let est = min(0.99, Double(bytes) / Double(expectedBytes))
                    if est > self.downloadProgress { self.downloadProgress = est }   // monotonic
                    try? await Task.sleep(nanoseconds: 700_000_000)
                }
            }
        }
        defer { progressPoller?.cancel() }

        // BK P5: own the cancellable unit. Before, the real Task lived in the caller and
        // `activeDownloadTask` was permanently nil, so `cancelDownload()` cancelled nothing and
        // `hub.downloadSnapshot` ran to completion — Cancel was a UI-only no-op. Running the
        // download inside `activeDownloadTask` means cancellation reaches the network/disk layer.
        let task = Task { [weak self] in
            guard let self else { return }
            if let fake = self.downloadFunction {
                try await fake(modelId) { self.downloadProgress = $0 }
            } else {
                guard let repoID = Repo.ID(rawValue: modelId) else {
                    throw LocalLLMError.generationFailed("Invalid model id: \(modelId)")
                }
                _ = try await self.hub.downloadSnapshot(of: repoID) { @MainActor progress in
                    // Single-writer rule: when the byte poller runs, the per-file fraction is
                    // noise (it thrashes 1%↔99%); only unknown-size models use it.
                    if expectedBytes == nil { self.downloadProgress = progress.fractionCompleted }
                }
            }
        }
        activeDownloadTask = task
        do {
            try await task.value
        } catch is CancellationError {
            PrivacyLog.localModel(.downloadCancelled, model: PrivacyToken(modelId))
            throw CancellationError()
        }

        downloadProgress = 1.0
        PrivacyLog.localModel(.downloaded, model: PrivacyToken(modelId))
    }

    /// Cancel any in-progress download and reset state (BK P5). Now that the download runs inside
    /// `activeDownloadTask`, this actually stops it instead of just clearing the UI flags.
    func cancelDownload() {
        activeDownloadTask?.cancel()
        activeDownloadTask = nil
        isDownloading = false
        downloadingModelId = nil
        downloadProgress = 0
        UIApplication.shared.isIdleTimerDisabled = false   // belt-and-braces with downloadModel's defer
    }

    /// Load an already-downloaded model into memory.
    /// Uses LLMModelFactory for text models, VLMModelFactory for vision models.
    func loadModel(_ modelId: String) async throws {
        if loadedModelId == modelId && isModelLoaded {
            return  // Already loaded — no GPU work needed, safe even in background
        }

        // Loading materializes model weights on the GPU via Metal (same restriction
        // as generate()), which iOS forbids in the background. The model is unloaded
        // when the app backgrounds, so a backgrounded scheduled task would otherwise
        // try to reload here and crash. Refuse early with a catchable error so callers
        // can defer.
        guard UIApplication.shared.applicationState != .background else {
            throw LocalLLMError.backgrounded
        }

        // Memory headroom gate: weights bigger than the app's remaining allocation
        // budget don't fail cleanly — the load (or first generation) thrashes the
        // compressor and ends in a silent Jetsam kill. Refuse with a catchable,
        // speakable error instead. Skipped when either number is unknown (model not
        // on disk yet, or no per-app budget on this platform — see MemoryHeadroom).
        //
        // Runs BEFORE the unload below so a refused load keeps the current model
        // usable — but credits the outgoing model's weights back to the budget
        // (effectiveAvailableBytes), so swapping models on a full phone isn't
        // refused when the swap itself would fit.
        let modelBytes = modelSizeOnDisk(modelId)
        let reclaimableBytes = loadedModelId.map { modelSizeOnDisk($0) } ?? 0
        let availableBytes = MemoryHeadroom.effectiveAvailableBytes(
            budget: MemoryHeadroom.availableBytes(), reclaimableBytes: reclaimableBytes)
        guard MemoryHeadroom.canLoad(modelBytes: modelBytes, availableBytes: availableBytes) else {
            throw LocalLLMError.insufficientMemory(
                neededBytes: modelBytes + MemoryHeadroom.workingOverheadBytes,
                availableBytes: availableBytes)
        }

        isLoadingModel = true
        defer { isLoadingModel = false }
        unloadModel()

        // MLX recycles evaluation buffers through a cache whose default limit is Metal's
        // recommendedMaxWorkingSetSize — effectively "all of RAM" on iPhone. Left uncapped,
        // each turn's temporaries accumulate there instead of returning to the OS (Gemma's
        // 262k-vocab chunked-prefill logits are ~256 MB apiece): observed 2.6 → 6.0 GB app
        // footprint over five questions, ending in a silent Jetsam kill with every daemon
        // on the phone idle-exited (2026-07-13 19:12 JetsamEvent). Cap it small per MLX's
        // own iOS guidance; set here (not init) so simulator unit tests never touch Metal.
        Memory.cacheLimit = 20 * 1024 * 1024

        let config = Self.modelConfiguration(for: modelId)
        func load(with factory: any ModelFactory) async throws -> ModelContainer {
            try await factory.loadContainer(
                from: #hubDownloader(hub),
                using: #huggingFaceTokenizerLoader(),
                configuration: config
            ) { progress in
                Task { @MainActor in
                    self.downloadProgress = progress.fractionCompleted
                }
            }
        }

        let wantsVision = Self.visionModelIds.contains(modelId)
            && !visionDemotedModelIds.contains(modelId)
        if wantsVision {
            do {
                modelContainer = try await load(with: VLMModelFactory.shared)
                loadedViaVLMFactory = true
            } catch {
                // The known shape of this failure was a quant whose weight tree didn't match
                // the VLM export (keyNotFound …k_norm.weight — device trace 2026-07-15),
                // fixed upstream and pinned. Whatever the cause, a model that fails VLM
                // mapping is still a perfectly good text model: demote for this run and load
                // through the text factory. Image turns then get the honest refusal instead
                // of a broken load.
                PrivacyLog.localModel(.visionDemoted, model: PrivacyToken(modelId),
                                      error: SafeErrorSummary(error))
                visionDemotedModelIds.insert(modelId)
                modelContainer = try await load(with: LLMModelFactory.shared)
                loadedViaVLMFactory = false
            }
        } else {
            modelContainer = try await load(with: LLMModelFactory.shared)
            loadedViaVLMFactory = false
        }

        loadedModelId = modelId
        isModelLoaded = true
        PrivacyLog.localModel(.loaded, model: PrivacyToken(modelId), vision: loadedViaVLMFactory)
    }

    /// Unload model from memory.
    func unloadModel() {
        let hadModel = modelContainer != nil
        modelContainer = nil
        loadedModelId = nil
        isModelLoaded = false
        loadedViaVLMFactory = false
        if hadModel {
            // Return MLX's recycled evaluation buffers to the OS — without this, Unload
            // frees the weights but leaves the buffer cache resident. Guarded so a
            // never-loaded service (unit tests on the simulator) never touches Metal.
            Memory.clearCache()
        }
        PrivacyLog.localModel(.unloaded)
    }

    // MARK: - Generation

    /// Generate a text response from the local model.
    /// - Parameter imageData: an image for the turn (VLM models only). Honored only when the
    ///   loaded model actually went through the VLM factory; the vision guard in LLMService
    ///   refuses image turns upstream otherwise, so a non-nil image here with a text-factory
    ///   model is a caller bug — logged and ignored rather than crashed on.
    func generate(
        userMessage: String,
        systemPrompt: String,
        history: [(role: String, content: String)] = [],
        imageData: Data? = nil,
        onToken: ((String) -> Void)? = nil
    ) async throws -> String {
        // On-device inference runs on the GPU via Metal, which iOS forbids in the
        // background: submitting a command buffer there raises
        // kIOGPUCommandBufferCallbackErrorBackgroundExecutionNotPermitted, which MLX
        // surfaces as an *uncatchable* C++ exception that terminates the process.
        // Refuse early with a catchable Swift error so callers can defer instead.
        // BK P4: one generation at a time per ModelContainer. A fast follow-up (or a stray
        // concurrent call) must not enter while a generation is live — two token loops on one
        // container is undefined. Checked before we flip `isGenerating`. (The sequential
        // re-generations inside `sendLocal` are strictly one-at-a-time and won't trip this.)
        guard !isGenerating else {
            throw LocalLLMError.alreadyGenerating
        }
        guard UIApplication.shared.applicationState != .background else {
            throw LocalLLMError.backgrounded
        }
        guard let container = modelContainer else {
            throw LocalLLMError.modelNotLoaded
        }

        isGenerating = true
        defer { isGenerating = false }

        // Image turn (P: local vision): route through the VLM processor, which owns the
        // model's own chat template and image tokenization — the manual tokenize path below
        // has no way to interleave image tokens.
        if let imageData {
            if loadedViaVLMFactory {
                if Gemma4ChatPrompt.matches(modelId: loadedModelId) {
                    return try await generateGemma4Turn(
                        userMessage: userMessage, systemPrompt: systemPrompt,
                        history: history, imageData: imageData,
                        container: container, onToken: onToken)
                }
                return try await generateVisionTurn(
                    userMessage: userMessage, systemPrompt: systemPrompt,
                    history: history, imageData: imageData,
                    container: container, onToken: onToken)
            }
            // Reachable despite the upstream guard: the first-ever photo question loads the
            // model DURING the turn, and the VLM→text demotion happens after the guard already
            // passed. Refuse honestly — silently answering text-only about an image the model
            // never saw is the exact hallucination the vision guard exists to prevent.
            PrivacyLog.localModel(.imageRefused, model: PrivacyToken(loadedModelId ?? "unknown"))
            return Self.visionWeightsUnavailableMessage
        }

        let tokenizer = await container.tokenizer

        // A Gemma 4 that loaded through the VLM factory takes its own path even for a text
        // turn: the VLM processor owns the model's chat template and the `LMInput` shape it
        // expects, and hand-assembling either is how the old crashes happened. History is
        // still budgeted first — measured with the same render the processor's template
        // produces, so the count matches what the model will actually see.
        if loadedViaVLMFactory && Gemma4ChatPrompt.matches(modelId: loadedModelId) {
            let budget = LocalModelBudget.promptBudget(for: loadedModelId)
            let trimmedHistory = try LocalModelBudget.historyFittingBudget(
                history: history, budget: budget
            ) { hist in
                let text = Gemma4ChatPrompt.render(
                    system: systemPrompt, history: hist, userMessage: userMessage,
                    bosToken: tokenizer.bosToken)
                return tokenizer.encode(text: text, addSpecialTokens: false).count
            }
            if trimmedHistory.count < history.count {
                PrivacyLog.localModel(.historyTrimmed, count: trimmedHistory.count,
                                      total: history.count, tokens: budget)
            }
            return try await generateGemma4Turn(
                userMessage: userMessage, systemPrompt: systemPrompt,
                history: trimmedHistory, imageData: nil,
                container: container, onToken: onToken)
        }

        // Tokenize a candidate history exactly as the model will — chat template, with the
        // no-system-role fallback some small models need. Used both to measure truncation
        // candidates and to produce the final token ids.
        func tokenize(_ hist: [(role: String, content: String)]) throws -> [Int] {
            var messages: [[String: String]] = [["role": "system", "content": systemPrompt]]
            for turn in hist { messages.append(["role": turn.role, "content": turn.content]) }
            messages.append(["role": "user", "content": userMessage])
            do {
                return try tokenizer.applyChatTemplate(messages: messages)
            } catch {
                // Gemma 4's `chat_template.jinja` uses constructs swift-jinja's parser rejects.
                // That is a *template* failure, not a "no system role" one, and the role-merging
                // fallback below would be the wrong repair: render Gemma's turn format directly
                // instead, which keeps the genuine system turn the template emits.
                if Gemma4ChatPrompt.isTemplateParseFailure(error),
                   Gemma4ChatPrompt.matches(modelId: loadedModelId) {
                    let text = Gemma4ChatPrompt.render(
                        system: systemPrompt, history: hist, userMessage: userMessage,
                        bosToken: tokenizer.bosToken)
                    return tokenizer.encode(text: text, addSpecialTokens: false)
                }
                // Merge the system prompt into the user turn for models without a system role.
                // No "User:" transcript label — a small model reads a speaker-labelled dialogue
                // and can flip roles, replying *as* the user addressed to the persona name.
                var fallback: [[String: String]] = []
                for turn in hist { fallback.append(["role": turn.role, "content": turn.content]) }
                fallback.append(["role": "user", "content": systemPrompt + "\n\n" + userMessage])
                return try tokenizer.applyChatTemplate(messages: fallback)
            }
        }

        // BK P2: budget the prompt from the *loaded model's* context window minus the generation
        // reserve (prompt + up to 512 new tokens must both fit, or generation OOMs mid-stream —
        // an uncatchable per-token kill), then truncate oldest-history-first to fit instead of
        // hard-rejecting. Only a prompt that can't be trimmed under budget (system + current turn
        // alone too big) throws `.promptTooLong` — catchable, so the caller can fall back to cloud.
        let budget = LocalModelBudget.promptBudget(for: loadedModelId)
        let trimmedHistory = try LocalModelBudget.historyFittingBudget(
            history: history, budget: budget
        ) { try tokenize($0).count }
        if trimmedHistory.count < history.count {
            PrivacyLog.localModel(.historyTrimmed, count: trimmedHistory.count,
                                  total: history.count, tokens: budget)
        }
        let tokens = try tokenize(trimmedHistory)

        // Token shape depends on which factory loaded the model:
        // - Text models (LLMModelFactory) MUST get 1D (L,) tokens. The library's default
        //   `prepare` chunks prompts longer than the 512-token prefill step as
        //   `y[.newAxis, ..<512]` / `y = y[512...]`, which assumes 1D — on a (1, L) batch
        //   those slices hit axis 0, so the remainder becomes an EMPTY (0, L) array and the
        //   next forward pass dies in QuantizedEmbedding's reshape ("cannot infer dimension"),
        //   an uncatchable fatal MLX error. Short prompts skip the chunk loop, which is why
        //   a (1, L) batch *appeared* to work: any real question (system prompt + tools
        //   > 512 tokens) crashed the app.
        // - Vision models (VLMModelFactory, e.g. SmolVLM2/Idefics3) skip that chunked
        //   prepare and feed the tokens to the language model in one shot, so they need the
        //   explicit (1, L) batch axis (their forward pass indexes dim(2)).
        // Keyed off the factory that ACTUALLY loaded the model, never the id's nominal
        // capability — after a VLM→text demotion, a (1, L) batch here is the fatal crash.
        let tokenIDs = Self.tokenBatch(tokens, isVisionModel: loadedViaVLMFactory)
        // Emitted before the prefill so it survives a fatal MLX crash in the unified log,
        // confirming what shape reaches the model.
        PrivacyLog.localModel(.tokenShape, model: PrivacyToken(loadedModelId ?? "unknown"),
                              tokens: tokens.count,
                              shape: PrivacyToken(tokenIDs.shape.map(String.init).joined(separator: "x")))

        let input = LMInput(text: .init(tokens: tokenIDs))

        // Watch for backgrounding *during* generation. The pre-check above covers
        // the already-backgrounded case; this covers the app being sent to the
        // background mid-stream, where the next per-token Metal eval would crash.
        enteredBackgroundDuringGeneration = false
        let bgObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Delivered on the main thread; this type is @MainActor.
            MainActor.assumeIsolated { self?.enteredBackgroundDuringGeneration = true }
        }
        defer { NotificationCenter.default.removeObserver(bgObserver) }

        // Generate — sampling and token cap are per-model (reasoning models differ)
        let parameters = Self.generateParameters(for: loadedModelId)
        let stream = try await container.generate(input: input, parameters: parameters)

        // Reasoning models (LFM2.5) start every completion inside a template-opened <think>
        // block. Suppress it on the token stream (the UI preview must not show — and TTS
        // must not speak — chain-of-thought) and strip it from the returned text below.
        let isReasoningModel = LocalModelBudget.reasoningModelIds.contains(loadedModelId ?? "")
        var filteredOnToken = onToken
        if isReasoningModel, let onToken {
            // No end-of-stream flush needed: the caller replaces the streamed preview with
            // the (fully stripped) returned text, so a held-back tail is only cosmetic.
            let filter = ThinkStreamFilter()
            filteredOnToken = { chunk in
                let visible = filter.ingest(chunk)
                if !visible.isEmpty { onToken(visible) }
            }
        }

        // Drive the stream through the pure loop below so we can bail out *before* requesting the
        // next token — before MLX submits the next Metal command buffer. Non-text generations
        // (`.toolCall`/unknown) are skipped; the loop keeps pulling until a text chunk or the end.
        //
        // `.info` is the exception (Plan CU P1): MLX reports its own token count and decode time
        // there, and that pair is the *only* input `TurnTimeline.tokensPerSecond` accepts — a rate
        // taken from timeline marks would divide a first-wins, backfilled window into a token count
        // it doesn't cover. Captured here and applied below rather than from inside the closure,
        // which is deliberately kept free of anything that could suspend mid-generation.
        var reported: GenerateCompletionInfo?
        var iterator = stream.makeAsyncIterator()
        let output = try await Self.drainTokenStream(
            nextChunk: {
                while let generation = await iterator.next() {
                    if case .chunk(let text) = generation { return text }
                    if case .info(let info) = generation { reported = info }
                }
                return nil
            },
            isBackgrounded: { [weak self] in
                (self?.enteredBackgroundDuringGeneration ?? false) || UIApplication.shared.applicationState == .background
            },
            // Plan CU P1: first-token is worth marking whether or not the caller wanted a streamed
            // preview — voice turns pass no `onToken` at all, and this is the only per-chunk seam
            // the local path has.
            onToken: { chunk in
                TurnRecorder.markFirstToken()
                filteredOnToken?(chunk)
            }
        )
        if let reported {
            TurnRecorder.addGeneration(tokens: reported.generationTokenCount, seconds: reported.generateTime)
        }
        // Memory telemetry per turn — footprint should now stay flat across questions;
        // before the cacheLimit cap it grew ~0.7 GB per turn until the Jetsam kill.
        PrivacyLog.localModel(.generationCompleted, megabytes: Memory.activeMemory / 1_048_576,
                              cacheMegabytes: Memory.cacheMemory / 1_048_576,
                              footprintMegabytes: Int(MemoryHeadroom.appFootprintBytes() / 1_048_576))

        // Strip the think block from the RETURNED text too, at this layer rather than in
        // LLMService: every consumer (tool-call parsing, corrective regens, uncertainty
        // re-ask query rewriting, agent scheduler) must see the answer only — think text
        // routinely "announces" plans and would false-trigger the announce-without-action
        // corrective regen, or leak reasoning into a web-search query. An all-think
        // completion (reserve exhausted mid-think) returns empty here, which the caller's
        // empty-completion guard surfaces as a catchable error instead of dead air.
        if isReasoningModel {
            let (spoken, reasoning) = ThinkStreamFilter.strip(output)
            lastReasoning = reasoning
            if let reasoning {
                PrivacyLog.localModel(.reasoningProduced, characters: reasoning.count)
            }
            return spoken
        }
        lastReasoning = nil
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One turn — text or photo — on a Gemma 4 that loaded through the VLM factory.
    ///
    /// Everything goes through `context.processor.prepare`, which owns Gemma's chat template
    /// and (for a photo) the interleaving of image soft tokens. Hand-assembling the `LMInput`
    /// is the fallback, not the plan: it happens only when swift-jinja cannot parse Gemma's
    /// template, and then the hand-render mirrors what the template emits — a genuine system
    /// turn, `<|turn>`/`<turn|>` delimiters, `assistant` mapped to `model`.
    ///
    /// A photo turn's prefill is one unchunked forward pass, so how much prompt it can afford
    /// is a property of the device, not of the model: `LocalModelBudget.multimodalTurnPlan`
    /// decides, and a roomy phone keeps its configured prompt and history.
    private func generateGemma4Turn(
        userMessage: String,
        systemPrompt: String,
        history: [(role: String, content: String)],
        imageData: Data?,
        container: ModelContainer,
        onToken: ((String) -> Void)?
    ) async throws -> String {
        let parameters = Self.generateParameters(for: loadedModelId)

        // Same mid-generation backgrounding watch as the other paths, via a lock-guarded box
        // because the drain runs off the main actor inside `container.perform`.
        let backgroundedFlag = LockedFlag()
        let bgObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { _ in
            backgroundedFlag.set()
        }
        defer { NotificationCenter.default.removeObserver(bgObserver) }

        let effectiveSystem: String
        let effectiveHistory: [(role: String, content: String)]
        // Long edge the photo may reach the processor at; 0 on a text turn. Assigned once in each
        // branch so the concurrently executing `container.perform` closure captures an immutable
        // value rather than a mutable local.
        let imageLongEdge: Int
        if let photo = imageData {
            // Measured now, not at launch: the binding constraint on a photo turn is what this
            // process may still allocate, and with the model resident and the camera live that
            // is a completely different number from the device's RAM.
            let headroom = MemoryHeadroom.availableBytes()
            let plan = LocalModelBudget.multimodalTurnPlan(
                for: loadedModelId, marketingRAMGB: Self.marketingRAMGB, availableBytes: headroom)
            PrivacyLog.localModel(.generationStarted,
                                  model: PrivacyToken(loadedModelId ?? "unknown"),
                                  footprintMegabytes: Int(MemoryHeadroom.appFootprintBytes() / 1_048_576),
                                  headroomMegabytes: Int(headroom / 1_048_576),
                                  kilobytes: photo.count / 1024,
                                  detail: PrivacyToken((plan.keepsFullSystemPrompt ? "fullPrompt" : "compactPrompt")
                                                       + (plan.refusesImage ? "-refused" : "")))
            // Say so rather than starting a prefill that ends as a process kill. A photo turn on
            // an already-resident multi-gigabyte model crossed the per-process cap on a 12 GB
            // phone and took the app to the home screen with no error and no recording of why.
            guard !plan.refusesImage else { throw LocalLLMError.insufficientMemoryForPhoto }
            effectiveSystem = plan.keepsFullSystemPrompt
                ? systemPrompt
                : Config.compactVisionTurnPrompt(from: systemPrompt)
            effectiveHistory = plan.keepsHistory ? Array(history.suffix(4)) : []
            imageLongEdge = plan.imageLongEdge
        } else {
            effectiveSystem = systemPrompt
            effectiveHistory = history
            imageLongEdge = 0
            PrivacyLog.localModel(.generationStarted,
                                  model: PrivacyToken(loadedModelId ?? "unknown"),
                                  detail: PrivacyToken("textOnly"))
        }

        let report = LockedGenerationReport()
        // `UserInput` (and any `CIImage` in it) isn't `Sendable`, so it is built inside the
        // `@Sendable` closure from Sendable ingredients only.
        let output = try await container.perform { context -> String in
            var chat: [Chat.Message] = [.system(effectiveSystem)]
            for turn in effectiveHistory {
                chat.append(turn.role == "assistant" ? .assistant(turn.content) : .user(turn.content))
            }
            var resize: CGSize?
            if let imageData {
                guard let ciImage = CIImage(data: imageData) else {
                    throw LocalLLMError.generationFailed("Couldn't decode the photo.")
                }
                chat.append(.user(userMessage, images: [.ciImage(ciImage)]))
                // Bounded, not squashed. There was no cap here at all, on the reasoning that
                // Gemma's processor picks its own canvas and its own soft-token count — true of
                // the *token* count, and beside the point for memory: preprocessing a
                // full-resolution frame materialises it as float pixels on top of a resident
                // multi-gigabyte model, which is where the per-process cap was crossed. The size
                // is computed aspect-preserving rather than passed as a square, so the crop the
                // old comment was defending is still intact.
                resize = LocalModelBudget.imageSize(width: Int(ciImage.extent.width),
                                                    height: Int(ciImage.extent.height),
                                                    maxLongEdge: imageLongEdge)
            } else {
                chat.append(.user(userMessage))
            }

            let userInput = resize.map { UserInput(chat: chat, processing: .init(resize: $0)) }
                ?? UserInput(chat: chat)
            let lmInput: LMInput
            do {
                lmInput = try await context.processor.prepare(input: userInput)
            } catch {
                // Only the text turn can be rescued by hand: a photo turn's soft tokens can
                // only be produced by the processor, so a failure there has to surface.
                guard imageData == nil, Gemma4ChatPrompt.isTemplateParseFailure(error) else { throw error }
                let text = Gemma4ChatPrompt.render(
                    system: effectiveSystem, history: effectiveHistory, userMessage: userMessage,
                    bosToken: context.tokenizer.bosToken)
                let tokens = context.tokenizer.encode(text: text, addSpecialTokens: false)
                // VLM-factory shape: (1, L). The mask must be explicit — a nil mask reaches
                // Metal as a null buffer.
                let promptArray = Self.tokenBatch(tokens, isVisionModel: true)
                lmInput = LMInput(text: .init(tokens: promptArray,
                                              mask: ones(like: promptArray).asType(.int8)))
            }

            PrivacyLog.localModel(.tokenShape, tokens: lmInput.text.tokens.size,
                                  shape: PrivacyToken(lmInput.text.tokens.shape
                                                        .map(String.init).joined(separator: "x")))

            let stream = try MLXLMCommon.generate(
                input: lmInput, parameters: parameters, context: context)
            var iterator = stream.makeAsyncIterator()
            return try await Self.drainTokenStream(
                nextChunk: {
                    while let generation = await iterator.next() {
                        if case .chunk(let text) = generation { return text }
                        if case .info(let info) = generation { report.note(info) }
                    }
                    return nil
                },
                isBackgrounded: { backgroundedFlag.isSet },
                onToken: { chunk in
                    report.noteToken(at: Date())
                    onToken?(chunk)
                }
            )
        }
        if let firstTokenAt = report.firstTokenAt { TurnRecorder.mark(.firstToken, at: firstTokenAt) }
        if let completion = report.completion {
            TurnRecorder.addGeneration(tokens: completion.generationTokenCount, seconds: completion.generateTime)
        }
        PrivacyLog.localModel(.generationCompleted, megabytes: Memory.activeMemory / 1_048_576,
                              cacheMegabytes: Memory.cacheMemory / 1_048_576,
                              detail: PrivacyToken("gemma4Turn"))
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One image turn through a VLM-factory model. The processor owns the chat template and
    /// image tokenization; history is kept short (image tokens are big) and un-budgeted — the
    /// processor's own encoding is the authority on how many tokens the image costs.
    private func generateVisionTurn(
        userMessage: String,
        systemPrompt: String,
        history: [(role: String, content: String)],
        imageData: Data,
        container: ModelContainer,
        onToken: ((String) -> Void)?
    ) async throws -> String {
        let parameters = GenerateParameters(maxTokens: 512, temperature: 0.7, topP: 0.9)

        // Same mid-generation backgrounding watch as the text path (Metal in the background
        // is an uncatchable kill) — but the drain runs inside `container.perform`, OFF the
        // main actor, so the flag must be a lock-guarded box rather than this actor's
        // property (and UIApplication can't be re-read there; the entry pre-check plus the
        // notification cover it).
        let backgroundedFlag = LockedFlag()
        let bgObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { _ in
            backgroundedFlag.set()
        }
        defer { NotificationCenter.default.removeObserver(bgObserver) }

        // Same turn-time headroom gate as the Gemma path: a smaller VLM is still a resident model
        // plus an unchunked multimodal prefill, and the per-process cap does not care which
        // factory loaded it.
        let visionPlan = LocalModelBudget.multimodalTurnPlan(
            for: loadedModelId, marketingRAMGB: Self.marketingRAMGB,
            availableBytes: MemoryHeadroom.availableBytes())
        guard !visionPlan.refusesImage else { throw LocalLLMError.insufficientMemoryForPhoto }
        let visionLongEdge = visionPlan.imageLongEdge
        PrivacyLog.localModel(.generationStarted,
                              model: PrivacyToken(loadedModelId ?? "unknown"),
                              count: visionLongEdge, kilobytes: imageData.count / 1024,
                              detail: PrivacyToken("visionTurn"))
        // `UserInput` (and the `CIImage` inside it) isn't `Sendable`, so it's built *inside* the
        // `@Sendable` closure from Sendable ingredients only — the image data, the prompt strings
        // and the history — rather than constructed out here and captured across the boundary.
        let report = LockedGenerationReport()
        let output = try await container.perform { context -> String in
            guard let ciImage = CIImage(data: imageData) else {
                throw LocalLLMError.generationFailed("Couldn't decode the photo.")
            }
            var chat: [Chat.Message] = [.system(systemPrompt)]
            for turn in history.suffix(4) {
                chat.append(turn.role == "assistant" ? .assistant(turn.content) : .user(turn.content))
            }
            chat.append(.user(userMessage, images: [.ciImage(ciImage)]))
            // Capped, because a full-resolution glasses photo through the image pipeline is a
            // pure memory spike — but aspect-preserving now rather than squashed into a square,
            // and at the long edge this turn's headroom actually allows.
            let resize = LocalModelBudget.imageSize(width: Int(ciImage.extent.width),
                                                    height: Int(ciImage.extent.height),
                                                    maxLongEdge: visionLongEdge)
                ?? CGSize(width: ciImage.extent.width, height: ciImage.extent.height)
            let userInput = UserInput(chat: chat, processing: .init(resize: resize))
            let lmInput = try await context.processor.prepare(input: userInput)
            let stream = try MLXLMCommon.generate(input: lmInput, parameters: parameters, context: context)
            var iterator = stream.makeAsyncIterator()
            return try await Self.drainTokenStream(
                nextChunk: {
                    while let generation = await iterator.next() {
                        if case .chunk(let text) = generation { return text }
                        if case .info(let info) = generation { report.note(info) }
                    }
                    return nil
                },
                isBackgrounded: { backgroundedFlag.isSet },
                onToken: { chunk in
                    report.noteToken(at: Date())
                    onToken?(chunk)
                }
            )
        }
        // Plan CU P1: applied on this side of `container.perform`, where the main actor is ours
        // again. First token is the wall-clock stamp the drain took; the token/decode pair is MLX's
        // own report, the only pair `TurnTimeline.tokensPerSecond` will divide.
        if let firstTokenAt = report.firstTokenAt { TurnRecorder.mark(.firstToken, at: firstTokenAt) }
        if let completion = report.completion {
            TurnRecorder.addGeneration(tokens: completion.generationTokenCount, seconds: completion.generateTime)
        }
        PrivacyLog.localModel(.generationCompleted, megabytes: Memory.activeMemory / 1_048_576,
                              cacheMegabytes: Memory.cacheMemory / 1_048_576,
                              detail: PrivacyToken("visionTurn"))
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Sampling parameters per model. Reasoning models (LFM2.5) follow Liquid's recommended
    /// low-temperature settings (temp 0.1, top-k 50, repetition penalty 1.1) and take their
    /// token cap from `LocalModelBudget.generationReserve(for:)` — the think block spends
    /// from the same cap as the spoken answer, so they get the larger reasoning reserve.
    /// Everything else keeps the long-standing defaults.
    nonisolated static func generateParameters(for modelId: String?) -> GenerateParameters {
        if let modelId, LocalModelBudget.reasoningModelIds.contains(modelId) {
            return GenerateParameters(
                maxTokens: LocalModelBudget.generationReserve(for: modelId),
                temperature: 0.1,
                topK: 50,
                repetitionPenalty: 1.1
            )
        }
        return GenerateParameters(
            maxTokens: LocalModelBudget.generationReserve(for: modelId),
            temperature: 0.7,
            topP: 0.9
        )
    }

    /// Load configuration for a model id.
    ///
    /// Gemma 4 needs `<turn|>` declared as an extra stop token: its `tokenizer_config.json`
    /// sets `eos_token` to `<eos>` while the chat template ends every turn with the separate
    /// `eot_token` `<turn|>`. Without it the model runs straight through the end of its answer
    /// into a hallucinated next turn.
    nonisolated static func modelConfiguration(for modelId: String) -> ModelConfiguration {
        if Gemma4ChatPrompt.matches(modelId: modelId) {
            return ModelConfiguration(id: modelId, extraEOSTokens: [Gemma4ChatPrompt.endOfTurnToken])
        }
        return ModelConfiguration(id: modelId)
    }

    /// Shape token ids for the loaded model (see the call site in `generate` for why):
    /// 1D (L,) for text-factory models — their chunked prefill slices axis 0 and an explicit
    /// batch axis fatally breaks prompts over the prefill step size; (1, L) for vision-factory
    /// models, whose prepare skips chunking and requires the batch axis.
    nonisolated static func tokenBatch(_ tokens: [Int], isVisionModel: Bool) -> MLXArray {
        let array = MLXArray(tokens)
        return isVisionModel ? array.expandedDimensions(axis: 0) : array
    }

    /// Pure token-drain loop (BK P4). Accumulates text chunks, honouring:
    /// - **Barge-in cancellation** — checked every iteration *before* pulling the next token, and
    ///   it always **throws `CancellationError`** (never a partial return). `ConversationTurnRunner`
    ///   maps `CancellationError` → `onCancelled`, the only path where a barge-in doesn't speak the
    ///   partial reply. Without this the MLX loop polled only background state, so `stop`/barge-in
    ///   marked the task cancelled but inference ran to completion (GPU/battery burn).
    /// - **Mid-stream backgrounding** — bail before the next Metal eval (uncatchable GPU crash);
    ///   return what we have, or throw `.backgrounded` if nothing was produced.
    ///
    /// `nextChunk`/`isBackgrounded` are injected so a fake stream drives this headlessly (no MLX
    /// model / GPU). Returns the accumulated (untrimmed) output.
    static func drainTokenStream(
        nextChunk: () async -> String?,
        isBackgrounded: () -> Bool,
        onToken: ((String) -> Void)?
    ) async throws -> String {
        var output = ""
        while true {
            try Task.checkCancellation()
            if isBackgrounded() {
                if output.isEmpty { throw LocalLLMError.backgrounded }
                break
            }
            guard let text = await nextChunk() else { break }
            output += text
            onToken?(text)
        }
        return output
    }

    // MARK: - Storage Info

    /// Persistent model storage directory (Application Support, never purged by iOS).
    /// `nonisolated static` so callers outside the main actor (first-run defaults) can ask what
    /// is on disk without touching the service.
    nonisolated static var modelCacheDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("LocalModels", isDirectory: true)
    }

    var modelDirectory: URL { Self.modelCacheDirectory }

    /// Get the on-disk path for a model. swift-huggingface uses a Python-compatible
    /// cache layout: <cacheDir>/models--{org}--{name}/
    private func modelPath(_ modelId: String) -> URL {
        let repoName = modelId.replacingOccurrences(of: "/", with: "--")
        return modelDirectory.appendingPathComponent("models--\(repoName)", isDirectory: true)
    }

    /// Check if a model is downloaded.
    func isModelDownloaded(_ modelId: String) -> Bool {
        FileManager.default.fileExists(atPath: modelPath(modelId).path)
    }

    /// Get size of a downloaded model on disk.
    func modelSizeOnDisk(_ modelId: String) -> Int64 {
        directorySize(modelPath(modelId))
    }

    /// Spoken/shown when an image reaches a model whose VLM load was demoted to text-only.
    /// Single source — LLMService's pre-flight guard and the in-generation net both return it.
    static let visionWeightsUnavailableMessage =
        "This model's vision weights couldn't load on this device, so it's running text-only. For photos, switch to SmolVLM2 or a cloud model."

    /// Expected full-snapshot size for a catalog model (parsed from its `estimatedSize`), or nil
    /// for custom/unknown ids. Drives the byte-based download progress estimate.
    /// `nonisolated` now that it reads only the (pure) catalog — callers outside the main actor
    /// can ask a model's expected size without hopping.
    nonisolated static func expectedDownloadBytes(for modelId: String) -> Int64? {
        guard let entry = LocalModelCatalog.entry(for: LocalModelID(modelId)) else { return nil }
        return LocalModelCatalog.bytes(fromEstimatedSize: entry.estimatedSize)
    }

    /// Bytes on disk attributable to an in-progress download: the partial snapshot plus
    /// CFNetwork's in-flight temp files (where the big safetensors grows until completion).
    /// Only temps created after `start` count — a stale orphan would jump the bar to 99%.
    private func onDiskDownloadBytes(for modelId: String, since start: Date) -> Int64 {
        var total = modelSizeOnDisk(modelId)
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        if let items = try? FileManager.default.contentsOfDirectory(
            at: tmp, includingPropertiesForKeys: [.creationDateKey, .fileSizeKey]
        ) {
            for item in items where item.lastPathComponent.hasPrefix("CFNetworkDownload_") {
                let values = try? item.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])
                let created = values?.creationDate ?? .distantPast
                if created >= start { total += Int64(values?.fileSize ?? 0) }
            }
        }
        return total
    }

    /// Delete a downloaded model.
    func deleteModel(_ modelId: String) throws {
        if loadedModelId == modelId {
            unloadModel()
        }
        let path = modelPath(modelId)
        if FileManager.default.fileExists(atPath: path.path) {
            try FileManager.default.removeItem(at: path)
            PrivacyLog.localModel(.deleted, model: PrivacyToken(modelId))
        }
    }

    /// List all downloaded model IDs by scanning the cache directory.
    func downloadedModelIds() -> [String] { Self.downloadedModelIdsOnDisk() }

    /// Filesystem-only view of the same list — usable before the service exists.
    nonisolated static func downloadedModelIdsOnDisk() -> [String] {
        // swift-huggingface stores as: <cacheDir>/models--{org}--{modelName}
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: modelCacheDirectory, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }

        var ids: [String] = []
        for entry in entries {
            let name = entry.lastPathComponent
            guard name.hasPrefix("models--") else { continue }
            // models--{org}--{modelName} → {org}/{modelName}
            let repo = String(name.dropFirst("models--".count))
            let id = repo.replacingOccurrences(of: "--", with: "/")
            ids.append(id)
        }
        return ids.sorted()
    }

    // MARK: - Helpers

    private func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }
}

// MARK: - Types

enum LocalLLMError: LocalizedError {
    case modelNotLoaded
    case generationFailed(String)
    case backgrounded
    case insufficientMemory(neededBytes: Int64, availableBytes: Int64)
    /// Not enough process allocation left to prefill a photo on the loaded model. Distinct from
    /// `insufficientMemory`, which is about *loading*: here the model is loaded and working, and
    /// only the image turn is out of reach.
    case insufficientMemoryForPhoto
    case promptTooLong(tokens: Int, limit: Int)
    case alreadyGenerating
    case alreadyDownloading

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "No local model is loaded. Download one in Settings → AI Models."
        case .generationFailed(let reason):
            return "Local model generation failed: \(reason)"
        case .backgrounded:
            return "On-device models can't run while the app is in the background. Switch to a cloud model for background tasks."
        case .insufficientMemory(let needed, let available):
            let gb = { (bytes: Int64) in String(format: "%.1f", Double(bytes) / 1_073_741_824) }
            return "Not enough memory to load the on-device model — it needs about \(gb(needed)) GB but only \(gb(available)) GB is available. Free up about \(gb(needed - available)) GB by closing other apps, or switch to a cloud model."
        case .insufficientMemoryForPhoto:
            return "There isn't enough memory to look at a photo with the on-device model right now. Ask me without the picture, or switch to a cloud model."
        case .promptTooLong(let tokens, let limit):
            return "Prompt is too long for the on-device model (\(tokens) tokens; limit \(limit)). Switch to a cloud model for this request."
        case .alreadyGenerating:
            return "The on-device model is already generating a response. Wait for it to finish."
        case .alreadyDownloading:
            return "A model download is already in progress. Cancel it first, or wait for it to finish."
        }
    }
}

struct RecommendedModel: Identifiable {
    let id: String
    let name: String
    let estimatedSize: String
    let hasVision: Bool
    let hasToolCalling: Bool
    let notes: String
    /// Minimum device RAM (GB) required to load this model. 0 = no restriction.
    let minimumRAMGB: Double

    init(id: String, name: String, estimatedSize: String, hasVision: Bool,
         hasToolCalling: Bool, notes: String, minimumRAMGB: Double = 0) {
        self.id = id
        self.name = name
        self.estimatedSize = estimatedSize
        self.hasVision = hasVision
        self.hasToolCalling = hasToolCalling
        self.notes = notes
        self.minimumRAMGB = minimumRAMGB
    }

    /// Whether the current device has enough RAM to run this model. Compared against the
    /// *marketing* RAM size, not raw `physicalMemory`: a 12 GB device reports ~11.5 GB
    /// (carve-outs), so a raw `>= 12` check blocked exactly the hardware it was meant to
    /// allow.
    var isCompatibleWithDevice: Bool {
        guard minimumRAMGB > 0 else { return true }
        return LocalLLMService.marketingRAMGB >= minimumRAMGB
    }
}

extension LocalLLMService {
    /// Physical RAM of this device in GB, as reported (always a little under the marketing
    /// number).
    nonisolated static var deviceRAMGB: Double {
        Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
    }

    /// The device's nominal RAM size: reported physical memory rounded UP to the next whole
    /// GB. Physical always underreports marketing by under a gigabyte, so the ceiling
    /// recovers the number on the box (11.5 → 12, 7.4 → 8) without ever inflating a smaller
    /// device into a larger tier.
    nonisolated static var marketingRAMGB: Double {
        deviceRAMGB.rounded(.up)
    }
}

/// A lock-guarded one-way boolean, settable from any thread — the mid-generation backgrounding
/// signal for vision turns, whose token drain runs off the main actor inside `container.perform`.
final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock(); defer { lock.unlock() }
        value = true
    }
}

/// What a vision turn's token drain observed, collected off the main actor and applied to the turn
/// timeline once `container.perform` returns (Plan CU P1).
///
/// The drain runs inside a `@Sendable` closure, so it cannot touch `TurnRecorder` — which is
/// main-actor isolated — and must not hop there mid-generation either: a suspension between MLX
/// token pulls is exactly the kind of cost instrumentation is not allowed to add. So the two facts
/// worth keeping are parked behind a lock and read back on the other side.
final class LockedGenerationReport: @unchecked Sendable {
    private let lock = NSLock()
    private var first: Date?
    private var info: GenerateCompletionInfo?

    /// Stamp the first token. Later tokens are a lock and a nil check.
    func noteToken(at time: Date) {
        lock.lock(); defer { lock.unlock() }
        if first == nil { first = time }
    }

    func note(_ completion: GenerateCompletionInfo) {
        lock.lock(); defer { lock.unlock() }
        info = completion
    }

    var firstTokenAt: Date? {
        lock.lock(); defer { lock.unlock() }
        return first
    }

    var completion: GenerateCompletionInfo? {
        lock.lock(); defer { lock.unlock() }
        return info
    }
}

/// Gemma 4's turn format, rendered by hand.
///
/// The model's real chat template lives in `chat_template.jinja` (not `tokenizer_config.json`)
/// and swift-jinja's parser rejects some of what it uses. This is the fallback for that case,
/// and it is a faithful transcription of the template rather than a generic "chat transcript":
///
///  - `<|turn>` opens a turn and `<turn|>` closes it — `sot_token`/`eot_token` in the
///    checkpoint's `tokenizer_config.json`, distinct from its `eos_token` (`<eos>`).
///  - The system prompt is a **genuine system turn**, not merged into the first user turn. The
///    template emits `<|turn>system\n…<turn|>` whenever message 0 is a system/developer message.
///  - `assistant` is renamed to `model`, and every body is trimmed.
///  - The generation prompt is a bare `<|turn>model\n`.
///
/// No speaker labels ("User:", "Assistant:") appear anywhere — a small model reading a
/// labelled dialogue can flip roles and answer *as* the wearer.
enum Gemma4ChatPrompt {
    /// Start-of-turn marker (`sot_token`).
    static let startOfTurnToken = "<|turn>"
    /// End-of-turn marker (`eot_token`) — must also be declared as an extra EOS token, since
    /// the checkpoint's `eos_token` is the different `<eos>`.
    static let endOfTurnToken = "<turn|>"

    /// Whether a model id is a Gemma 4 checkpoint. Matched on the id (both hub casings of the
    /// E-series appear in the wild) rather than a fixed list, so a user-typed Gemma 4 id gets
    /// the same handling as a catalog one.
    static func matches(modelId: String?) -> Bool {
        guard let id = modelId?.lowercased() else { return false }
        return id.contains("gemma-4") || id.contains("gemma4")
    }

    /// Whether an error is the template failing to *parse*, as opposed to any other failure
    /// from `applyChatTemplate` / `processor.prepare`.
    ///
    /// Matched on the error's description because the Jinja error type is not part of this
    /// target's dependency surface; both observed shapes are covered — the wrapped
    /// `parser("…")` case and a bare `Unexpected token …` message.
    static func isTemplateParseFailure(_ error: Error) -> Bool {
        let text = String(describing: error)
        return text.contains("parser(") || text.contains("Unexpected token")
    }

    /// Render a turn in Gemma 4's format. `bosToken` is prepended when the tokenizer has one,
    /// because the caller encodes with `addSpecialTokens: false` (the template emits
    /// `bos_token` itself, and letting both add it would double it).
    static func render(
        system: String,
        history: [(role: String, content: String)],
        userMessage: String,
        bosToken: String?
    ) -> String {
        var out = bosToken ?? ""
        let sys = system.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sys.isEmpty {
            appendTurn(&out, role: "system", body: sys)
        }
        for turn in history {
            appendTurn(&out, role: turn.role == "assistant" ? "model" : turn.role, body: turn.content)
        }
        appendTurn(&out, role: "user", body: userMessage)
        out += "\(startOfTurnToken)model\n"
        return out
    }

    private static func appendTurn(_ out: inout String, role: String, body: String) {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        out += "\(startOfTurnToken)\(role)\n\(trimmed)\(endOfTurnToken)\n"
    }
}
