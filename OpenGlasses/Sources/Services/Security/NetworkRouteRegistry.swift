import Foundation

/// What a route can carry off the device. Coarse on purpose: the point is to make the privacy
/// manifest and the medical local-only rule checkable, not to describe payload shapes.
enum NetworkDataClass: String, CaseIterable, Sendable {
    /// Microphone or glasses audio, raw or encoded.
    case audio
    /// Speech-to-text output, conversation turns, notes — anything the wearer or a bystander said.
    case transcript
    /// Camera frames or stills.
    case frame
    /// Anything that could be protected health information: clinical notes, vitals, FHIR resources.
    case healthFact
    /// API keys, bearer tokens, OAuth codes.
    case credential
    /// Coarse or precise device location.
    case location
    /// Prompt text assembled by the app, including tool arguments the model produced.
    case promptText
    /// Names, phone numbers, addresses drawn from the address book.
    case contactData
    /// Model or asset bytes flowing *inbound*; the outbound half is an identifier only.
    case modelAsset
    /// Carries no user-derived content at all — a fixed catalog or health-check request.
    case telemetryFree
}

/// Where a route's endpoint lives. Drives which addresses `EndpointPolicy` will accept.
enum NetworkEndpointClass: String, CaseIterable, Sendable {
    /// A cloud service whose host the user configured (their API key, their account).
    case userConfiguredCloud
    /// A cloud service this app talks to by default at a host we ship.
    case firstPartyCloud
    /// A server on the wearer's own LAN — Home Assistant, an MCP server, a local LLM host.
    case localNetwork
    /// 127.0.0.1 / ::1 only.
    case loopback
    /// The open web, reached with a URL the model or the user supplied.
    case publicWeb
    /// An OpenClaw-style agent gateway.
    case gateway

    /// Only these two classes may address loopback or RFC1918 space.
    var permitsPrivateNetwork: Bool {
        self == .localNetwork || self == .loopback
    }

    /// Cleartext `http` is tolerated only where the destination is provably on the wearer's own
    /// network; everywhere else it is a Release-build rejection.
    var permitsCleartextHTTP: Bool { permitsPrivateNetwork }
}

/// What Medical Compliance's "local only" promise means for a given route.
enum MedicalRoutePolicy: Equatable, Sendable {
    /// Refuse the request outright while medical local-only is on.
    case blockedWhenLocalOnly
    /// Permitted even in local-only mode, with the reason it does not break the promise.
    case allowedLocalOnly(String)
    /// The promise does not govern this route, with the reason.
    case notApplicable(String)

    var blocksLocalOnly: Bool { self == .blockedWhenLocalOnly }

    /// The one-line justification an audit reads. Blocked routes need none.
    var justification: String? {
        switch self {
        case .blockedWhenLocalOnly: return nil
        case .allowedLocalOnly(let why), .notApplicable(let why): return why
        }
    }
}

/// Every outbound network route the app can originate, named once so the medical local-only rule,
/// the endpoint rules and the privacy manifest can all be checked against the same list.
///
/// `NetworkRouteRegistryTests` scrapes the source tree for `URLSession`/`webSocketTask`/`NWConnection`
/// owners and fails when an owning type maps to no case here, so a new network client cannot be
/// added without declaring what it sends and where.
enum NetworkRoute: String, CaseIterable, Sendable {

    // MARK: Speech to text
    case deepgramLiveTranscription
    case deepgramBatchTranscription

    // MARK: Text to speech
    case elevenLabsSpeechSynthesis
    case elevenLabsVoiceCatalog

    // MARK: Realtime and translation
    case openAIRealtimeSession
    case geminiLiveSession
    case geminiLiveModelCatalog
    case cloudTranslationCaptions

    // MARK: Model reasoning
    case llmCompletion
    case intentClassification
    case providerModelCatalog
    case conversationRecallSummary

    // MARK: Tools
    case webSearch
    case weatherLookup
    case newsHeadlines
    case currencyRates
    case aircraftOverhead
    case aedDirectory
    case homeAssistantCommand
    case homeAssistantEntityCache
    case openClawSkillCatalog

