import Foundation

// Plan KT §4.2 — the one route a card's draft is written through. Unlike
// `LLMService.completeStateless`, which runs the active provider's conversation path over an
// emptied-and-restored history (so a turn running beside it reads an empty history, and the
// request still goes through the conversation's prompt, recorder and usage paths), this route is
// the same for every provider and carries nothing but two strings: the instructions and the
// prompt `DraftPrompt` built. There is no field for tools, history, memory, persona, Brain or
// timeline text, so none can be added by accident; nothing is persisted, and neither the prompt
// nor the reply is logged.
//
// Model order (decision 5): Apple's on-device model, then the local MLX model (only when one is
// loaded and the app is in front), then the wearer's cloud model, and that only after a one-time
// consent naming what is sent, never under Medical Compliance (HIPAA mode, with or without Local
// Only), and never for a draft carrying caption text when the route is on the blocked list.

/// "Write drafts with" (§5.6).
enum DraftWriterChoice: String, CaseIterable, Sendable {
    /// Apple's on-device model or the loaded local model; otherwise the plain template.
    case onThisPhone
    /// The same, then the wearer's cloud model once they have agreed to it.
    case cloud
}

/// The wearer's cloud model, as the route policy sees it: no key, no address book, nothing to send.
struct DraftCloudTarget: Equatable, Sendable {
    let configId: String
    let provider: LLMProvider
    /// The name the consent and the draft's footer use: "Anthropic (Claude)".
    let providerName: String
    let model: String
    /// The host requests go to, so a changed endpoint needs a new consent.
    let host: String
    /// The credential is an account sign-in rather than a typed key.
    let usesAccountSignIn: Bool

    init(configId: String, provider: LLMProvider, providerName: String, model: String, host: String,
         usesAccountSignIn: Bool) {
        self.configId = configId
        self.provider = provider
        self.providerName = providerName
        self.model = model
        self.host = host.lowercased()
        self.usesAccountSignIn = usesAccountSignIn
    }

    /// The saved model as a cloud target, or nil for the on-device providers.
    init?(config: ModelConfig) {
        let provider = config.llmProvider
        guard provider != .local, provider != .appleOnDevice else { return nil }
        let signIn: Bool
        switch provider {
        case .anthropic: signIn = AnthropicAuth.usesAccountSignIn(apiKey: config.apiKey)
        case .xai: signIn = XAIAuth.usesAccountSignIn(apiKey: config.apiKey)
        case .chatgpt, .geminiVertex: signIn = true
        default: signIn = false
        }
        let base = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = URL(string: base.isEmpty ? provider.defaultBaseURL : base)?.host ?? provider.rawValue
        self.init(configId: config.id, provider: provider, providerName: config.providerDisplayName,
                  model: config.model, host: host, usesAccountSignIn: signIn)
    }

    /// What a consent is recorded against: this saved model, this provider, this host. A
    /// different model, or the same one pointed somewhere else, asks again.
    var consentKey: String { "\(configId)|\(provider.rawValue)|\(host)" }

    /// The routes a meeting follow-up's draft (caption text: other people's words) never goes to
    /// (decision 5). Two kinds:
    /// - **a Gemini AI Studio key.** Google may use what an unpaid key sends to improve its
    ///   products, and the app cannot tell a paid key from an unpaid one, so every AI Studio key
    ///   is treated as unpaid. (Vertex AI runs on the wearer's own billed project.)
    /// - **a subscription rather than an API account:** the ChatGPT, Claude and xAI sign-ins, and
    ///   the coding-plan subscriptions (Z.ai, Qwen, MiniMax), whose terms are a consumer plan's.
    var isBlockedForCaptionText: Bool {
        switch provider {
        case .gemini, .chatgpt, .zai, .qwen, .minimax: return true
        case .anthropic, .xai: return usesAccountSignIn
        default: return false
        }
    }

    /// Whether the isolated transport can reach this model at all: a typed key on the Anthropic
    /// Messages API, Gemini's `generateContent` or an OpenAI-compatible chat endpoint. A sign-in
    /// route needs the conversation path's token handling, which this route deliberately does not
    /// share, so it writes no drafts.
    var isSupported: Bool {
        switch provider {
        case .chatgpt, .geminiVertex, .local, .appleOnDevice: return false
        case .anthropic, .xai: return !usesAccountSignIn
        default: return true
        }
    }
}

/// Where one draft is written.
enum DraftRoute: Equatable, Sendable {
    case appleOnDevice
    case localModel
    case cloud(DraftCloudTarget)

    var origin: DraftOrigin {
        switch self {
        case .appleOnDevice, .localModel: return .onDevice
        case .cloud(let target): return .cloud(provider: target.providerName)
        }
    }

    var isOnDevice: Bool { if case .cloud = self { false } else { true } }
}

