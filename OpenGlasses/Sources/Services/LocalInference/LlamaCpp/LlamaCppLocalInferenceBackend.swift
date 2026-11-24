import Foundation

/// Typed faults from the GGUF runtime, in the same spirit as `LocalLLMError` for MLX: every case is
/// something the wearer or the caller can act on, and none of them carries prompt text.
enum LlamaBackendError: LocalizedError, Equatable {
    /// `Config.ggufModelsEnabled` is off. MLX is unaffected.
    case runtimeDisabled
    /// The manifest no longer describes what is on disk.
    case installationIncomplete(LocalModelID)
    /// The manifest names no weights file, or names one that is not there.
    case weightsMissing(LocalModelID)
    /// The file does not describe its own architecture, so nothing can be configured from it.
    case unsupportedArchitecture
    /// The embedded chat template cannot carry a conversation.
    case unsupportedChatTemplate(LlamaChatTemplateFault)
    /// Every ceiling together left a context too small to hold an exchange.
    case contextTooSmall(tokens: Int)
    case insufficientMemory(neededBytes: Int64, availableBytes: Int64)
    case notLoaded
    case alreadyGenerating
    /// Refused *before* decode. Counts only — never the prompt.
    case promptTooLong(promptTokens: Int, reserveTokens: Int, contextTokens: Int)
    case tokenizationFailed
    case engine(LlamaEngineError)

    var errorDescription: String? {
        switch self {
        case .runtimeDisabled:
            return String(localized: "GGUF models are turned off. In Settings → Assistant → AI Models, edit or add a Local (On-Device MLX) model and open Download & Manage Models to pick a different on-device model.")
        case .installationIncomplete(let id):
            return String(localized: "The installed files for \(id.rawValue) are incomplete. Download the model again.")
        case .weightsMissing(let id):
            return String(localized: "The model file for \(id.rawValue) is missing. Download the model again.")
        case .unsupportedArchitecture:
            return String(localized: "This model file doesn't say what architecture it is, so it can't be loaded.")
        case .unsupportedChatTemplate:
            return String(localized: "This model doesn't carry a usable chat template, so it can't be used for conversation. It stays installed, but it can't be selected for chat.")
        case .contextTooSmall(let tokens):
            return String(localized: "There isn't enough memory to give this model a usable context window (\(tokens) tokens). Close other apps, or switch to a cloud model.")
        case .insufficientMemory(let needed, let available):
            let gb = { (bytes: Int64) in String(format: "%.1f", Double(bytes) / 1_073_741_824) }
            return String(localized: "Not enough memory to load the on-device model — it needs about \(gb(needed)) GB but only \(gb(available)) GB is available. Free up memory by closing other apps, or switch to a cloud model.")
        case .notLoaded:
            return String(localized: "No local model is loaded. In Settings → Assistant → AI Models, edit or add a Local (On-Device MLX) model, then open Download & Manage Models.")
        case .alreadyGenerating:
            return String(localized: "The on-device model is already generating a response. Wait for it to finish.")
        case .promptTooLong(let prompt, let reserve, let context):
            return String(localized: "This conversation is too long for the on-device model (\(prompt) tokens plus \(reserve) for the reply; the limit is \(context)). Start a new conversation, or switch to a cloud model.")
        case .tokenizationFailed:
            return String(localized: "The on-device model couldn't read that prompt.")
        case .engine:
            return String(localized: "The on-device model failed while generating. Try again, or switch to a cloud model.")
        }
    }
}

