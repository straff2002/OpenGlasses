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
            return "GGUF models are turned off. Turn them on in Settings → AI Models, or pick a "
                + "different on-device model."
        case .installationIncomplete(let id):
            return "The installed files for \(id.rawValue) are incomplete. Download the model again."
        case .weightsMissing(let id):
            return "The model file for \(id.rawValue) is missing. Download the model again."
        case .unsupportedArchitecture:
            return "This model file doesn't say what architecture it is, so it can't be loaded."
        case .unsupportedChatTemplate:
            return "This model doesn't carry a usable chat template, so it can't be used for "
                + "conversation. It stays installed, but it can't be selected for chat."
        case .contextTooSmall(let tokens):
            return "There isn't enough memory to give this model a usable context window "
                + "(\(tokens) tokens). Close other apps, or switch to a cloud model."
        case .insufficientMemory(let needed, let available):
            let gb = { (bytes: Int64) in String(format: "%.1f", Double(bytes) / 1_073_741_824) }
            return "Not enough memory to load the on-device model — it needs about \(gb(needed)) GB "
                + "but only \(gb(available)) GB is available. Free up memory by closing other apps, "
                + "or switch to a cloud model."
        case .notLoaded:
            return "No local model is loaded. Download one in Settings → AI Models."
        case .alreadyGenerating:
            return "The on-device model is already generating a response. Wait for it to finish."
        case .promptTooLong(let prompt, let reserve, let context):
            return "This conversation is too long for the on-device model "
                + "(\(prompt) tokens plus \(reserve) for the reply; the limit is \(context)). Start "
                + "a new conversation, or switch to a cloud model."
        case .tokenizationFailed:
            return "The on-device model couldn't read that prompt."
        case .engine:
            return "The on-device model failed while generating. Try again, or switch to a cloud "
                + "model."
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
        let templateProfile: LlamaChatTemplateProfile
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
    }

    private var resources: Resources?
    private var activeGeneration: Task<Void, Never>?

    init(engine: any LlamaEngine = LlamaCppEngine(),
         directoryForInstallation: (@Sendable (InstalledLocalModel) -> URL)? = nil,
         fileManager: FileManager = .default,
         availableProcessBytes: @escaping @Sendable () -> Int64 = { MemoryHeadroom.availableBytes() },
         appFootprintBytes: @escaping @Sendable () -> Int64 = { MemoryHeadroom.appFootprintBytes() },
         thermalState: @escaping @Sendable () -> ProcessInfo.ThermalState
            = { ProcessInfo.processInfo.thermalState },
         monotonicNanoseconds: @escaping @Sendable () -> UInt64
            = { DispatchTime.now().uptimeNanoseconds },
         isRuntimeEnabled: @escaping @Sendable () -> Bool = { Config.ggufModelsEnabled }) {
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
            //    discovered to be broken on the wearer's first question.
            let templateResult = LlamaCppChatTemplate.validate(engine.chatTemplate(model, named: nil)) {
                try engine.applyChatTemplate($0, turns: $1, addAssistantHeader: $2)
            }
            let templateProfile: LlamaChatTemplateProfile
            switch templateResult {
            case .success(let profile):
                templateProfile = profile
            case .failure(let fault):
                throw LlamaBackendError.unsupportedChatTemplate(fault)
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
            resources = Resources(installation: installation,
                                  model: model,
                                  context: context,
                                  sampler: sampler,
                                  samplerOptions: samplerOptions,
                                  templateProfile: templateProfile,
                                  contextTokens: actualContext,
                                  batchTokens: actualBatch,
                                  vocabularyAddsBOS: engine.vocabularyAddsBOS(model),
                                  bosPiece: engine.beginningOfSequencePiece(model),
                                  loaded: loaded,
                                  headroomAfterLoadBytes: availableProcessBytes())

            PrivacyLog.localModel(.loaded,
                                  model: PrivacyToken(installation.id.rawValue),
                                  vision: false,
                                  tokens: actualContext,
                                  footprintMegabytes: megabytes(appFootprintBytes()),
                                  headroomMegabytes: megabytes(availableProcessBytes()),
                                  detail: PrivacyToken("gguf-\(plan.binding.rawValue)"),
                                  milliseconds: milliseconds(since: startedAt),
                                  state: thermalToken())
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
        tearDown(PartialLoad(model: resources.model,
                             context: resources.context,
                             sampler: resources.sampler))
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
        if let sampler = partial.sampler { engine.freeSampler(sampler) }
        if let context = partial.context { engine.freeContext(context) }
        if let model = partial.model { engine.freeModel(model) }
    }

    // MARK: - Generation

    nonisolated func generate(_ request: LocalGenerationRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let starter = Task { await self.startGeneration(request, continuation: continuation) }
            continuation.onTermination = { termination in
                // A consumer that walks away must stop the GPU too — otherwise a barge-in leaves
                // the model decoding to completion, burning battery on an answer nobody will read.
                guard case .cancelled = termination else { return }
                starter.cancel()
                Task { await self.cancelGeneration() }
            }
        }
    }

    /// The isolated half of a generation: everything that touches resident state, ending with the
    /// launch of the off-actor decode loop.
    private func startGeneration(_ request: LocalGenerationRequest,
                                 continuation: AsyncThrowingStream<String, Error>.Continuation) {
        guard let resources else {
            continuation.finish(throwing: LlamaBackendError.notLoaded)
            return
        }
        guard activeGeneration == nil else {
            continuation.finish(throwing: LlamaBackendError.alreadyGenerating)
            return
        }
        // 1. Text-only phase.
        guard request.images.isEmpty else {
            continuation.finish(throwing: LocalInferenceError.visionNotAvailable)
            return
        }

        let promptStartedAt = monotonicNanoseconds()
        let promptTokens: [LlamaToken]
        let reserveTokens: Int
        do {
            // 2. Seam messages become template turns, with the system-merge policy the template's
            //    own probe decided at load.
            let turns = LlamaCppChatTemplate.turns(
                from: request.messages,
                mergingSystemIntoFirstUser: resources.templateProfile.mergesSystemIntoFirstUser)

            // 3. Apply the template, then tokenize with the special-token handling the rendered
            //    text calls for, and work out the output reserve.
            let rendered = try engine.applyChatTemplate(resources.templateProfile.template,
                                                        turns: turns,
                                                        addAssistantHeader: true)
            let addSpecial = LlamaCppChatTemplate.shouldAddSpecialTokens(
                rendered: rendered,
                bosPiece: resources.bosPiece,
                vocabularyAddsBOS: resources.vocabularyAddsBOS)
            promptTokens = try engine.tokenize(resources.model,
                                               text: rendered,
                                               addSpecial: addSpecial,
                                               parseSpecial: true)
            let requested = request.maxOutputTokens > 0 ? request.maxOutputTokens
                                                        : Self.defaultOutputTokens
            reserveTokens = max(1, min(requested, resources.contextTokens - 1))
        } catch let error as LlamaEngineError {
            continuation.finish(throwing: LlamaBackendError.engine(error))
            return
        } catch {
            continuation.finish(throwing: LlamaBackendError.tokenizationFailed)
            return
        }

        guard !promptTokens.isEmpty else {
            continuation.finish(throwing: LlamaBackendError.tokenizationFailed)
            return
        }

        // 4. Refuse before decode, with counts and never the prompt.
        let admission = LlamaPromptAdmission(promptTokens: promptTokens.count,
                                             reserveTokens: reserveTokens,
                                             contextTokens: resources.contextTokens)
        guard admission.fits else {
            PrivacyLog.localModel(.generationFailed,
                                  model: PrivacyToken(resources.installation.id.rawValue),
                                  count: admission.overflowTokens,
                                  total: resources.contextTokens,
                                  tokens: admission.promptTokens,
                                  detail: PrivacyToken("gguf-over-context"))
            continuation.finish(throwing: LlamaBackendError.promptTooLong(
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
                continuation.finish(throwing: LlamaBackendError.engine(error))
                return
            } catch {
                continuation.finish(throwing: error)
                return
            }
        }

        PrivacyLog.localModel(.generationStarted,
                              model: PrivacyToken(resources.installation.id.rawValue),
                              tokens: admission.promptTokens,
                              detail: PrivacyToken("gguf"),
                              state: thermalToken())

        let plan = GenerationPlan(installationID: resources.installation.id,
                                  model: resources.model,
                                  context: resources.context,
                                  sampler: sampler,
                                  promptTokens: promptTokens,
                                  batchTokens: resources.batchTokens,
                                  contextTokens: resources.contextTokens,
                                  maxOutputTokens: reserveTokens,
                                  stopSequences: request.stopSequences,
                                  headroomAfterLoadBytes: resources.headroomAfterLoadBytes,
                                  promptStartedAt: promptStartedAt)

        // The assignment below happens before this method suspends or returns, so the loop's own
        // `finishGeneration()` — which needs this actor — cannot observe a nil slot and leave the
        // backend permanently "already generating".
        activeGeneration = Task { [weak self] in
            guard let self else { return }
            await self.runLoop(plan, sampling: request.sampling, preview: request.previewSink,
                               continuation: continuation)
            await self.finishGeneration()
        }
    }

    private func finishGeneration() {
        activeGeneration = nil
    }

    /// Everything the decode loop needs, captured so the loop can run off the actor.
    private struct GenerationPlan: Sendable {
        let installationID: LocalModelID
        let model: LlamaModelHandle
        let context: LlamaContextHandle
        let sampler: LlamaSamplerHandle
        let promptTokens: [LlamaToken]
        let batchTokens: Int
        let contextTokens: Int
        let maxOutputTokens: Int
        let stopSequences: [String]
        let headroomAfterLoadBytes: Int64
        let promptStartedAt: UInt64
    }

    /// Steps 5–10, off the actor so a cancel can reach it.
    private nonisolated func runLoop(_ plan: GenerationPlan,
                                     sampling: LocalSamplingConfiguration,
                                     preview: ((String) -> Void)?,
                                     continuation: AsyncThrowingStream<String, Error>.Continuation) async {
        // 5. Clear the KV cache for every request. Plan DZ's cache policy is full-history-per-call;
        //    the sampler's penalty history is reset with it, or the previous turn's tokens would
        //    keep penalising this one.
        engine.clearMemory(plan.context)
        engine.resetSampler(plan.sampler)

        var accumulator = LlamaUTF8Accumulator()
        var matcher = LlamaStopSequenceMatcher(stopSequences: plan.stopSequences)
        var position = 0
        var generated = 0
        var firstTokenAt: UInt64?

        func emit(_ text: String) -> Bool {
            guard !text.isEmpty else { return false }
            let (safe, stop) = matcher.consume(text)
            if !safe.isEmpty {
                preview?(safe)
                continuation.yield(safe)
            }
            return stop
        }

        do {
            // 6. Prompt decode, partitioned to the context's own batch size, with a cancellation
            //    check between chunks.
            var offset = 0
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
            PrivacyLog.localModel(.promptDecoded,
                                  model: PrivacyToken(plan.installationID.rawValue),
                                  count: (plan.promptTokens.count + plan.batchTokens - 1)
                                      / plan.batchTokens,
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
                if emit(accumulator.append(engine.tokenBytes(plan.model, token: token))) { break }

                guard position < plan.contextTokens else { break }
                try engine.decode(plan.context, tokens: [token], position: position,
                                  wantsLogitsForLast: true)
                position += 1
            }

            if !matcher.hasStopped {
                _ = emit(accumulator.flush())
                let tail = matcher.flush()
                if !tail.isEmpty {
                    preview?(tail)
                    continuation.yield(tail)
                }
            }
            // 10. Drain the accelerator before anyone can free what it is still reading.
            engine.synchronize(plan.context)
            recordCompletion(plan, generated: generated, firstTokenAt: firstTokenAt,
                             position: position)
            continuation.finish()
        } catch is CancellationError {
            engine.synchronize(plan.context)
            PrivacyLog.localModel(.generationFailed,
                                  model: PrivacyToken(plan.installationID.rawValue),
                                  count: generated,
                                  detail: PrivacyToken("gguf-cancelled"))
            continuation.finish(throwing: CancellationError())
        } catch let error as LlamaEngineError {
            engine.synchronize(plan.context)
            let mapped: Error = error == .cancelled ? CancellationError()
                                                    : LlamaBackendError.engine(error)
            PrivacyLog.localModel(.generationFailed,
                                  model: PrivacyToken(plan.installationID.rawValue),
                                  count: generated,
                                  detail: PrivacyToken("gguf"),
                                  error: SafeErrorSummary(mapped))
            continuation.finish(throwing: mapped)
        } catch {
            engine.synchronize(plan.context)
            continuation.finish(throwing: error)
        }
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
        PrivacyLog.localModel(.generationCompleted,
                              model: PrivacyToken(plan.installationID.rawValue),
                              count: generated,
                              total: plan.contextTokens,
                              tokens: plan.promptTokens.count,
                              footprintMegabytes: megabytes(appFootprintBytes()),
                              headroomMegabytes: megabytes(headroomNow - plan.headroomAfterLoadBytes),
                              detail: PrivacyToken("gguf"),
                              milliseconds: milliseconds(since: plan.promptStartedAt),
                              firstTokenMilliseconds: firstTokenAt.map {
                                  Int(($0 &- plan.promptStartedAt) / 1_000_000)
                              },
                              percent: usage,
                              state: thermalToken())
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
