import Foundation

/// The slice of `LocalLLMService` the MLX backend actually needs.
///
/// Extracted as a protocol for one reason: it lets the adapter — and every test of it — run with no
/// MLX, no Metal and no `Wearables`. `LocalLLMService` conforms with no changes to its own code.
@MainActor
protocol MLXLocalRuntime: AnyObject {
    var isModelLoaded: Bool { get }
    var loadedModelId: String? { get }
    /// Whether the model that actually loaded went through the VLM factory. Not the id's nominal
    /// capability — a demoted checkpoint is text-only however it is catalogued.
    var loadedViaVLMFactory: Bool { get }

    func loadModel(_ modelId: String) async throws
    func unloadModel()
    func generate(userMessage: String,
                  systemPrompt: String,
                  history: [(role: String, content: String)],
                  imageData: Data?,
                  onToken: ((String) -> Void)?) async throws -> String
}

extension LocalLLMService: MLXLocalRuntime {}

// MARK: - Prompt assembly

/// One prior turn in the shape the MLX path has always used.
struct MLXHistoryTurn: Equatable, Sendable {
    let role: String
    let content: String

    init(role: String, content: String) {
        self.role = role
        self.content = content
    }

    init(_ tuple: (role: String, content: String)) {
        self.init(role: tuple.role, content: tuple.content)
    }

    var tuple: (role: String, content: String) { (role: role, content: content) }
}

/// Converts between the seam's message list and the three arguments `LocalLLMService.generate` has
/// always taken.
///
/// This type is the whole risk surface of putting MLX behind the seam, so it is pure and separately
/// tested: if `decompose(compose(x)) == x` for every shape the caller produces, then routing a
/// generation through the coordinator hands the MLX runtime *byte-for-byte the arguments it would
/// have received directly*, and no prompt can drift.
enum MLXPromptAdapter {

    /// Why a message list cannot be expressed as MLX's (system, history, user) triple.
    enum Fault: Error, Equatable {
        /// The list does not end with the current user turn.
        case missingUserTurn
        /// A system turn appeared somewhere other than the front. MLX's history has no system role,
        /// so there is nowhere truthful to put it — better to refuse than to silently demote it to
        /// a user turn the model would answer.
        case systemTurnOutOfPosition(index: Int)
    }

    struct Decomposed: Equatable {
        let systemPrompt: String
        let history: [MLXHistoryTurn]
        let userMessage: String
    }

    /// Build the seam's message list from what `sendLocal` already has in hand.
    static func compose(systemPrompt: String,
                        history: [(role: String, content: String)],
                        userMessage: String) -> [LocalChatMessage] {
        var messages: [LocalChatMessage] = [.system(systemPrompt)]
        for turn in history {
            messages.append(turn.role == "assistant" ? .assistant(turn.content) : .user(turn.content))
        }
        messages.append(.user(userMessage))
        return messages
    }

    /// Recover MLX's three arguments from the seam's message list. Exact inverse of `compose` for
    /// every list `compose` can produce.
    static func decompose(_ messages: [LocalChatMessage]) throws -> Decomposed {
        guard let last = messages.last, last.role == .user else { throw Fault.missingUserTurn }

        var systemPrompt = ""
        var index = 0
        // Leading system turns only. `compose` emits exactly one; more than one is joined the way
        // a chat template would, so a future caller that splits its prompt is not silently truncated.
        while index < messages.count, messages[index].role == .system {
            systemPrompt += systemPrompt.isEmpty ? messages[index].content
                                                 : "\n\n" + messages[index].content
            index += 1
        }

        var history: [MLXHistoryTurn] = []
        let middle = messages[index..<(messages.count - 1)]
        for (offset, message) in middle.enumerated() {
            switch message.role {
            case .system:
                throw Fault.systemTurnOutOfPosition(index: index + offset)
            case .user:
                history.append(MLXHistoryTurn(role: "user", content: message.content))
            case .assistant:
                history.append(MLXHistoryTurn(role: "assistant", content: message.content))
            }
        }
        return Decomposed(systemPrompt: systemPrompt, history: history, userMessage: last.content)
    }
}

// MARK: - Backend