    // MARK: Gateways and bridges
    case openClawGatewaySocket
    case openClawBridgeRequest
    case openClawEventStream
    case gatewayConnectionTest
    case hermesBridgeSession
    case mcpHTTPTransport
    case customAgentHarness
    case expertBridgeWebhook
    case expertSignaling
    case offlineEndpointSync
    case webRTCBrowserStreaming
    case twitchChatSocket

    // MARK: Catalogs
    case clawHubCatalog
    case vaultPackCatalog
    case playbookHTTPStep
    case localizationCatalogDownload

    // MARK: On-device model acquisition
    case localModelRepositoryMetadata
    case localModelDownload
    case ttsVoiceModelDownload
    case asrModelDownload
    case fingerspellingModelDownload

    // MARK: Medical records
    case fhirExport
    case fhirConnectionTest

    // MARK: Account linking
    case claudeOAuthToken
    case chatGPTOAuthToken
    case googleOAuthToken

    // MARK: Local listeners
    case webHUDMirrorListener
    case mcpGlassesListener
    case loopbackOAuthCallback
}

extension NetworkRoute {

    /// One sentence, in the terms a privacy reviewer uses.
    var purpose: String {
        switch self {
        case .deepgramLiveTranscription: return "Stream captured audio to the diarization vendor for live who-said-what transcription."
        case .deepgramBatchTranscription: return "Upload a recorded audio file for diarized transcription after the fact."
        case .elevenLabsSpeechSynthesis: return "Send the assistant's reply text to the cloud voice vendor and play back the returned audio."
        case .elevenLabsVoiceCatalog: return "List the voices the configured key may use, for the voice picker."
        case .openAIRealtimeSession: return "Hold a live speech-to-speech session, streaming audio and optional frames both ways."
        case .geminiLiveSession: return "Hold a live multimodal session, streaming audio and optional frames both ways."
        case .geminiLiveModelCatalog: return "List the realtime models the configured key may use."
        case .cloudTranslationCaptions: return "Translate captured speech in the cloud for translated captions."
        case .llmCompletion: return "Send the assembled prompt, history and any attached frames to the selected model provider."
        case .intentClassification: return "Classify an utterance into an intent using the configured model provider."
        case .providerModelCatalog: return "List the models a configured provider key may use."
        case .conversationRecallSummary: return "Summarize retrieved past conversation turns into a cited answer."
        case .webSearch: return "Run a web search for a query the wearer or the model produced."
        case .weatherLookup: return "Fetch a forecast for the device's coarse location or a named place."
        case .newsHeadlines: return "Fetch news headlines for a topic."
        case .currencyRates: return "Fetch published exchange rates."
        case .aircraftOverhead: return "Fetch aircraft positions near the device's coarse location."
        case .aedDirectory: return "Look up publicly listed defibrillator locations near the device."
        case .homeAssistantCommand: return "Call the wearer's Home Assistant instance to read or change device state."
        case .homeAssistantEntityCache: return "Refresh the cached list of the wearer's Home Assistant entities."
        case .openClawSkillCatalog: return "List or search the skills the configured agent gateway offers."
        case .openClawGatewaySocket: return "Hold the agent gateway's duplex session, carrying prompts, transcripts and frames."
        case .openClawBridgeRequest: return "Send a single request to the agent gateway and read its reply."
        case .openClawEventStream: return "Subscribe to the agent gateway's event stream."
        case .gatewayConnectionTest: return "Health-check a gateway URL and token the user just entered."
        case .hermesBridgeSession: return "Exchange session data with a Hermes bridge host on the wearer's network."
        case .mcpHTTPTransport: return "Call a configured MCP server's HTTP transport with a tool request."
        case .customAgentHarness: return "Drive a user-supplied agent endpoint with the conversation so far."
        case .expertBridgeWebhook: return "Notify a Field Assist expert endpoint that help was requested."
        case .expertSignaling: return "Exchange WebRTC signaling so an expert can see the wearer's camera."
        case .webRTCBrowserStreaming: return "Relay camera frames to a browser viewer through the signaling server."
        case .offlineEndpointSync: return "Flush queued offline records to the configured sync endpoint."
        case .twitchChatSocket: return "Read and post broadcast chat messages."
        case .clawHubCatalog: return "Fetch the published skill-pack catalog."
        case .vaultPackCatalog: return "Fetch the published vault-pack catalog."
        case .playbookHTTPStep: return "Call the URL an active playbook step names, with variables the run has filled in."
        case .localizationCatalogDownload: return "Download an updated localization catalog."
        case .localModelRepositoryMetadata: return "Read a model repository's file listing before downloading weights."
        case .localModelDownload: return "Download on-device model weights in the background."
        case .ttsVoiceModelDownload: return "Download on-device neural voice model files."
        case .asrModelDownload: return "Download on-device speech-recognition model files."
        case .fingerspellingModelDownload: return "Download the on-device fingerspelling model files."
        case .fhirExport: return "Write an export to the operator's own FHIR record system."
        case .fhirConnectionTest: return "Health-check the FHIR base URL and credential the operator just entered."
        case .claudeOAuthToken: return "Exchange or refresh an OAuth token for the model provider account."
        case .chatGPTOAuthToken: return "Exchange or refresh an OAuth token for the model provider account."
        case .googleOAuthToken: return "Exchange or refresh an OAuth token for the linked Google account."
        case .webHUDMirrorListener: return "Serve the HUD mirror to a browser on the wearer's own network."
        case .mcpGlassesListener: return "Serve the glasses MCP tool surface to a client on the wearer's own network."
        case .loopbackOAuthCallback: return "Receive the OAuth redirect on 127.0.0.1 during account linking."
        }
    }

