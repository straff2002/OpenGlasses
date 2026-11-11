import Foundation

extension Notification.Name {
    /// A setting that decides where content goes was written: a model, a live model, a voice, a
    /// recogniser or the app mode. Key fields don't post it, because they save on every keystroke;
    /// `SecretInputField` asks for a review when the person leaves the field.
    static let cloudServicesChanged = Notification.Name("cloudServicesChanged")
}

/// One network origin the person has set up, and what it would be used for.
struct CloudService: Identifiable, Equatable {
    let name: String
    let url: URL
    let origin: String
    var scopes: [CloudProcessingScope]
    /// The scopes worth stopping the person for. A zero-setup route (keyless search, Gemini Live
    /// for someone who only uses the Gemini chat model) is listed, but waits for first use.
    var asked: Set<CloudProcessingScope>
    var id: String { origin }
}

/// The routes behind the list, before they are merged by origin.
struct CloudServiceRoute: Equatable {
    let name: String
    let url: String
    let scope: CloudProcessingScope
    var asked = true
}

enum CloudServiceCatalog {
    /// One entry per origin, in the order the routes first name it, so a key that serves chat and
    /// speech is one question rather than two. A route without a usable address is dropped.
    static func services(routes: [CloudServiceRoute]) -> [CloudService] {
        var merged: [CloudService] = []
        for route in routes {
            guard let url = URL(string: route.url.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let terms = try? CloudProcessingTerms(url: url, scope: route.scope) else { continue }
            if let index = merged.firstIndex(where: { $0.origin == terms.origin }) {
                if !merged[index].scopes.contains(route.scope) { merged[index].scopes.append(route.scope) }
                if route.asked { merged[index].asked.insert(route.scope) }
            } else {
                merged.append(CloudService(name: route.name, url: url, origin: terms.origin, scopes: [route.scope],
                                           asked: route.asked ? [route.scope] : []))
            }
        }
        return merged
    }

    /// What a saved model reaches, or nil for an on-device model and one with nothing to send
    /// with. `accountConnected` is the sign-in that stands in for a key on that provider.
    static func route(for model: ModelConfig, accountConnected: Bool, vertexURL: URL?) -> CloudServiceRoute? {
        let provider = model.llmProvider
        let hasKey = !model.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let address: String
        switch provider {
        case .local, .appleOnDevice:
            return nil
        case .geminiVertex:
            guard accountConnected, let vertexURL else { return nil }
            address = vertexURL.absoluteString
        case .chatgpt:
            guard accountConnected else { return nil }
            address = provider.defaultBaseURL
        case .custom:
            guard !model.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            address = model.baseURL
        default:
            guard hasKey || accountConnected else { return nil }
            address = model.baseURL.isEmpty ? provider.defaultBaseURL : model.baseURL
        }
        let name = provider == .custom ? ProcessingFacts.host(of: address) ?? model.providerDisplayName
                                       : model.providerDisplayName
        return CloudServiceRoute(name: name, url: address, scope: .conversation)
    }

    /// Plan KZ §10: a provider that runs web search itself sends the query to the same address as
    /// the conversation, but it is a new use of that address, so it is listed (and asked about)
    /// under Web search too — while the policy would attach the search to the model's requests.
    static func providerSearchRoute(for model: ModelConfig, decision: ProviderSearchPolicy.Decision,
                                    conversationRoute: CloudServiceRoute?) -> CloudServiceRoute? {
        guard decision.spec != nil, let conversationRoute else { return nil }
        return CloudServiceRoute(name: conversationRoute.name, url: conversationRoute.url, scope: .webSearch)
    }

    /// Where each voice sends the text it reads. The on-device ones send nothing.
    static func voiceRoute(for engine: TTSEngine) -> CloudServiceRoute? {
        switch engine {
        case .elevenLabs:
            return CloudServiceRoute(name: "ElevenLabs", url: "https://api.elevenlabs.io", scope: .speechOutput)
        case .openAI:
            return CloudServiceRoute(name: "OpenAI", url: CloudVoiceRequests.openAISpeechURL.absoluteString, scope: .speechOutput)
        case .xai:
            return CloudServiceRoute(name: "xAI", url: CloudVoiceRequests.xaiSpeechURL.absoluteString, scope: .speechOutput)
        case .gemini:
            return CloudServiceRoute(name: "Google", url: CloudVoiceRequests.geminiModelsURL.absoluteString, scope: .speechOutput)
        default:
            return nil
        }
    }

    static func dictationRoute(for provider: CloudDictationProvider) -> CloudServiceRoute {
        switch provider {
        case .deepgram:
            return CloudServiceRoute(name: provider.vendorName, url: DeepgramDictationRequest.endpoint, scope: .speechRecognition)
        case .openAI:
            return CloudServiceRoute(name: provider.vendorName, url: OpenAIDictationRequest.url.absoluteString, scope: .speechRecognition)
        }
    }
}

/// Reads the app's real settings into routes. It never holds a second copy: the voice and the
/// recogniser come from `ProcessingFactsProvider`, which already decides them for "Where Your
/// Requests Go".
///
/// Gateways, MCP servers and agent harnesses aren't here. Their addresses are built at connection
/// time, so they get the first-use question, and a request refused with nobody there queues them.
@MainActor
enum CloudServiceFactsProvider {
    static func current() -> [CloudService] {
        CloudServiceCatalog.services(routes: routes())
    }