/// `LocalLLMService` behind the backend-neutral seam.
///
/// **This is an adapter, not a rewrite.** It translates shapes and owns the cancellation handle;
/// every decision that affects what the model sees or produces — chat template, history budgeting,
/// token shape by factory, sampling parameters, generation reserve, `<think>` handling, the
/// backgrounding guard, the VLM→text demotion — stays exactly where it already is, inside
/// `LocalLLMService`. That is why `LocalGenerationRequest`'s `maxOutputTokens`, `sampling` and
/// `stopSequences` are deliberately **ignored here**: the MLX path derives all three from
/// `LocalModelBudget` and `LocalLLMService.generateParameters(for:)`, and honouring them at this
/// layer would change shipped behaviour under the guise of adding a seam. A runtime that has no
/// such existing policy (the GGUF backend) uses them.
///
/// Not an actor: `LocalLLMService` is `@MainActor`, so every call has to hop there anyway, and the
/// only state this type owns is the cancellation handle — a lock is honest about that and keeps
/// `generate` synchronous, as the protocol requires.
final class MLXLocalInferenceBackend: LocalInferenceBackend, @unchecked Sendable {

    let runtime: LocalModelRuntime = .mlx

    private let service: any MLXLocalRuntime

    private let lock = NSLock()
    private var resident: LocalLoadedModel?
    private var activeGeneration: Task<Void, Never>?

    init(service: any MLXLocalRuntime) {
        self.service = service
    }

    var loadedModel: LocalLoadedModel? {
        lock.lock(); defer { lock.unlock() }
        return resident
    }

    // MARK: Load / unload

    func load(_ installation: InstalledLocalModel,
              configuration: LocalLoadConfiguration) async throws -> LocalLoadedModel {
        guard installation.runtime == .mlx else {
            throw LocalInferenceError.noBackend(installation.runtime)
        }
        let modelID = installation.id.rawValue
        // `LocalLLMService.loadModel` is already idempotent for the resident model, already runs
        // the backgrounding and memory-headroom gates, and already owns the demotion fallback.
        // Calling it unchanged is the point of this adapter.
        try await service.loadModel(modelID)

        let loadedViaVision = await MainActor.run { service.loadedViaVLMFactory }
        var capabilities: Set<LocalModelCapability> = [.text]
        // As loaded, not as catalogued: a demoted checkpoint must not advertise vision.
        if loadedViaVision { capabilities.insert(.vision) }
        if installation.descriptor.supportsTools { capabilities.insert(.toolFriendly) }

        let loaded = LocalLoadedModel(
            id: installation.id,
            runtime: .mlx,
            contextLength: configuration.contextLength,
            capabilities: capabilities)
        lock.lock(); resident = loaded; lock.unlock()
        return loaded
    }

    func unload() async {
        await cancelGeneration()
        await MainActor.run { service.unloadModel() }
        lock.lock(); resident = nil; lock.unlock()
    }

    // MARK: Generation

    func generate(_ request: LocalGenerationRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [service] in
                do {
                    let decomposed = try MLXPromptAdapter.decompose(request.messages)
                    let preview = request.previewSink
                    // One element: MLX produces its authoritative answer as a whole (the reasoning
                    // strip happens on the returned text, not on the token stream). Incremental
                    // text reaches the UI through `previewSink`, per the protocol's output contract.
                    let text = try await service.generate(
                        userMessage: decomposed.userMessage,
                        systemPrompt: decomposed.systemPrompt,
                        history: decomposed.history.map(\.tuple),
                        imageData: request.images.first?.data,
                        onToken: preview)
                    continuation.yield(text)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            lock.lock(); activeGeneration = task; lock.unlock()
            continuation.onTermination = { [weak self] termination in
                // A consumer that walks away (or is cancelled) must stop the GPU work too —
                // otherwise a barge-in leaves MLX decoding to completion, which is the exact
                // battery/thermal burn the drain loop's cancellation check exists to prevent.
                if case .cancelled = termination { self?.cancelActiveGeneration() }
            }
        }
    }

    func cancelGeneration() async {
        let task: Task<Void, Never>? = {
            lock.lock(); defer { lock.unlock() }
            let current = activeGeneration
            activeGeneration = nil
            return current
        }()
        task?.cancel()
        // Await the task's completion, not just its cancellation flag: the coordinator unloads
        // straight after this returns, and freeing weights under a live token loop is a crash.
        await task?.value
    }

    private func cancelActiveGeneration() {
        lock.lock()
        let task = activeGeneration
        activeGeneration = nil
        lock.unlock()
        task?.cancel()
    }
}