/// The GGUF runtime behind the backend-neutral seam (Plan DZ P1/PR3).
///
/// ### Why an actor, and why the decode loop leaves it
/// The wrapper's own rule is "nothing here is thread-safe; the owning actor is the synchronization",
/// so model, context and sampler handles are actor state and every call that touches them is
/// serialized here. The one deliberate exception is the decode/sample loop: a generation runs for
/// tens of seconds, and if it held the actor for its whole duration, `cancelGeneration()` — which
/// is an actor method — could not run until the generation it is trying to stop had finished. So
/// the loop runs on its own task with a snapshot of the handles, and the actor holds only the task.
/// That is safe for exactly one reason, and it is a property of the wrapper rather than a hope:
/// cancellation is an atomic flag on the context (`og_llama_context_set_cancelled`), which is the
/// only call made concurrently with the loop. Nothing frees a handle until `cancelGeneration()` has
/// awaited the loop's completion and synchronized the accelerator.
///
/// ### What is not here
/// Downloading, catalog policy, conversation storage and the tool loop — all seam invariants from
/// PR1, unchanged. The coordinator, not this actor, decides who is resident.
actor LlamaCppLocalInferenceBackend: LocalInferenceBackend {

    let runtime: LocalModelRuntime = .llamaCpp

    /// Prompt tokens per decode call when the caller states no preference. The context reports its
    /// own batch size after creation and that is what the loop partitions against.
    static let defaultBatchTokens = 512
    /// Output allowance when the request names none.
    static let defaultOutputTokens = 512

    // MARK: - Injected environment

    private let engine: any LlamaEngine
    /// Where an installation's files live. Injected so the actor never needs a repository.
    private let directoryForInstallation: @Sendable (InstalledLocalModel) -> URL
    private let fileManager: FileManager
    private let availableProcessBytes: @Sendable () -> Int64
    private let appFootprintBytes: @Sendable () -> Int64
    private let thermalState: @Sendable () -> ProcessInfo.ThermalState
    private let monotonicNanoseconds: @Sendable () -> UInt64
    /// Whether GGUF is switched on. Injected so a test does not mutate a global default.
    private let isRuntimeEnabled: @Sendable () -> Bool
    /// Where the diagnostics card's numbers go. It is a *second sink on the existing measurement*,
    /// not a second measurement: the two call sites below hand it the same values they hand
    /// `PrivacyLog`, so the card and the log can never disagree about a run.
    private let recordDiagnostics: @Sendable (LocalRuntimeDiagnosticsSample) -> Void

    // MARK: - Resident state

    /// Everything a loaded model owns. Created model → context → sampler; destroyed in reverse.
    private struct Resources {
        let installation: InstalledLocalModel
        let model: LlamaModelHandle
        let context: LlamaContextHandle
        /// Rebuilt when a request asks for sampling the resident chain was not built for — a
        /// sampler chain is small, and rebuilding it is the only way `LocalGenerationRequest`'s
        /// seed and temperature can reach the runtime.
        var sampler: LlamaSamplerHandle
        var samplerOptions: LlamaSamplerOptions
        /// The fixed-list template path (`llama_chat_apply_template`), or nil when only llama.cpp's
        /// Jinja engine can render this model's template (Gemma 4's), Plan MQ P2.
        let templateProfile: LlamaChatTemplateProfile?
        /// The model's templates in `common/chat` (Plan MQ P2): what renders a tool turn in the
        /// family's own format and parses its calls. Nil when it cannot read them; a tool turn then
        /// takes the Hermes instruction over the fixed-list path, as MLX does with no format.
        let chatTemplates: LlamaChatTemplatesHandle?
        let contextTokens: Int
        let batchTokens: Int
        let vocabularyAddsBOS: Bool
        let bosPiece: String?
        let loaded: LocalLoadedModel
        /// Headroom at the moment the load finished, so a generation can report the delta.
        let headroomAfterLoadBytes: Int64
    }

    /// Handles created so far during a load. The failure path frees exactly what exists, in reverse.
    private struct PartialLoad {
        var model: LlamaModelHandle?
        var context: LlamaContextHandle?
        var sampler: LlamaSamplerHandle?
        var chatTemplates: LlamaChatTemplatesHandle?
    }

    private var resources: Resources?
    private var activeGeneration: Task<Void, Never>?
    /// The tokens the KV cache holds after the last generation, in order (Plan MQ H3): its prompt
    /// and every generated token it decoded. Empty after a cancel, an error or an unload, when
    /// nothing is known about the cache, so the next prompt is read from the start.
    private var cachedTokens: [LlamaToken] = []
    /// The `common/chat` format last logged, so it is logged once per model.
    private var chatFormatLogged: String?

    init(engine: any LlamaEngine = LlamaCppEngine(),
         directoryForInstallation: (@Sendable (InstalledLocalModel) -> URL)? = nil,
         fileManager: FileManager = .default,
         availableProcessBytes: @escaping @Sendable () -> Int64 = { MemoryHeadroom.availableBytes() },
         appFootprintBytes: @escaping @Sendable () -> Int64 = { MemoryHeadroom.appFootprintBytes() },
         thermalState: @escaping @Sendable () -> ProcessInfo.ThermalState
            = { ProcessInfo.processInfo.thermalState },
         monotonicNanoseconds: @escaping @Sendable () -> UInt64
            = { DispatchTime.now().uptimeNanoseconds },
         isRuntimeEnabled: @escaping @Sendable () -> Bool = { Config.ggufModelsEnabled },
         recordDiagnostics: @escaping @Sendable (LocalRuntimeDiagnosticsSample) -> Void
            = { LocalRuntimeDiagnostics.shared.record($0) }) {
        self.engine = engine
        self.directoryForInstallation = directoryForInstallation ?? { installation in
            LocalModelRepository.defaultDirectory(for: installation)
        }
        self.fileManager = fileManager
        self.availableProcessBytes = availableProcessBytes
        self.appFootprintBytes = appFootprintBytes
        self.thermalState = thermalState
        self.monotonicNanoseconds = monotonicNanoseconds
        self.isRuntimeEnabled = isRuntimeEnabled
        self.recordDiagnostics = recordDiagnostics
    }

    var loadedModel: LocalLoadedModel? { resources?.loaded }

    // MARK: - Load

    /// Plan DZ's seven-step load flow, in order.
    func load(_ installation: InstalledLocalModel,
              configuration: LocalLoadConfiguration) async throws -> LocalLoadedModel {
        guard isRuntimeEnabled() else { throw LlamaBackendError.runtimeDisabled }
        guard installation.runtime == .llamaCpp else {
            throw LocalInferenceError.noBackend(installation.runtime)
        }
        // Idempotent for the resident model: tearing down a working model to rebuild it identically
        // is a multi-gigabyte round trip for no change.
        if let resources, resources.installation.id == installation.id {
            return resources.loaded
        }
        // A *different* model resident here means the caller bypassed the coordinator, which
        // normally evicts first. Releasing it before allocating the next one is the same invariant
        // either way — two multi-gigabyte allocations must never be resident together.
        if resources != nil { await unload() }

        // 1. Resolve a completed installation and validate the manifest again. "Again" is the
        //    point: the repository validated it when it was written, and files can disappear.
        let weightsURL = try resolveWeights(installation)

        // 2. Residency is the coordinator's (it is what called us). What is left of step 2 is the
        //    memory-admission policy, run against live headroom rather than install-time numbers.
        let available = availableProcessBytes()
        let admission = LocalModelBudget.admit(.init(
            runtime: .llamaCpp,
            declaredWeightsBytes: installation.descriptor.estimatedWeightsBytes,
            configuredContextTokens: configuration.contextLength,
            policyContextTokens: installation.descriptor.contextLength,
            availableProcessBytes: available,
            safetyReserveBytes: installation.descriptor.minimumHeadroomBytes))
        if case .refuse(let refusal) = admission {
            switch refusal {
            case .insufficientHeadroom(let needed, let availableBytes):
                throw LlamaBackendError.insufficientMemory(neededBytes: needed,
                                                           availableBytes: availableBytes)
            }
        }

        let startedAt = monotonicNanoseconds()
        var partial = PartialLoad()
        do {
            // 3. Load the file and read what it says about itself. No filename is parsed anywhere
            //    on this path.
            let model = try engine.loadModel(atPath: weightsURL.path, options: LlamaModelOptions())
            partial.model = model

            let metadataResult = GGUFMetadataValidator.metadata { key in
                engine.metadataValue(model, key: key)
            }
            guard case .success(let metadata) = metadataResult else {
                throw LlamaBackendError.unsupportedArchitecture
            }

            // 4. The embedded template is authoritative, so it is proved usable here rather than
            //    discovered to be broken on the wearer's first question. Plan MQ P2: llama.cpp's
            //    `common/chat` reads it too, for tool turns; and a template the fixed list does not
            //    know (Gemma 4's) still loads when `common/chat` renders a conversation with it.
            let templateResult = LlamaCppChatTemplate.validate(engine.chatTemplate(model, named: nil)) {
                try engine.applyChatTemplate($0, turns: $1, addAssistantHeader: $2)
            }
            let chatTemplates = try? engine.chatTemplates(model)
            partial.chatTemplates = chatTemplates
            if chatTemplates != nil, !LlamaCppEngine.catchesStandardExceptions {
                // A template that needs `common/chat`'s automatic parser will not render in this
                // image (see `LlamaCppEngine.catchesStandardExceptions`); its tool turns fall back.
                PrivacyLog.localModel(.toolFormat, model: PrivacyToken(installation.id.rawValue),
                                      detail: PrivacyToken("gguf-exceptions-unreliable"))
            }
            let templateProfile: LlamaChatTemplateProfile?
            switch templateResult {
            case .success(let profile):
                templateProfile = profile
            case .failure(let fault):
                guard let chatTemplates, Self.chatRendersAConversation(engine, chatTemplates) else {
                    throw LlamaBackendError.unsupportedChatTemplate(fault)
                }
                templateProfile = nil
            }

            // 5. Clamp to the smallest known ceiling.
            let memoryBudgetTokens = GGUFMetadataValidator.affordableContextTokens(
                bytes: contextBudgetBytes(available: available, installation: installation),
                metadata: metadata)
            let plan = GGUFMetadataValidator.contextPlan(
                requested: configuration.contextLength,
                modelCapability: engine.trainingContextTokens(model),
                descriptorPolicy: installation.descriptor.contextLength,
                memoryBudgetTokens: memoryBudgetTokens)
            guard plan.isViable else {
                throw LlamaBackendError.contextTooSmall(tokens: plan.contextTokens)
            }

            // 6. Context, then sampler. Nothing is published until both exist.
            let requestedBatch = configuration.batchSize > 0 ? configuration.batchSize
                                                             : Self.defaultBatchTokens
            let context = try engine.createContext(model, options: LlamaContextOptions(
                contextTokens: plan.contextTokens,
                batchTokens: min(requestedBatch, plan.contextTokens)))
            partial.context = context

            let samplerOptions = LlamaSamplerOptions(.conservative)
            let sampler = try engine.createSampler(model, options: samplerOptions)
            partial.sampler = sampler

            // The context is the authority on its own sizes: it may round a request down.
            let actualContext = max(1, engine.contextTokens(context))
            let actualBatch = max(1, engine.batchTokens(context))

            var capabilities: Set<LocalModelCapability> = [.text]
            // Text-only phase: vision is never advertised, whatever the descriptor claims.
            if installation.descriptor.supportsTools { capabilities.insert(.toolFriendly) }

            let loaded = LocalLoadedModel(id: installation.id,
                                          runtime: .llamaCpp,
                                          contextLength: actualContext,
                                          capabilities: capabilities)
            cachedTokens = []
            chatFormatLogged = nil
            resources = Resources(installation: installation,
                                  model: model,
                                  context: context,
                                  sampler: sampler,
                                  samplerOptions: samplerOptions,
                                  templateProfile: templateProfile,
                                  chatTemplates: chatTemplates,
                                  contextTokens: actualContext,
                                  batchTokens: actualBatch,
                                  vocabularyAddsBOS: engine.vocabularyAddsBOS(model),
                                  bosPiece: engine.beginningOfSequencePiece(model),
                                  loaded: loaded,
                                  headroomAfterLoadBytes: availableProcessBytes())

            let loadMilliseconds = milliseconds(since: startedAt)
            PrivacyLog.localModel(.loaded,
                                  model: PrivacyToken(installation.id.rawValue),
                                  vision: false,
                                  tokens: actualContext,
                                  footprintMegabytes: megabytes(appFootprintBytes()),
                                  headroomMegabytes: megabytes(availableProcessBytes()),
                                  detail: PrivacyToken("gguf-\(plan.binding.rawValue)"),
                                  milliseconds: loadMilliseconds,
                                  state: thermalToken())
            // Same numbers, second sink: the card can say what the context came out at before the
            // wearer has asked the model anything.
            recordDiagnostics(LocalRuntimeDiagnosticsSample(
                kind: .load,
                modelID: installation.id,
                runtime: .llamaCpp,
                modelRevision: installation.descriptor.revision,
                contextTokens: actualContext,
                promptTokens: 0,
                generatedTokens: 0,
                firstTokenMilliseconds: nil,
                totalMilliseconds: loadMilliseconds,
                headroomDeltaBytes: 0,
                footprintBytes: appFootprintBytes(),
                thermalState: .init(thermalState()),
                recordedAt: Date()))
            return loaded
        } catch {
            // 7. Reverse-order teardown of whatever was created, then a typed error. A raw engine
            //    status is wrapped rather than propagated: callers act on this backend's
            //    vocabulary, and `OGLlamaStatus` is an implementation detail of the wrapper.
            tearDown(partial)
            let typed = (error as? LlamaEngineError).map(LlamaBackendError.engine) ?? error
            PrivacyLog.localModel(.loadFailed,
                                  model: PrivacyToken(installation.id.rawValue),
                                  detail: PrivacyToken("gguf"),
                                  milliseconds: milliseconds(since: startedAt),
                                  error: SafeErrorSummary(typed))
            throw typed
        }
    }

    func unload() async {
        await cancelGeneration()
        guard let resources else { return }
        self.resources = nil
        cachedTokens = []
        chatFormatLogged = nil
        tearDown(PartialLoad(model: resources.model,
                             context: resources.context,
                             sampler: resources.sampler,
                             chatTemplates: resources.chatTemplates))
        PrivacyLog.localModel(.unloaded,
                              model: PrivacyToken(resources.installation.id.rawValue),
                              headroomMegabytes: megabytes(availableProcessBytes()),
                              detail: PrivacyToken("gguf"))
    }

    /// Free what exists, in the reverse of creation order, with the accelerator drained first.
    ///
    /// The order is not cosmetic: the sampler holds vocabulary-sized buffers derived from the
    /// model, the context holds graph state that points into it, and Metal work outlives the call
    /// that queued it. Freeing a model out from under either is a GPU-side use-after-free.
    private func tearDown(_ partial: PartialLoad) {
        if let context = partial.context { engine.synchronize(context) }
        if let templates = partial.chatTemplates { engine.freeChatTemplates(templates) }
        if let sampler = partial.sampler { engine.freeSampler(sampler) }
        if let context = partial.context { engine.freeContext(context) }
        if let model = partial.model { engine.freeModel(model) }
    }

    // MARK: - Generation

    /// Where one generation's output goes: text as the stream's elements, and — for
    /// `generateEvents` — the tool calls, the tool fit and the runtime's report beside it.
    private struct Output: Sendable {
        let text: @Sendable (String) -> Void
        let event: @Sendable (LocalGenerationEvent) -> Void
        let finish: @Sendable (Error?) -> Void
    }

    nonisolated func generate(_ request: LocalGenerationRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let output = Output(text: { continuation.yield($0) },
                                event: { _ in },
                                finish: { error in
                                    if let error { continuation.finish(throwing: error) } else { continuation.finish() }
                                })
            let starter = Task { await self.startGeneration(request, output: output) }
            continuation.onTermination = { termination in
                // A consumer that walks away must stop the GPU too — otherwise a barge-in leaves the
                // model decoding to completion, burning battery on an answer nobody will read.
                guard case .cancelled = termination else { return }
                starter.cancel()
                Task { await self.cancelGeneration() }
            }
        }
    }

    /// The same generation with the family's tool calls parsed out of it (Plan MQ P2): on a tool
    /// turn the text is the reply without its calls, then each call, as MLX's library yields them.
    nonisolated func generateEvents(_ request: LocalGenerationRequest) -> AsyncThrowingStream<LocalGenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            let output = Output(text: { continuation.yield(.text($0)) },
                                event: { continuation.yield($0) },
                                finish: { error in
                                    if let error { continuation.finish(throwing: error) } else { continuation.finish() }
                                })
            let starter = Task { await self.startGeneration(request, output: output) }
            continuation.onTermination = { termination in
                guard case .cancelled = termination else { return }
                starter.cancel()
                Task { await self.cancelGeneration() }
            }
        }
    }

    /// A prompt ready to decode, and how its completion is read.
    private struct PreparedPrompt {
        let tokens: [LlamaToken]
        /// The tool turn's render (Plan MQ P2): its completion is parsed by `common/chat` and its
        /// lazy grammar goes on the sampler. Nil on the fixed-list path.
        let chat: PreparedChat?
        /// What the runtime sent of a tool turn's tools; nil on a turn with none.
        let fit: LocalToolFit.Report?
    }

    private struct PreparedChat {
        /// The request that was rendered: the family's parser is built from it (llama.cpp v1.0.0).
        let requestJSON: String
        let renderJSON: String
        let render: LlamaToolChat.Render
        /// Control tokens the family's parser reads as text: its call markers.
        let preserved: Set<LlamaToken>
    }

    /// Thrown inside preparation; mapped to the backend's typed error at the boundary.
    private struct PromptOverflow: Error {
        let promptTokens: Int
    }

    /// The isolated half of a generation: everything that touches resident state, ending with the
    /// launch of the off-actor decode loop.
    private func startGeneration(_ request: LocalGenerationRequest, output: Output) {
        guard let resources else {
            output.finish(LlamaBackendError.notLoaded)
            return
        }
        guard activeGeneration == nil else {
            output.finish(LlamaBackendError.alreadyGenerating)
            return
        }
        // 1. Text-only phase.
        guard request.images.isEmpty else {
            output.finish(LocalInferenceError.visionNotAvailable)
            return
        }

        let promptStartedAt = monotonicNanoseconds()
        let requested = request.maxOutputTokens > 0 ? request.maxOutputTokens : Self.defaultOutputTokens
        let reserveTokens = max(1, min(requested, resources.contextTokens - 1))
        let budget = max(1, resources.contextTokens - reserveTokens)

        // 2–3. The prompt: rendered by `common/chat` for a tool turn (and for every turn of a model
        //      only it can render), by the fixed-list template otherwise; tokenized with the
        //      special-token handling the rendered text calls for; fitted to the context in
        //      batches so its start stays put (Plan MQ H3).
        let prepared: PreparedPrompt
        do {
            prepared = try preparePrompt(request, resources: resources, budget: budget)
        } catch let overflow as PromptOverflow {
            // 4. Refuse before decode, with counts and never the prompt.
            let admission = LlamaPromptAdmission(promptTokens: overflow.promptTokens,
                                                 reserveTokens: reserveTokens,
                                                 contextTokens: resources.contextTokens)
            PrivacyLog.localModel(.generationFailed,
                                  model: PrivacyToken(resources.installation.id.rawValue),
                                  count: admission.overflowTokens,
                                  total: resources.contextTokens,
                                  tokens: admission.promptTokens,
                                  detail: PrivacyToken("gguf-over-context"))
            output.finish(LlamaBackendError.promptTooLong(promptTokens: admission.promptTokens,
                                                          reserveTokens: admission.reserveTokens,
                                                          contextTokens: admission.contextTokens))
            return
        } catch let error as LlamaEngineError {
            output.finish(LlamaBackendError.engine(error))
            return
        } catch {
            output.finish(LlamaBackendError.tokenizationFailed)
            return
        }

        guard !prepared.tokens.isEmpty else {
            output.finish(LlamaBackendError.tokenizationFailed)
            return
        }

        // 4. Refuse before decode, with counts and never the prompt.
        let admission = LlamaPromptAdmission(promptTokens: prepared.tokens.count,
                                             reserveTokens: reserveTokens,
                                             contextTokens: resources.contextTokens)
        guard admission.fits else {
            PrivacyLog.localModel(.generationFailed,
                                  model: PrivacyToken(resources.installation.id.rawValue),
                                  count: admission.overflowTokens,
                                  total: resources.contextTokens,
                                  tokens: admission.promptTokens,
                                  detail: PrivacyToken("gguf-over-context"))
            output.finish(LlamaBackendError.promptTooLong(
                promptTokens: admission.promptTokens,
                reserveTokens: admission.reserveTokens,
                contextTokens: admission.contextTokens))
            return
        }

        // Per-request sampling. The MLX adapter ignores `request.sampling` because MLX derives its
        // own; this runtime has no such existing policy, so the request's temperature and seed are
        // authoritative — and a pinned seed is what makes a generation reproducible in a test.
        // The replacement is built before the old chain is freed: a failed create must not leave a
        // resident model pointing at a freed sampler.
        let desiredSampling = LlamaSamplerOptions(request.sampling)
        var sampler = resources.sampler
        if desiredSampling != resources.samplerOptions {
            do {
                let replacement = try engine.createSampler(resources.model, options: desiredSampling)
                engine.freeSampler(resources.sampler)
                sampler = replacement
                self.resources?.sampler = replacement
                self.resources?.samplerOptions = desiredSampling
            } catch let error as LlamaEngineError {
                output.finish(LlamaBackendError.engine(error))
                return
            } catch {
                output.finish(error)
                return
            }
        }

        // Plan MQ P2: the family's lazy call grammar for this turn, or none. A grammar that cannot
        // be built leaves the turn unconstrained — its parser still reads the call — rather than
        // failing a turn the model may well answer in words.
        var parser: LlamaChatParserHandle?
        if let chat = prepared.chat {
            if chat.render.constrainsCalls, (prepared.fit?.kept ?? 0) > 0 {
                do {
                    try engine.setChatGrammar(sampler, model: resources.model, renderJSON: chat.renderJSON)
                } catch {
                    engine.clearGrammar(sampler)
                    PrivacyLog.localModel(.toolFormat, model: PrivacyToken(resources.installation.id.rawValue),
                                          detail: PrivacyToken("gguf-grammar-unavailable"))
                }
            } else {
                engine.clearGrammar(sampler)
            }
            if let templates = resources.chatTemplates {
                parser = try? engine.createChatParser(templates, requestJSON: chat.requestJSON)
            }
            noteChatFormat(chat.render.formatName, model: resources.installation.id)
        } else {
            engine.clearGrammar(sampler)
        }

        PrivacyLog.localModel(.generationStarted,
                              model: PrivacyToken(resources.installation.id.rawValue),
                              tokens: admission.promptTokens,
                              detail: PrivacyToken(prepared.chat == nil ? "gguf" : "gguf-chat"),
                              state: thermalToken())

        let plan = GenerationPlan(installationID: resources.installation.id,
                                  modelRevision: resources.installation.descriptor.revision,
                                  model: resources.model,
                                  context: resources.context,
                                  sampler: sampler,
                                  promptTokens: prepared.tokens,
                                  cachedTokens: cachedTokens,
                                  batchTokens: resources.batchTokens,
                                  contextTokens: resources.contextTokens,
                                  maxOutputTokens: reserveTokens,
                                  stopSequences: request.stopSequences
                                      + (prepared.chat?.render.additionalStops ?? []),
                                  chat: prepared.chat.map { ChatPlan(parser: parser, preserved: $0.preserved) },
                                  fit: prepared.fit,
                                  headroomAfterLoadBytes: resources.headroomAfterLoadBytes,
                                  promptStartedAt: promptStartedAt)
        // What the cache holds is unknown until this generation reports back.
        cachedTokens = []

        // The assignment below happens before this method suspends or returns, so the loop's own
        // `finishGeneration()` — which needs this actor — cannot observe a nil slot and leave the
        // backend permanently "already generating".
        activeGeneration = Task { [weak self] in
            guard let self else { return }
            let cached = await self.runLoop(plan, preview: request.previewSink, output: output)
            await self.finishGeneration(cached: cached)
        }
    }

    private func finishGeneration(cached: [LlamaToken]) {
        activeGeneration = nil
        cachedTokens = cached
    }

    /// Log the family `common/chat` recognised, as a token, once per model (Plan MQ P2).
    private func noteChatFormat(_ format: String, model: LocalModelID) {
        guard chatFormatLogged != format else { return }
        chatFormatLogged = format
        PrivacyLog.localModel(.toolFormat, model: PrivacyToken(model.rawValue),
                              detail: PrivacyToken("gguf-\(format)"))
    }

    // MARK: - Prompt

    /// The prompt for one request. Three routes:
    ///  - a tool turn, through `common/chat` (Plan MQ P2): the family's own rendering of the
    ///    system prompt, the earlier turns, this turn's calls and results and the tools, fitted by
    ///    `LocalToolFit` exactly as MLX fits them, the history then trimmed in batches;
    ///  - an ordinary turn on a model only `common/chat` can render (Gemma 4's template), the same
    ///    way with no tools;
    ///  - otherwise the fixed-list template, as Plan DZ shipped it, now trimmed in batches too. A
    ///    tool turn reaches this route only when `common/chat` could not read the model's
    ///    templates: its tools then go as the Hermes instruction, as MLX does with no format.
    private func preparePrompt(_ request: LocalGenerationRequest, resources: Resources,
                               budget: Int) throws -> PreparedPrompt {
        let system = Self.systemText(request.messages)
        if let templates = resources.chatTemplates {
            if let toolTurn = request.toolTurn {
                do {
                    return try prepareChat(templates: templates, system: system, history: toolTurn.history,
                                           turn: toolTurn.turn, toolTurn: toolTurn, resources: resources,
                                           budget: budget)
                } catch let overflow as PromptOverflow {
                    throw overflow
                } catch where resources.templateProfile != nil {
                    // The template would not render this turn with its tools: the Hermes
                    // instruction over the fixed-list path, rather than no answer.
                    PrivacyLog.localModel(.toolFormat, model: PrivacyToken(resources.installation.id.rawValue),
                                          detail: PrivacyToken("gguf-render-failed"))
                }
            }
            if resources.templateProfile == nil {
                let messages = Self.loopMessages(request.messages)
                return try prepareChat(templates: templates, system: system,
                                       history: Array(messages.dropLast()), turn: Array(messages.suffix(1)),
                                       toolTurn: nil, resources: resources, budget: budget)
            }
        }
        guard let profile = resources.templateProfile else { throw LlamaEngineError.noChatTemplate }

        var messages = request.messages
        var fit: LocalToolFit.Report?
        if let toolTurn = request.toolTurn {
            // No `common/chat` for this model: the transcript in `messages` is already flattened by
            // the caller, and the tools go as text.
            if !toolTurn.tools.isEmpty, let first = messages.firstIndex(where: { $0.role == .system }) {
                messages[first] = .system(messages[first].content + toolTurn.fallbackInstructions)
            }
            fit = LocalToolFit.fit(toolTurn, rendersTools: false, budget: budget,
                                   window: resources.contextTokens) { _, _ in 0 }.report
        }
        let leadingSystem = messages.prefix { $0.role == .system }
        let rest = Array(messages.dropFirst(leadingSystem.count))
        let current = Array(rest.suffix(1))
        let history = Array(rest.dropLast())
        func tokens(_ kept: [LocalChatMessage]) throws -> [LlamaToken] {
            let turns = LlamaCppChatTemplate.turns(
                from: Array(leadingSystem) + kept + current,
                mergingSystemIntoFirstUser: profile.mergesSystemIntoFirstUser)
            let rendered = try engine.applyChatTemplate(profile.template, turns: turns, addAssistantHeader: true)
            let addSpecial = LlamaCppChatTemplate.shouldAddSpecialTokens(
                rendered: rendered, bosPiece: resources.bosPiece, vocabularyAddsBOS: resources.vocabularyAddsBOS)
            return try engine.tokenize(resources.model, text: rendered, addSpecial: addSpecial, parseSpecial: true)
        }
        guard let kept = try LocalModelBudget.historyFittingBudgetInBatches(
            history: history, budget: budget, startsExchange: { $0.role == .user },
            tokenCount: { try tokens($0).count }) else {
            throw PromptOverflow(promptTokens: try tokens([]).count)
        }
        if kept.count < history.count {
            PrivacyLog.localModel(.historyTrimmed, count: kept.count, total: history.count, tokens: budget)
        }
        return PreparedPrompt(tokens: try tokens(kept), chat: nil, fit: fit)
    }

    private func prepareChat(templates: LlamaChatTemplatesHandle, system: String,
                             history: [LocalToolLoop.Message], turn: [LocalToolLoop.Message],
                             toolTurn: LocalToolTurn?, resources: Resources,
                             budget: Int) throws -> PreparedPrompt {
        func rendered(_ messages: [LocalToolLoop.Message],
                      tools: [[String: Any]]) throws -> (request: String, json: String, render: LlamaToolChat.Render,
                                                        tokens: [LlamaToken]) {
            let request = LlamaToolChat.requestJSON(
                system: system, messages: messages, tools: tools, thinkingOff: toolTurn?.thinkingOff ?? true)
            let json = try engine.renderChat(templates, requestJSON: request)
            let render = try LlamaToolChat.render(json)
            let addSpecial = LlamaCppChatTemplate.shouldAddSpecialTokens(
                rendered: render.prompt, bosPiece: resources.bosPiece, vocabularyAddsBOS: resources.vocabularyAddsBOS)
            let tokens = try engine.tokenize(resources.model, text: render.prompt,
                                             addSpecial: addSpecial, parseSpecial: true)
            return (request, json, render, tokens)
        }

        // The definitions first, measured with no history (`LocalToolFit`, as MLX).
        var keptSpecs: [[String: Any]] = []
        var fit: LocalToolFit.Report?
        if let toolTurn {
            let fitted = try LocalToolFit.fit(toolTurn, rendersTools: true, budget: budget,
                                              window: resources.contextTokens) { kept, detail in
                try rendered(turn, tools: toolTurn.specs(kept: kept, detail: detail)).tokens.count
            }
            keptSpecs = fitted.turn.tools
            fit = fitted.report
        }

        // Then the history, into the room they leave, a batch at a time (Plan MQ H3).
        guard let kept = try LocalModelBudget.historyFittingBudgetInBatches(
            history: history, budget: budget, startsExchange: { $0.role == .user },
            tokenCount: { try rendered($0 + turn, tools: keptSpecs).tokens.count }) else {
            throw PromptOverflow(promptTokens: try rendered(turn, tools: []).tokens.count)
        }
        if kept.count < history.count {
            PrivacyLog.localModel(.historyTrimmed, count: kept.count, total: history.count, tokens: budget)
        }

        let final = try rendered(kept + turn, tools: keptSpecs)
        var preserved = Set<LlamaToken>()
        for piece in final.render.preservedTokens {
            let ids = (try? engine.tokenize(resources.model, text: piece, addSpecial: false, parseSpecial: true)) ?? []
            if ids.count == 1 { preserved.insert(ids[0]) }
        }
        return PreparedPrompt(tokens: final.tokens,
                              chat: PreparedChat(requestJSON: final.request, renderJSON: final.json,
                                                 render: final.render, preserved: preserved),
                              fit: fit)
    }

    /// The leading system messages' text, joined as a template would join them.
    static func systemText(_ messages: [LocalChatMessage]) -> String {
        messages.prefix { $0.role == .system }
            .map(\.content)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
    }

    /// An ordinary turn's messages after the system prompt, as the loop's messages.
    static func loopMessages(_ messages: [LocalChatMessage]) -> [LocalToolLoop.Message] {
        messages.drop { $0.role == .system }.compactMap { message in
            switch message.role {
            case .user: return .user(message.content)
            case .assistant: return .assistant(message.content)
            case .system: return nil
            }
        }
    }

    /// A conversation rendered through `common/chat` keeps its user turn: the load-time proof for a
    /// template only `common/chat` can read.
    static func chatRendersAConversation(_ engine: any LlamaEngine, _ templates: LlamaChatTemplatesHandle) -> Bool {
        let probe = "OGPROBE-USER-7D2A"
        guard let json = try? engine.renderChat(templates, requestJSON: LlamaToolChat.requestJSON(
                  system: "OGPROBE-SYSTEM-7D2A", messages: [.user(probe)], tools: [], thinkingOff: true)),
              let render = try? LlamaToolChat.render(json) else { return false }
        return render.prompt.contains(probe)
    }

    // MARK: - Decode loop

    /// A tool turn's reading of its completion (Plan MQ P2).
    private struct ChatPlan: Sendable {
        /// Nil when the render's parser could not be built: the text is then returned unparsed, and
        /// the app's output policy reads it as it reads any other.
        let parser: LlamaChatParserHandle?
        let preserved: Set<LlamaToken>
    }

    /// Everything the decode loop needs, captured so the loop can run off the actor.
    private struct GenerationPlan: Sendable {
        let installationID: LocalModelID
        /// Carried rather than looked up: the completion record runs off the actor, and reaching
        /// back for the installation there would be a hop for a value that cannot change mid-turn.
        let modelRevision: String
        let model: LlamaModelHandle
        let context: LlamaContextHandle
        let sampler: LlamaSamplerHandle
        let promptTokens: [LlamaToken]
        /// What the KV cache held when this generation was planned (Plan MQ H3).
        let cachedTokens: [LlamaToken]
        let batchTokens: Int
        let contextTokens: Int
        let maxOutputTokens: Int
        let stopSequences: [String]
        let chat: ChatPlan?
        let fit: LocalToolFit.Report?
        let headroomAfterLoadBytes: Int64
        let promptStartedAt: UInt64
    }

    /// Steps 5–10, off the actor so a cancel can reach it. Returns the tokens the KV cache holds
    /// afterwards, or none when the generation did not finish (the cache is then unknown).
    private nonisolated func runLoop(_ plan: GenerationPlan,
                                     preview: ((String) -> Void)?,
                                     output: Output) async -> [LlamaToken] {
        defer { if let parser = plan.chat?.parser { engine.freeChatParser(parser) } }
        // 5. Keep the KV cache's shared prefix and drop the rest (Plan MQ H3): a turn that starts as
        //    the last one did prefills only from where they differ. The sampler's penalty history
        //    is reset either way, or the previous turn's tokens would keep penalising this one.
        let keep = LlamaPromptCache.reusablePrefix(cached: plan.cachedTokens, prompt: plan.promptTokens)
        let kept = min(max(0, engine.keepPrefix(plan.context, tokens: keep)), keep)
        engine.resetSampler(plan.sampler)

        var accumulator = LlamaUTF8Accumulator()
        var matcher = LlamaStopSequenceMatcher(stopSequences: plan.stopSequences)
        var position = kept
        var generated = 0
        var firstTokenAt: UInt64?
        var decoded = plan.promptTokens
        // A tool turn's raw completion, call markers included, for `common/chat`'s parser.
        var raw = ""
        var previewShown = ""

        func emit(_ text: String) -> Bool {
            guard !text.isEmpty else { return false }
            let (safe, stop) = matcher.consume(text)
            if !safe.isEmpty {
                if let chat = plan.chat {
                    raw += safe
                    // The reply so far, without the call it may be starting, for the preview only.
                    if let preview, let parser = chat.parser,
                       let json = try? engine.parseChat(parser, text: raw, partial: true),
                       let parsed = try? LlamaToolChat.parsed(json) {
                        let delta = LlamaToolChat.previewDelta(shown: previewShown, current: parsed.content)
                        if !delta.isEmpty {
                            previewShown += delta
                            preview(delta)
                        }
                    }
                } else {
                    preview?(safe)
                    output.text(safe)
                }
            }
            return stop
        }

        do {
            // 6. Prompt decode from the first token the cache does not hold, partitioned to the
            //    context's own batch size, with a cancellation check between chunks.
            var offset = kept
            while offset < plan.promptTokens.count {
                if Task.isCancelled { throw CancellationError() }
                let end = min(offset + plan.batchTokens, plan.promptTokens.count)
                let chunk = Array(plan.promptTokens[offset..<end])
                try engine.decode(plan.context,
                                  tokens: chunk,
                                  position: position,
                                  wantsLogitsForLast: end == plan.promptTokens.count)
                position += chunk.count
                offset = end
            }
            let promptDecodedAt = monotonicNanoseconds()
            let decodedPromptTokens = plan.promptTokens.count - kept
            PrivacyLog.localModel(.promptDecoded,
                                  model: PrivacyToken(plan.installationID.rawValue),
                                  count: (decodedPromptTokens + plan.batchTokens - 1) / plan.batchTokens,
                                  total: kept,
                                  tokens: plan.promptTokens.count,
                                  detail: PrivacyToken("gguf"),
                                  milliseconds: Int((promptDecodedAt &- plan.promptStartedAt)
                                                    / 1_000_000))

            // 7. One token at a time, stopping on end-of-generation, a stop sequence, cancellation,
            //    the output cap, or a full context.
            while generated < plan.maxOutputTokens {
                if Task.isCancelled { throw CancellationError() }
                let token = try engine.sample(plan.sampler, context: plan.context)
                if engine.isEndOfGeneration(plan.model, token: token) { break }

                generated += 1
                if firstTokenAt == nil { firstTokenAt = monotonicNanoseconds() }

                // 8. Bytes, not characters: the accumulator holds a split sequence until it is whole.
                //    A tool turn renders the family's call markers, which its parser reads.
                let special = plan.chat?.preserved.contains(token) ?? false
                if emit(accumulator.append(engine.tokenBytes(plan.model, token: token,
                                                             renderSpecial: special))) { break }

                guard position < plan.contextTokens else { break }
                try engine.decode(plan.context, tokens: [token], position: position,
                                  wantsLogitsForLast: true)
                decoded.append(token)
                position += 1
            }

            if !matcher.hasStopped {
                _ = emit(accumulator.flush())
                let tail = matcher.flush()
                if !tail.isEmpty {
                    if plan.chat != nil {
                        raw += tail
                    } else {
                        preview?(tail)
                        output.text(tail)
                    }
                }
            }
            // 10. Drain the accelerator before anyone can free what it is still reading.
            engine.synchronize(plan.context)
            let finishedAt = monotonicNanoseconds()

            // What the runtime sent of a tool turn's tools, for the dispatcher — on the Hermes
            // fallback too, where every offered tool went as text.
            if let fit = plan.fit { output.event(.toolFit(fit)) }
            if let chat = plan.chat {
                // Plan MQ P2: the reply and its calls, read by the family's own parser. A completion
                // that is not the family's format is never a call: its text goes back as it came,
                // for the output policy to read.
                var content = raw
                var calls: [LocalToolCallEvent] = []
                if let parser = chat.parser {
                    if let json = try? engine.parseChat(parser, text: raw, partial: false),
                       let parsed = try? LlamaToolChat.parsed(json) {
                        content = parsed.content
                        calls = parsed.calls
                        if parsed.malformedCalls > 0 || !calls.isEmpty {
                            PrivacyLog.localModel(.toolCall, model: PrivacyToken(plan.installationID.rawValue),
                                                  count: calls.count, total: calls.count + parsed.malformedCalls,
                                                  detail: PrivacyToken("gguf-parsed"))
                        }
                    } else {
                        PrivacyLog.localModel(.toolCall, model: PrivacyToken(plan.installationID.rawValue),
                                              count: 0, detail: PrivacyToken("gguf-unparsed"))
                    }
                }
                if !content.isEmpty { output.text(content) }
                for call in calls { output.event(.toolCall(call)) }
            }
            output.event(.stats(Self.stats(plan, generated: generated, firstTokenAt: firstTokenAt,
                                           finishedAt: finishedAt)))
            recordCompletion(plan, generated: generated, firstTokenAt: firstTokenAt,
                             position: position)
            output.finish(nil)
            return decoded
        } catch is CancellationError {
            engine.synchronize(plan.context)
            PrivacyLog.localModel(.generationFailed,
                                  model: PrivacyToken(plan.installationID.rawValue),
                                  count: generated,
                                  detail: PrivacyToken("gguf-cancelled"))
            output.finish(CancellationError())
            return []
        } catch let error as LlamaEngineError {
            engine.synchronize(plan.context)
            let mapped: Error = error == .cancelled ? CancellationError()
                                                    : LlamaBackendError.engine(error)
            PrivacyLog.localModel(.generationFailed,
                                  model: PrivacyToken(plan.installationID.rawValue),
                                  count: generated,
                                  detail: PrivacyToken("gguf"),
                                  error: SafeErrorSummary(mapped))
            output.finish(mapped)
            return []
        } catch {
            engine.synchronize(plan.context)
            output.finish(error)
            return []
        }
    }

    /// The runtime's report for the qualification record (Plan MQ P3): time to first token as the
    /// prompt time (render, tokenize and the prefill the cache did not save), and the decode after it.
    private static func stats(_ plan: GenerationPlan, generated: Int, firstTokenAt: UInt64?,
                              finishedAt: UInt64) -> LocalGenerationStats {
        let first = firstTokenAt ?? finishedAt
        return LocalGenerationStats(promptTokens: plan.promptTokens.count,
                                    generatedTokens: generated,
                                    promptSeconds: Double(first &- plan.promptStartedAt) / 1_000_000_000,
                                    generateSeconds: Double(finishedAt &- first) / 1_000_000_000,
                                    tokenCap: plan.maxOutputTokens,
                                    stoppedAtCap: generated >= plan.maxOutputTokens)
    }

    /// 9. Load and decode timings, token counts, context usage, headroom delta and thermal state —
    /// counts and enums only. Tokens per second is deliberately not a field: it is `count` over
    /// `duration`, and a derived number is one more thing that can disagree with its inputs.
    private nonisolated func recordCompletion(_ plan: GenerationPlan,
                                              generated: Int,
                                              firstTokenAt: UInt64?,
                                              position: Int) {
        let headroomNow = availableProcessBytes()
        let usage = plan.contextTokens > 0 ? (position * 100) / plan.contextTokens : 0
        let totalMilliseconds = milliseconds(since: plan.promptStartedAt)
        let firstTokenMilliseconds = firstTokenAt.map {
            Int(($0 &- plan.promptStartedAt) / 1_000_000)
        }
        PrivacyLog.localModel(.generationCompleted,
                              model: PrivacyToken(plan.installationID.rawValue),
                              count: generated,
                              total: plan.contextTokens,
                              tokens: plan.promptTokens.count,
                              footprintMegabytes: megabytes(appFootprintBytes()),
                              headroomMegabytes: megabytes(headroomNow - plan.headroomAfterLoadBytes),
                              detail: PrivacyToken("gguf"),
                              milliseconds: totalMilliseconds,
                              firstTokenMilliseconds: firstTokenMilliseconds,
                              percent: usage,
                              state: thermalToken())
        // The diagnostics card reads exactly what the line above recorded — same counts, same
        // clock, same headroom reading — so there is one measurement with two readers.
        recordDiagnostics(LocalRuntimeDiagnosticsSample(
            kind: .generation,
            modelID: plan.installationID,
            runtime: .llamaCpp,
            modelRevision: plan.modelRevision,
            contextTokens: plan.contextTokens,
            promptTokens: plan.promptTokens.count,
            generatedTokens: generated,
            firstTokenMilliseconds: firstTokenMilliseconds,
            totalMilliseconds: totalMilliseconds,
            headroomDeltaBytes: headroomNow - plan.headroomAfterLoadBytes,
            footprintBytes: appFootprintBytes(),
            thermalState: .init(thermalState()),
            recordedAt: Date()))
    }

    // MARK: - Cancellation

    /// Stop the in-flight generation and wait until it has actually stopped — the coordinator
    /// unloads immediately after this returns.
    func cancelGeneration() async {
        guard let task = activeGeneration else { return }
        activeGeneration = nil
        if let resources { engine.setCancelled(resources.context, true) }
        task.cancel()
        // Awaiting the task suspends this actor, which is what lets the loop's own
        // `finishGeneration()` hop back in. The alternative — spinning — would deadlock.
        await task.value
        if let resources {
            // 10. The flag stops new work; synchronize is what makes the *outstanding* work safe
            //     to free. Clearing the flag afterwards leaves the context usable for the next turn.
            engine.synchronize(resources.context)
            engine.setCancelled(resources.context, false)
        }
    }

    // MARK: - Installation

    /// Re-validate the manifest and return the weights file's URL.
    ///
    /// The digest is *not* recomputed here: rehashing several gigabytes on every load would add
    /// seconds to a cold start for a check the installer already made against the same bytes. What
    /// is checked is what can change after installation — presence, containment, and size.
    private func resolveWeights(_ installation: InstalledLocalModel) throws -> URL {
        let files = installation.validatedFiles.isEmpty ? installation.descriptor.files
                                                        : installation.validatedFiles
        // Sorted so a sharded model resolves to its first shard deterministically; the engine
        // follows the split from there.
        let weights = files.filter { $0.role == .weights }
            .sorted { $0.relativePath < $1.relativePath }
        guard let first = weights.first else {
            throw LlamaBackendError.weightsMissing(installation.id)
        }
        let root = directoryForInstallation(installation)
        guard let url = LocalModelPath.resolve(first.relativePath, under: root) else {
            throw LlamaBackendError.installationIncomplete(installation.id)
        }
        guard fileManager.fileExists(atPath: url.path) else {
            throw LlamaBackendError.weightsMissing(installation.id)
        }
        if first.byteCount > 0 {
            let attributes = try? fileManager.attributesOfItem(atPath: url.path)
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            guard size == first.byteCount else {
                throw LlamaBackendError.installationIncomplete(installation.id)
            }
        }
        return url
    }

    /// Bytes the KV cache may claim: what the process can still allocate, less the weights it is
    /// about to resident and the runtime's own working set. `0` when there is no budget to speak of
    /// (simulator, Mac), which leaves the context unclamped by memory — the same "unknown is not
    /// zero" rule `MemoryHeadroom` already applies.
    private func contextBudgetBytes(available: Int64, installation: InstalledLocalModel) -> Int64 {
        guard available > 0 else { return 0 }
        let committed = installation.descriptor.estimatedWeightsBytes
            + LocalModelBudget.workingSetBytes(for: .llamaCpp)
            + max(0, installation.descriptor.minimumHeadroomBytes)
        return max(0, available - committed)
    }

    // MARK: - Diagnostics helpers

    private nonisolated func megabytes(_ bytes: Int64) -> Int { Int(bytes / (1024 * 1024)) }

    private nonisolated func milliseconds(since start: UInt64) -> Int {
        Int((monotonicNanoseconds() &- start) / 1_000_000)
    }

    private nonisolated func thermalToken() -> PrivacyToken {
        switch thermalState() {
        case .nominal: return PrivacyToken("nominal")
        case .fair: return PrivacyToken("fair")
        case .serious: return PrivacyToken("serious")
        case .critical: return PrivacyToken("critical")
        @unknown default: return PrivacyToken("unknown")
        }
    }
}