    static func routes() -> [CloudServiceRoute] {
        guard !Config.hipaaLocalOnly else { return [] }
        let facts = ProcessingFactsProvider.current()
        var routes = Config.savedModels.compactMap(modelRoute)
        if let voice = CloudServiceCatalog.voiceRoute(for: facts.voiceEngine) { routes.append(voice) }
        if let dictation = facts.speechRecognitionCloudProvider {
            routes.append(CloudServiceCatalog.dictationRoute(for: dictation))
        }
        if facts.diarizationEnabled {
            routes.append(CloudServiceCatalog.dictationRoute(for: .deepgram))
        }
        routes += liveRoutes()
        routes += searchRoutes()
        return routes
    }

    static func modelRoute(_ model: ModelConfig) -> CloudServiceRoute? {
        let connected: Bool
        switch model.llmProvider {
        case .chatgpt: connected = ChatGPTOAuthService.shared.isConnected
        case .anthropic: connected = ClaudeOAuthService.shared.isConnected
        case .xai: connected = XAIOAuthService.shared.isConnected
        case .geminiVertex: connected = GoogleOAuthService.shared.isConnected
        default: connected = false
        }
        let vertex = model.llmProvider == .geminiVertex
            ? VertexAI.endpointURL(projectID: Config.vertexProjectID, region: Config.vertexRegion, model: model.model)
            : nil
        return CloudServiceCatalog.route(for: model, accountConnected: connected, vertexURL: vertex)
    }

    private static func liveRoutes() -> [CloudServiceRoute] {
        var routes = Config.savedRealtimeModels.map {
            CloudServiceRoute(name: $0.name, url: $0.endpoint, scope: .liveSession)
        }
        if Config.geminiLiveModelConfig != nil {
            routes.append(CloudServiceRoute(name: "Google", url: "https://generativelanguage.googleapis.com",
                                            scope: .liveSession, asked: Config.appMode == .geminiLive))
        }
        if Config.openAIRealtimeModelConfig != nil {
            routes.append(CloudServiceRoute(name: "OpenAI", url: RealtimeConnectionConfiguration.openAIEndpoint,
                                            scope: .liveSession, asked: Config.appMode == .openaiRealtime))
        }
        return routes
    }