/// Why no model writes this draft. The card keeps its template ("Simple draft").
enum DraftNoRouteReason: String, CaseIterable, Error, Sendable {
    /// No on-device model is ready, and the wearer writes drafts on the phone only.
    case nothingOnDevice
    /// The wearer chose their cloud model but has not agreed to it for drafts.
    case cloudNotConsented
    /// The wearer's active model is on the device, or there is none.
    case noCloudModel
    /// The cloud model is reached through a sign-in this route does not use.
    case cloudUnsupported
    /// Medical Compliance is on: drafts stay on the phone.
    case medicalCompliance
    /// A meeting follow-up, and the cloud model is on the blocked list.
    case blockedForCaptionText
}

/// What the route decision reads. Pure data, so the order and every gate are value tests.
struct DraftRouteInputs: Equatable, Sendable {
    var appleOnDeviceAvailable: Bool
    var localModelLoaded: Bool
    var isForeground: Bool
    var choice: DraftWriterChoice
    var cloud: DraftCloudTarget?
    /// The consent key the wearer agreed to, if any (`DraftCloudTarget.consentKey`).
    var cloudConsent: String?
    /// Medical Compliance (HIPAA mode) is on — with or without Local Only.
    var hipaaMode: Bool
    /// Medical Compliance's Local Only is on.
    var medicalLocalOnly: Bool
    /// The draft carries caption text: a meeting follow-up.
    var carriesCaptionText: Bool
}

enum DraftRoutePolicy {

    static func decide(_ inputs: DraftRouteInputs) -> Result<DraftRoute, DraftNoRouteReason> {
        if inputs.appleOnDeviceAvailable { return .success(.appleOnDevice) }
        if inputs.localModelLoaded && inputs.isForeground { return .success(.localModel) }
        guard inputs.choice == .cloud else { return .failure(.nothingOnDevice) }
        if inputs.hipaaMode || inputs.medicalLocalOnly { return .failure(.medicalCompliance) }
        guard let target = inputs.cloud else { return .failure(.noCloudModel) }
        if inputs.carriesCaptionText && target.isBlockedForCaptionText { return .failure(.blockedForCaptionText) }
        guard target.isSupported else { return .failure(.cloudUnsupported) }
        guard inputs.cloudConsent == target.consentKey else { return .failure(.cloudNotConsented) }
        return .success(.cloud(target))
    }

    /// Whether `target` could ever be offered for drafts while `hipaaMode` is as it is: what the
    /// settings page offers as "Write drafts with {provider}".
    static func canOffer(_ target: DraftCloudTarget?, hipaaMode: Bool, medicalLocalOnly: Bool) -> Bool {
        guard let target, !hipaaMode, !medicalLocalOnly else { return false }
        return target.isSupported
    }
}

/// Everything that leaves for a model. Two strings and a cap; there is nothing else to fill.
struct DraftModelRequest: Equatable, Sendable {
    let route: DraftRoute
    let instructions: String
    let prompt: String
    let maxOutputTokens: Int
}

enum DraftCallFailure: Error, Equatable, Sendable {
    case noRoute(DraftNoRouteReason)
    /// The model failed, timed out or answered with nothing. No detail: it could carry text.
    case modelFailed
}

/// The seam in front of the models: what is available now, and one call. Tests replace it and
/// read the requests it was handed.
@MainActor
protocol DraftModelEngine: AnyObject {
    func routeInputs(carriesCaptionText: Bool) -> DraftRouteInputs
    func run(_ request: DraftModelRequest) async throws -> String
}

/// One draft, one call.
@MainActor
final class DraftModelCall {
    /// A draft is short; this is room for an email's worth with some to spare.
    static let maxOutputTokens = 400
    /// A call longer than this falls back to the template.
    static let timeout: TimeInterval = 25

    private let engine: any DraftModelEngine
    private let timeout: TimeInterval

    init(engine: any DraftModelEngine, timeout: TimeInterval = DraftModelCall.timeout) {
        self.engine = engine
        self.timeout = timeout
    }

    /// The route this draft would take now, without calling anything.
    func route(carriesCaptionText: Bool) -> Result<DraftRoute, DraftNoRouteReason> {
        DraftRoutePolicy.decide(engine.routeInputs(carriesCaptionText: carriesCaptionText))
    }

    func complete(instructions: String, prompt: String,
                  carriesCaptionText: Bool) async -> Result<(text: String, route: DraftRoute), DraftCallFailure> {
        let route: DraftRoute
        switch self.route(carriesCaptionText: carriesCaptionText) {
        case .failure(let reason): return .failure(.noRoute(reason))
        case .success(let chosen): route = chosen
        }
        let request = DraftModelRequest(route: route, instructions: instructions, prompt: prompt,
                                        maxOutputTokens: Self.maxOutputTokens)
        let engine = self.engine
        let limit = timeout
        let reply: String? = await withTaskGroup(of: String?.self) { group in
            group.addTask { @MainActor in try? await engine.run(request) }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let reply, !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.modelFailed)
        }
        return .success((reply, route))
    }
}