    /// What can leave the device on this route. Inbound-only bytes are not listed except as
    /// `modelAsset`, which exists so asset downloads are visibly distinguished from content egress.
    var dataClasses: Set<NetworkDataClass> {
        switch self {
        case .deepgramLiveTranscription, .deepgramBatchTranscription:
            return [.audio, .transcript]
        case .elevenLabsSpeechSynthesis:
            return [.transcript, .credential]
        case .elevenLabsVoiceCatalog, .geminiLiveModelCatalog, .providerModelCatalog,
             .gatewayConnectionTest, .fhirConnectionTest:
            return [.credential]
        case .openAIRealtimeSession, .geminiLiveSession:
            return [.audio, .transcript, .frame, .credential]
        case .cloudTranslationCaptions:
            return [.audio, .transcript, .credential]
        case .llmCompletion:
            return [.promptText, .transcript, .frame, .healthFact, .contactData, .credential]
        case .intentClassification:
            return [.promptText, .credential]
        case .conversationRecallSummary:
            return [.transcript, .healthFact]
        case .webSearch, .newsHeadlines:
            return [.promptText]
        case .weatherLookup, .aircraftOverhead, .aedDirectory:
            return [.location]
        case .currencyRates, .clawHubCatalog, .vaultPackCatalog:
            return [.telemetryFree]
        case .playbookHTTPStep:
            return [.promptText]
        case .homeAssistantCommand, .homeAssistantEntityCache:
            return [.promptText, .credential]
        case .openClawSkillCatalog:
            return [.promptText, .credential]
        case .openClawGatewaySocket, .openClawBridgeRequest, .customAgentHarness:
            return [.promptText, .transcript, .frame, .credential]
        case .openClawEventStream:
            return [.credential]
        case .hermesBridgeSession:
            return [.transcript, .frame]
        case .mcpHTTPTransport:
            return [.promptText, .credential]
        case .expertBridgeWebhook:
            return [.transcript, .location]
        case .expertSignaling, .webRTCBrowserStreaming:
            return [.frame, .audio]
        case .offlineEndpointSync:
            return [.transcript, .healthFact, .credential]
        case .twitchChatSocket:
            return [.transcript, .credential]
        case .localizationCatalogDownload, .localModelRepositoryMetadata, .localModelDownload,
             .ttsVoiceModelDownload, .asrModelDownload, .fingerspellingModelDownload:
            return [.modelAsset]
        case .fhirExport:
            return [.healthFact, .credential]
        case .claudeOAuthToken, .chatGPTOAuthToken, .googleOAuthToken:
            return [.credential]
        case .webHUDMirrorListener:
            return [.frame, .transcript]
        case .mcpGlassesListener:
            return [.promptText, .frame]
        case .loopbackOAuthCallback:
            return [.credential]
        }
    }