    private static func searchRoutes() -> [CloudServiceRoute] {
        var routes: [CloudServiceRoute] = []
        // Plan KZ: the active model's provider, when it would run the search itself.
        if let model = Config.activeModel {
            let decision = ProviderSearchPolicy.decide(ProviderSearchLive.inputs(
                for: model, credential: model.apiKey, webSearchDeclared: true,
                learnedResponsesRejection: false))
            if let route = CloudServiceCatalog.providerSearchRoute(for: model, decision: decision,
                                                                    conversationRoute: modelRoute(model)) {
                routes.append(route)
            }
        }
        if Config.isPerplexityConfigured {
            routes.append(CloudServiceRoute(name: "Perplexity", url: "https://api.perplexity.ai", scope: .webSearch))
        }
        if Config.isTavilyConfigured {
            routes.append(CloudServiceRoute(name: "Tavily", url: "https://api.tavily.com", scope: .webSearch))
        }
        if Config.isBraveConfigured {
            routes.append(CloudServiceRoute(name: "Brave Search", url: "https://api.search.brave.com", scope: .webSearch))
        }
        if Config.isSearXNGConfigured {
            routes.append(CloudServiceRoute(name: "SearXNG", url: Config.searxngBaseURL, scope: .webSearch))
        }
        // The zero-setup fallbacks work without anyone choosing them, so they wait for first use.
        if !Config.isTavilyConfigured {
            routes.append(CloudServiceRoute(name: "Tavily", url: "https://api.tavily.com", scope: .webSearch, asked: false))
        }
        routes.append(CloudServiceRoute(name: "DuckDuckGo", url: "https://api.duckduckgo.com", scope: .webSearch, asked: false))
        return routes
    }
}

/// Asks about services at the moment they are set up, so that an answer given with the phone in
/// hand is already there when a request arrives from Siri, the Watch or a locked phone.
///
/// One rule covers saving a key, adding a model, an organisation's profile and the first launch
/// after this feature arrived: anything set up that has never been answered gets one question. So
/// there's no separate catch-up, and nothing to remember at each new place a service can be added.
@MainActor
final class CloudSharingReview {
    static let shared = CloudSharingReview()

    private let consent: CloudProcessingConsent
    private let services: () -> [CloudService]
    private let settled: () -> Bool
    private var running = false
    private var again = false
    private var scheduled = false
    private var forced: Set<String> = []
    private var observer: NSObjectProtocol?

    init(consent: CloudProcessingConsent? = nil,
         services: (() -> [CloudService])? = nil,
         settled: (() -> Bool)? = nil) {
        self.consent = consent ?? .shared
        self.services = services ?? { CloudServiceFactsProvider.current() }
        self.settled = settled ?? Self.isPastSetup
    }

    private static func isPastSetup() -> Bool {
        #if DEBUG
        // A seeded UI test has saved models and no one to answer; only the test of this asks.
        if UITestSupport.isActive, !UITestSupport.isSet(.cloudSharingReview) { return false }
        #endif
        return Config.isPastOnboarding
    }

    /// Follows settings changes for as long as the app can show a question.
    func startObserving() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: .cloudServicesChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule() }
        }
    }

    /// Several settings often change together; they should reach the person as one review.
    private func schedule() {
        guard !scheduled else { return }
        scheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            self?.scheduled = false
            self?.run()
        }
    }

    /// `asking` is a service the person has just picked: picking it again after Not now, or after
    /// withdrawing, is a fresh decision. `duringSetup` lets onboarding ask at its key step.
    func run(asking picked: URL? = nil, duringSetup: Bool = false) {
        if let picked, let origin = try? CloudProcessingTerms(url: picked, scope: .conversation).origin { forced.insert(origin) }
        guard duringSetup || settled() else { return }
        guard !running else { again = true; return }
        running = true
        Task { @MainActor in
            await review()
            running = false
        }
    }

    func run(pickedModelId id: String) {
        let route = Config.savedModels.first { $0.id == id }.flatMap(CloudServiceFactsProvider.modelRoute)
        run(asking: route.flatMap { URL(string: $0.url.trimmingCharacters(in: .whitespacesAndNewlines)) })
    }

    /// Finishes when nothing is left to ask, or when the person left and the rest can wait.
    func review() async {
        repeat {
            again = false
            let list = consent.withRefusedServices(services())
            for service in list {
                let scopes = consent.scopesToAsk(service, forced: forced.contains(service.origin))
                guard !scopes.isEmpty else { continue }
                guard await consent.ask(about: service, scopes: scopes) else { return }
                forced.remove(service.origin)
            }
        } while again
    }
}