    var endpointClass: NetworkEndpointClass {
        switch self {
        case .deepgramLiveTranscription, .deepgramBatchTranscription,
             .elevenLabsSpeechSynthesis, .elevenLabsVoiceCatalog,
             .openAIRealtimeSession, .geminiLiveSession, .geminiLiveModelCatalog,
             .cloudTranslationCaptions, .llmCompletion, .intentClassification,
             .providerModelCatalog, .conversationRecallSummary,
             .customAgentHarness, .expertBridgeWebhook, .expertSignaling,
             .offlineEndpointSync, .webRTCBrowserStreaming,
             .fhirExport, .fhirConnectionTest:
            return .userConfiguredCloud
        case .claudeOAuthToken, .chatGPTOAuthToken, .googleOAuthToken,
             .localModelRepositoryMetadata, .localModelDownload, .ttsVoiceModelDownload,
             .asrModelDownload, .fingerspellingModelDownload, .localizationCatalogDownload,
             .clawHubCatalog, .vaultPackCatalog:
            return .firstPartyCloud
        case .webSearch, .weatherLookup, .newsHeadlines, .currencyRates,
             .aircraftOverhead, .aedDirectory, .twitchChatSocket, .playbookHTTPStep:
            return .publicWeb
        case .homeAssistantCommand, .homeAssistantEntityCache, .hermesBridgeSession,
             .mcpHTTPTransport, .webHUDMirrorListener, .mcpGlassesListener:
            return .localNetwork
        case .loopbackOAuthCallback:
            return .loopback
        case .openClawGatewaySocket, .openClawBridgeRequest, .openClawEventStream,
             .gatewayConnectionTest, .openClawSkillCatalog:
            return .gateway
        }
    }

    var medicalPolicy: MedicalRoutePolicy {
        switch self {
        case .localModelRepositoryMetadata, .localModelDownload, .ttsVoiceModelDownload,
             .asrModelDownload, .fingerspellingModelDownload:
            return .allowedLocalOnly(
                "The outbound half is a model identifier and a range request; no captured content leaves, and these downloads are what make on-device inference possible in the first place.")
        case .loopbackOAuthCallback:
            return .allowedLocalOnly(
                "An inbound listener bound to 127.0.0.1; the redirect never reaches a network interface.")
        case .conversationRecallSummary:
            return .notApplicable(
                "It owns no transport: it delegates to llmCompletion, which the model-routing policy already redirects to an on-device model instead of refusing. Blocking it would disable a feature whose bytes never leave the phone.")
        case .fhirExport, .fhirConnectionTest:
            return .notApplicable(
                "The destination is the operator's own record system, which is the point of the medical export; local-only governs third-party egress, not the covered entity's own write-back.")
        default:
            return .blockedWhenLocalOnly
        }
    }

    /// Some routes are a distinct *purpose* riding another route's transport. They still need
    /// their own guard call — a wearer turning off cloud translation is not turning off the
    /// realtime session — but they own no `URLSession`, so the scrape will never see them.
    /// Naming the transport they borrow keeps that explicit instead of looking like an omission.
    var transportDelegatedTo: NetworkRoute? {
        switch self {
        case .cloudTranslationCaptions: return .geminiLiveSession
        case .conversationRecallSummary: return .llmCompletion
        case .openClawEventStream: return .openClawGatewaySocket
        default: return nil
        }
    }

    /// The types that actually own the transport for this route. `NetworkRouteRegistryTests`
    /// checks this against a scrape of the source tree, so the mapping cannot silently rot.
    /// Empty exactly when ``transportDelegatedTo`` names the route whose transport is borrowed.
    var owningTypes: [String] {
        switch self {
        case .deepgramLiveTranscription: return ["DeepgramSTTService"]
        case .deepgramBatchTranscription: return ["DeepgramBatchService"]
        case .elevenLabsSpeechSynthesis, .elevenLabsVoiceCatalog: return ["TextToSpeechService"]
        case .openAIRealtimeSession: return ["OpenAIRealtimeService", "OpenAIWebSocketDelegate"]
        case .geminiLiveSession: return ["GeminiLiveService", "WebSocketDelegate"]
        case .geminiLiveModelCatalog: return ["GeminiLiveModelCatalog"]
        case .cloudTranslationCaptions: return []
        case .llmCompletion: return ["LLMService"]
        case .intentClassification: return ["IntentClassifier"]
        case .providerModelCatalog: return ["ModelFetcher"]
        case .conversationRecallSummary: return []
        case .webSearch: return ["WebSearchTool"]
        case .weatherLookup: return ["WeatherTool"]
        case .newsHeadlines: return ["NewsTool"]
        case .currencyRates: return ["CurrencyTool"]
        case .aircraftOverhead: return ["AircraftOverheadTool"]
        case .aedDirectory: return ["AEDFinder"]
        case .homeAssistantCommand: return ["HomeAssistantTool"]
        case .homeAssistantEntityCache: return ["HomeAssistantEntityCache"]
        case .openClawSkillCatalog: return ["OpenClawSkillsTool"]
        case .openClawGatewaySocket: return ["URLSessionGatewaySocket"]
        case .openClawBridgeRequest: return ["OpenClawBridge"]
        case .openClawEventStream: return []
        case .gatewayConnectionTest: return ["EditGatewaySheet"]
        case .hermesBridgeSession: return ["HermesBridgeService"]
        case .mcpHTTPTransport: return ["HTTPTransport"]
        case .customAgentHarness: return ["CustomAgentHarness"]
        case .expertBridgeWebhook: return ["WebhookExpertNotifier"]
        case .expertSignaling: return ["ExpertSignalingClient"]
        case .offlineEndpointSync: return ["EndpointSyncSink"]
        case .webRTCBrowserStreaming: return ["WebRTCStreamingService"]
        case .twitchChatSocket: return ["URLSessionChatSocket"]
        case .clawHubCatalog: return ["ClawHubService"]
        case .vaultPackCatalog: return ["VaultPackCatalogService"]
        case .playbookHTTPStep: return ["PlaybookStore"]
        case .localizationCatalogDownload: return ["LocalizationManager"]
        case .localModelRepositoryMetadata: return ["LocalModelRepositoryClient"]
        case .localModelDownload: return ["LocalModelBackgroundTransfer"]
        case .ttsVoiceModelDownload: return ["HuggingFaceModelInstaller"]
        case .asrModelDownload: return ["ASRModelBundle"]
        case .fingerspellingModelDownload: return ["FingerspellingModelBundle"]
        case .fhirExport: return ["MedicalExportService"]
        case .fhirConnectionTest: return ["MedicalExportSettingsView"]
        case .claudeOAuthToken: return ["ClaudeOAuthService"]
        case .chatGPTOAuthToken: return ["ChatGPTOAuthService"]
        case .googleOAuthToken: return ["GoogleOAuthService"]
        case .webHUDMirrorListener: return ["WebHUDMirrorServer"]
        case .mcpGlassesListener: return ["MCPGlassesServer"]
        case .loopbackOAuthCallback: return ["LoopbackCallbackServer"]
        }
    }
}

/// The registry itself: lookups plus the short, justified exemption list the scrape test consults.
enum NetworkRouteRegistry {

    /// Types that hold a `URLSession`/`NWConnection` but originate no route of their own.
    /// Deliberately short — anything added here has to be a transport or an observer, never a
    /// feature that sends something.
    static let exemptTransportTypes: [String: String] = [
        "BoundedHTTPClient":
            "Shared hardened transport. It carries whatever route its caller declares; guarding here would hide which feature actually sent the bytes.",
        "NetworkInterceptor":
            "A URLProtocol diagnostic observer. It re-issues a request another route already originated and guarded, so counting it again would double-count."
    ]

    static func route(owningType: String) -> NetworkRoute? {
        NetworkRoute.allCases.first { $0.owningTypes.contains(owningType) }
    }

    static func routes(sending dataClass: NetworkDataClass) -> [NetworkRoute] {
        NetworkRoute.allCases.filter { $0.dataClasses.contains(dataClass) }
    }
}
