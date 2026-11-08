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

extension NetworkDataClass {
    /// The `NSPrivacyCollectedDataType` this class has to appear as in `PrivacyInfo.xcprivacy`,
    /// or nil when it needs no declaration. `PrivacyManifestReconciliationTests` walks the registry
    /// against the manifest so a new route cannot start sending a category the manifest denies.
    var privacyManifestType: String? {
        switch self {
        case .audio: return "NSPrivacyCollectedDataTypeAudioData"
        case .transcript, .promptText: return "NSPrivacyCollectedDataTypeOtherUserContent"
        case .frame: return "NSPrivacyCollectedDataTypePhotosorVideos"
        case .healthFact: return "NSPrivacyCollectedDataTypeHealth"
        case .location: return "NSPrivacyCollectedDataTypePreciseLocation"
        case .contactData: return "NSPrivacyCollectedDataTypeContacts"
        case .credential:
            // The user's own key, sent to the vendor it belongs to so that vendor can serve them.
            // Apple's categories describe data the developer collects about the user; this is
            // neither collected by us nor about them.
            return nil
        case .modelAsset:
            // The outbound half is an identifier; the bytes travel inbound.
            return nil
        case .telemetryFree:
            return nil
        }
    }
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

    /// Which classes may address loopback or RFC1918 space.
    ///
    /// `gateway` is here because an agent gateway has a first-class LAN mode — the gateway config
    /// carries a `lanURL` alongside its tunnel URL, and a self-hosted gateway on the wearer's own
    /// machine is the ordinary case, not a workaround. Everything else must reach a public host.
    var permitsPrivateNetwork: Bool {
        switch self {
        case .localNetwork, .loopback, .gateway: return true
        case .userConfiguredCloud, .firstPartyCloud, .publicWeb: return false
        }
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
    /// Plan JM P2 — dictation through a cloud recogniser the wearer chose. Separate from the
    /// diarization routes: a different switch, a different purpose.
    case deepgramDictation
    case openAIDictation

    // MARK: Text to speech
    case elevenLabsSpeechSynthesis
    case elevenLabsVoiceCatalog
    /// Plan ID item 5: the OpenAI and xAI voices. OpenAI publishes no voice list, so no catalog.
    case openAISpeechSynthesis
    case xaiSpeechSynthesis
    case xaiVoiceCatalog
    /// Plan JZ: the Gemini voice, with the saved Gemini model's key. Its voices are a fixed list;
    /// its speech models come from the key's own model list.
    case geminiSpeechSynthesis
    case geminiSpeechModelCatalog

    // MARK: Realtime and translation
    case openAIRealtimeSession
    case openAICompatibleRealtimeSession
    case geminiLiveSession
    case geminiLiveModelCatalog
    case cloudTranslationCaptions

    // MARK: Model reasoning
    case llmCompletion
    case intentClassification
    case providerModelCatalog
    case conversationRecallSummary
    /// Plan GE: the one check that decides an offline conversation can move back to the cloud.
    case connectivityProbe

    // MARK: Tools
    case webSearch
    // Weather itself is WeatherKit's own request (no transport of ours, so no route — the same
    // rule as MusicKit and MapKit search); only the attribution-mark download is ours.
    case weatherAttributionMark
    case newsHeadlines
    /// Apple's public podcast directory: a show looked up by the words the wearer said (Plan JF).
    case podcastDirectory
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
    /// Plan JP: Hermes Agent's own OpenAI-compatible API server — a conversation turn over HTTP,
    /// beside the bridge script's socket above.
    case hermesAgentAPI
    case mcpHTTPTransport
    case customAgentHarness
    case expertBridgeWebhook
    case expertSignaling
    case offlineEndpointSync
    case workizAPI
    case webRTCBrowserStreaming
    case twitchChatSocket
    /// A recorded job's bundle sent to the organisation's office over the managed connection
    /// (Plan HE). Not a `URLSession`: the bytes are carried by the embedded office engine.
    case jobRecordingOfficeSync

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
    case searchModelDownload

    // MARK: Medical records
    case fhirExport
    case fhirConnectionTest

    // MARK: Account linking
    case claudeOAuthToken
    case chatGPTOAuthToken
    case googleOAuthToken
    case xaiOAuthToken

    // MARK: Local listeners
    case webHUDMirrorListener
    case mcpGlassesListener
    case loopbackOAuthCallback
    /// Development-only (`DAT_MOCK_DISPLAY`, Debug Simulator builds): the simulated Display's test server.
    case simulatedDisplayTestServer
}

extension NetworkRoute {

    /// One sentence, in the terms a privacy reviewer uses.
    var purpose: String {
        switch self {
        case .deepgramLiveTranscription: return "Stream captured audio to the diarization vendor for live who-said-what transcription."
        case .deepgramBatchTranscription: return "Upload a recorded audio file for diarized transcription after the fact."
        case .deepgramDictation: return "Stream the audio of a question the wearer is asking to Deepgram, with the wearer's own key, when they chose it as the recognizer."
        case .openAIDictation: return "Upload the audio of a question the wearer just asked to OpenAI's transcription endpoint, with the OpenAI API key, when they chose it as the recognizer."
        case .elevenLabsSpeechSynthesis: return "Send the assistant's reply text to the cloud voice vendor and play back the returned audio."
        case .elevenLabsVoiceCatalog: return "List the voices the configured key may use, for the voice picker."
        case .openAISpeechSynthesis: return "Send the assistant's reply text to OpenAI's speech endpoint with the OpenAI key and play back the returned audio."
        case .xaiSpeechSynthesis: return "Send the assistant's reply text to xAI's speech endpoint with the xAI key or sign-in and play back the returned audio."
        case .xaiVoiceCatalog: return "List the voices the xAI key or sign-in may use, for the voice picker."
        case .geminiSpeechSynthesis: return "Send the assistant's reply text to Google's Gemini speech model with the Gemini key and play back the returned audio."
        case .geminiSpeechModelCatalog: return "List the models the Gemini key may use, to offer its speech models in the voice picker."
        case .openAIRealtimeSession: return "Hold a live speech-to-speech session, streaming audio and optional frames both ways."
        case .openAICompatibleRealtimeSession: return "Hold a live session with the OpenAI-compatible server explicitly configured by the wearer."
        case .geminiLiveSession: return "Hold a live multimodal session, streaming audio and optional frames both ways."
        case .geminiLiveModelCatalog: return "List the realtime models the configured key may use."
        case .cloudTranslationCaptions: return "Translate captured speech in the cloud for translated captions."
        case .llmCompletion: return "Send the assembled prompt, history and any attached frames to the selected model provider."
        case .intentClassification: return "Classify an utterance into an intent using the configured model provider."
        case .providerModelCatalog: return "List the models a configured provider key may use."
        case .conversationRecallSummary: return "Summarize retrieved past conversation turns into a cited answer."
        case .connectivityProbe: return "Send a content-free HEAD request to the configured model provider's own host to confirm the connection is back before an offline conversation returns to the cloud."
        case .webSearch: return "Run a web search for a query the wearer or the model produced."
        case .weatherAttributionMark: return "Download the Apple Weather mark shown beside weather data, as Apple requires; the request names a fixed image and nothing about the wearer."
        case .newsHeadlines: return "Fetch news headlines for a topic."
        case .podcastDirectory: return "Look a podcast up by name in Apple's public directory so its episode can open in the Podcasts app; only the words the wearer said are sent."
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
        case .hermesAgentAPI: return "Send a conversation turn — and, for a visual question, one privacy-filtered glasses still — to the Hermes Agent API server on the wearer's network, and check that it answers."
        case .mcpHTTPTransport: return "Call a configured MCP server's HTTP transport with a tool request."
        case .customAgentHarness: return "Drive a user-supplied agent endpoint with the conversation so far."
        case .expertBridgeWebhook: return "Notify a Field Assist expert endpoint that help was requested."
        case .expertSignaling: return "Exchange WebRTC signaling so an expert can see the wearer's camera."
        case .webRTCBrowserStreaming: return "Relay camera frames to a browser viewer through the signaling server."
        case .workizAPI: return "Read assigned jobs and write a confirmed work report to the technician’s Workiz account."
        case .offlineEndpointSync: return "Flush queued offline records to the configured sync endpoint."
        case .twitchChatSocket: return "Read and post broadcast chat messages."
        case .jobRecordingOfficeSync: return "Send a recorded job — its video, sound, timeline and transcript — to the organisation's own office, the one this phone is paired with."
        case .clawHubCatalog: return "Fetch the published skill-pack catalog."
        case .vaultPackCatalog: return "Fetch the published vault-pack catalog."
        case .playbookHTTPStep: return "Call the URL an active playbook step names, with variables the run has filled in."
        case .localizationCatalogDownload: return "Download an updated localization catalog."
        case .localModelRepositoryMetadata: return "Read a model repository's file listing before downloading weights."
        case .localModelDownload: return "Download on-device model weights in the background."
        case .ttsVoiceModelDownload: return "Download on-device neural voice model files."
        case .asrModelDownload: return "Download on-device speech-recognition model files."
        case .fingerspellingModelDownload: return "Download the on-device fingerspelling model files."
        case .searchModelDownload: return "Download the on-device search model that Field Assist's manual search can use, when the wearer chooses it."
        case .fhirExport: return "Write an export to the operator's own FHIR record system."
        case .fhirConnectionTest: return "Health-check the FHIR base URL the operator entered. The saved credential goes only to the address it was saved with."
        case .claudeOAuthToken: return "Exchange or refresh an OAuth token for the model provider account."
        case .chatGPTOAuthToken: return "Exchange or refresh an OAuth token for the model provider account."
        case .googleOAuthToken: return "Exchange or refresh an OAuth token for the linked Google account."
        case .xaiOAuthToken: return "Discover the sign-in endpoints, then exchange or refresh an OAuth token for the xAI account."
        case .webHUDMirrorListener: return "Serve the HUD mirror to a browser on the wearer's own network."
        case .mcpGlassesListener: return "Serve the glasses MCP tool surface to a client on the wearer's own network."
        case .loopbackOAuthCallback: return "Receive the OAuth redirect on 127.0.0.1 during account linking."
        case .simulatedDisplayTestServer: return "Read the simulated Display's current frame from its test server on 127.0.0.1, in development-only Simulator builds."
        }
    }

    /// What can leave the device on this route. Inbound-only bytes are not listed except as
    /// `modelAsset`, which exists so asset downloads are visibly distinguished from content egress.
    var dataClasses: Set<NetworkDataClass> {
        switch self {
        case .deepgramLiveTranscription, .deepgramBatchTranscription, .deepgramDictation:
            return [.audio, .transcript]
        case .openAIDictation:
            return [.audio, .transcript, .credential]
        case .elevenLabsSpeechSynthesis, .openAISpeechSynthesis, .xaiSpeechSynthesis,
             .geminiSpeechSynthesis:
            return [.transcript, .credential]
        case .elevenLabsVoiceCatalog, .xaiVoiceCatalog, .geminiSpeechModelCatalog,
             .geminiLiveModelCatalog, .providerModelCatalog,
             .gatewayConnectionTest, .fhirConnectionTest:
            return [.credential]
        case .openAIRealtimeSession, .openAICompatibleRealtimeSession, .geminiLiveSession:
            return [.audio, .transcript, .frame, .credential]
        case .cloudTranslationCaptions:
            return [.audio, .transcript, .credential]
        case .llmCompletion:
            return [.promptText, .transcript, .frame, .healthFact, .contactData, .credential]
        case .intentClassification:
            return [.promptText, .credential]
        case .conversationRecallSummary:
            return [.transcript, .healthFact]
        case .webSearch, .newsHeadlines, .podcastDirectory:
            return [.promptText]
        case .aircraftOverhead, .aedDirectory:
            return [.location]
        case .currencyRates, .clawHubCatalog, .vaultPackCatalog, .weatherAttributionMark,
             .connectivityProbe:
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
        case .hermesAgentAPI:
            return [.promptText, .transcript, .frame, .credential]
        case .mcpHTTPTransport:
            return [.promptText, .credential]
        case .expertBridgeWebhook:
            return [.transcript, .location]
        case .expertSignaling, .webRTCBrowserStreaming:
            return [.frame, .audio]
        case .jobRecordingOfficeSync:
            return [.frame, .audio, .transcript]
        case .workizAPI: return [.transcript, .healthFact, .credential, .contactData]
        case .offlineEndpointSync:
            return [.transcript, .healthFact, .credential]
        case .twitchChatSocket:
            return [.transcript, .credential]
        case .localizationCatalogDownload, .localModelRepositoryMetadata, .localModelDownload,
             .ttsVoiceModelDownload, .asrModelDownload, .fingerspellingModelDownload, .searchModelDownload:
            return [.modelAsset]
        case .fhirExport:
            return [.healthFact, .credential]
        case .claudeOAuthToken, .chatGPTOAuthToken, .googleOAuthToken, .xaiOAuthToken:
            return [.credential]
        case .webHUDMirrorListener:
            return [.frame, .transcript]
        case .mcpGlassesListener:
            return [.promptText, .frame]
        case .loopbackOAuthCallback:
            return [.credential]
        case .simulatedDisplayTestServer:
            return [.telemetryFree]
        }
    }

    var endpointClass: NetworkEndpointClass {
        switch self {
        case .deepgramLiveTranscription, .deepgramBatchTranscription,
             .deepgramDictation, .openAIDictation,
             .elevenLabsSpeechSynthesis, .elevenLabsVoiceCatalog,
             .openAISpeechSynthesis, .xaiSpeechSynthesis, .xaiVoiceCatalog,
             .geminiSpeechSynthesis, .geminiSpeechModelCatalog,
             .openAIRealtimeSession, .geminiLiveSession, .geminiLiveModelCatalog,
             .cloudTranslationCaptions, .llmCompletion, .intentClassification,
             .providerModelCatalog, .conversationRecallSummary, .connectivityProbe,
             .customAgentHarness, .expertBridgeWebhook, .expertSignaling,
             .offlineEndpointSync, .workizAPI, .webRTCBrowserStreaming,
             .fhirExport, .fhirConnectionTest:
            return .userConfiguredCloud
        case .claudeOAuthToken, .chatGPTOAuthToken, .googleOAuthToken, .xaiOAuthToken,
             .localModelRepositoryMetadata, .localModelDownload, .ttsVoiceModelDownload,
             .asrModelDownload, .fingerspellingModelDownload, .searchModelDownload, .localizationCatalogDownload,
             .clawHubCatalog, .vaultPackCatalog, .weatherAttributionMark:
            return .firstPartyCloud
        case .webSearch, .newsHeadlines, .podcastDirectory, .currencyRates,
             .aircraftOverhead, .aedDirectory, .twitchChatSocket, .playbookHTTPStep:
            return .publicWeb
        case .homeAssistantCommand, .homeAssistantEntityCache, .hermesBridgeSession, .hermesAgentAPI,
             .mcpHTTPTransport, .webHUDMirrorListener, .mcpGlassesListener, .jobRecordingOfficeSync,
             .openAICompatibleRealtimeSession:
            // The explicit compatible-server setting supports both LAN servers and TLS gateways.
            return .localNetwork
        case .loopbackOAuthCallback, .simulatedDisplayTestServer:
            return .loopback
        case .openClawGatewaySocket, .openClawBridgeRequest, .openClawEventStream,
             .gatewayConnectionTest, .openClawSkillCatalog:
            return .gateway
        }
    }

    var medicalPolicy: MedicalRoutePolicy {
        switch self {
        case .localModelRepositoryMetadata, .localModelDownload, .ttsVoiceModelDownload,
             .asrModelDownload, .fingerspellingModelDownload, .searchModelDownload:
            return .allowedLocalOnly(
                "The outbound half is a model identifier and a range request; no captured content leaves, and these downloads are what make on-device inference possible in the first place.")
        case .loopbackOAuthCallback:
            return .allowedLocalOnly(
                "An inbound listener bound to 127.0.0.1; the redirect never reaches a network interface.")
        case .simulatedDisplayTestServer:
            return .allowedLocalOnly(
                "A request to 127.0.0.1 in a development-only Simulator build; it never reaches a network interface and the code is not compiled into a store or TestFlight build.")
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
        case .openAICompatibleRealtimeSession: return .openAIRealtimeSession
        case .conversationRecallSummary: return .llmCompletion
        case .openClawEventStream: return .openClawGatewaySocket
        default: return nil
        }
    }

    /// The type that sends on this route when its transport is the embedded office engine rather
    /// than a `URLSession`. The scrape below looks for `URLSession` and its kin and so can never
    /// see such a route; naming the sender here is what keeps it from looking like an omission,
    /// and `NetworkRouteRegistryTests` checks that the type exists and calls the medical guard for
    /// this route. Nil for every route the scrape can see.
    var officeEngineSender: String? {
        switch self {
        case .jobRecordingOfficeSync: return "JobRecordingSyncService"
        default: return nil
        }
    }

    /// The types that actually own the transport for this route. `NetworkRouteRegistryTests`
    /// checks this against a scrape of the source tree, so the mapping cannot silently rot.
    /// Empty exactly when ``transportDelegatedTo`` names the route whose transport is borrowed, or
    /// ``officeEngineSender`` names the type that sends over the embedded office engine.
    var owningTypes: [String] {
        switch self {
        case .deepgramLiveTranscription: return ["DeepgramSTTService"]
        case .deepgramBatchTranscription: return ["DeepgramBatchService"]
        case .deepgramDictation: return ["DeepgramDictationService"]
        case .openAIDictation: return ["OpenAIDictationService"]
        case .elevenLabsSpeechSynthesis, .elevenLabsVoiceCatalog,
             .openAISpeechSynthesis, .xaiSpeechSynthesis, .xaiVoiceCatalog,
             .geminiSpeechSynthesis, .geminiSpeechModelCatalog: return ["TextToSpeechService"]
        case .openAIRealtimeSession: return ["RealtimeJSONSessionService"]
        case .openAICompatibleRealtimeSession: return []
        case .geminiLiveSession: return ["GeminiLiveService"]
        case .geminiLiveModelCatalog: return ["GeminiLiveModelCatalog"]
        case .cloudTranslationCaptions: return []
        case .llmCompletion: return ["LLMService"]
        case .intentClassification: return ["IntentClassifier"]
        case .providerModelCatalog: return ["ModelFetcher"]
        case .conversationRecallSummary: return []
        case .connectivityProbe: return ["ConnectivityProbe"]
        case .webSearch: return ["WebSearchTool"]
        case .weatherAttributionMark: return ["WeatherAttributionMarkLoader"]
        case .newsHeadlines: return ["NewsTool"]
        case .podcastDirectory: return ["AppleLookupPodcastDirectory"]
        case .currencyRates: return ["CurrencyTool"]
        case .aircraftOverhead: return ["AircraftOverheadTool"]
        case .aedDirectory: return ["AEDFinder"]
        case .homeAssistantCommand: return ["HomeAssistantTool", "HomeAssistantRESTClient"]
        case .homeAssistantEntityCache: return ["HomeAssistantEntityCache"]
        case .openClawSkillCatalog: return ["OpenClawSkillsTool"]
        case .openClawGatewaySocket: return ["URLSessionGatewaySocket"]
        case .openClawBridgeRequest: return ["OpenClawBridge"]
        case .openClawEventStream: return []
        case .gatewayConnectionTest: return ["EditGatewaySheet"]
        case .hermesBridgeSession: return ["URLSessionHermesSocket"]
        case .hermesAgentAPI: return ["URLSessionHermesHTTPTransport"]
        case .mcpHTTPTransport: return ["HTTPTransport"]
        case .customAgentHarness: return ["CustomAgentHarness"]
        case .expertBridgeWebhook: return ["WebhookExpertNotifier"]
        case .expertSignaling: return ["ExpertSignalingClient"]
        case .workizAPI: return ["URLSessionWorkizTransport"]
        case .offlineEndpointSync: return ["EndpointSyncSink"]
        case .webRTCBrowserStreaming: return ["WebRTCStreamingService"]
        case .twitchChatSocket: return ["URLSessionChatSocket"]
        case .jobRecordingOfficeSync: return []
        case .clawHubCatalog: return ["ClawHubService"]
        case .vaultPackCatalog: return ["VaultPackCatalogService"]
        case .playbookHTTPStep: return ["PlaybookStore"]
        case .localizationCatalogDownload: return ["LocalizationManager"]
        case .localModelRepositoryMetadata: return ["LocalModelRepositoryClient"]
        case .localModelDownload: return ["LocalModelBackgroundTransfer"]
        case .ttsVoiceModelDownload: return ["HuggingFaceModelInstaller"]
        case .asrModelDownload: return ["ASRModelBundle"]
        case .fingerspellingModelDownload: return ["FingerspellingModelBundle"]
        case .searchModelDownload: return ["HuggingFaceModelInstaller"]
        case .fhirExport: return ["MedicalExportService"]
        case .fhirConnectionTest: return ["MedicalExportService"]
        case .claudeOAuthToken: return ["ClaudeOAuthService"]
        case .chatGPTOAuthToken: return ["ChatGPTOAuthService"]
        case .googleOAuthToken: return ["GoogleOAuthService"]
        case .xaiOAuthToken: return ["XAIOAuthService"]
        case .webHUDMirrorListener: return ["WebHUDMirrorServer"]
        case .mcpGlassesListener: return ["MCPGlassesServer"]
        case .loopbackOAuthCallback: return ["LoopbackCallbackServer"]
        case .simulatedDisplayTestServer: return ["SimulatedDisplayLab"]
        }
    }
}

/// The registry itself: lookups plus the short, justified exemption list the scrape test consults.
enum NetworkRouteRegistry {

    /// Types that hold a `URLSession`/`NWConnection` but originate no route of their own.
    /// Deliberately short — anything added here has to be a transport or an observer, never a
    /// feature that sends something.
    static let exemptTransportTypes: [String: String] = [
        "CloudProcessingLease":
            "Cancels previously authorized requests on withdrawal; it originates no feature request or endpoint.",
        "CloudProcessingTransferDelegate":
            "Enforces the recipient and live consent on an existing caller-declared route; it does not originate requests.",
        "CloudProcessingSocketAuthorization":
            "Holds a caller-created socket suspended until recipient-specific approval; the socket owner declares and medically guards its route.",
        "CloudProcessingConsent":
            "File-scope URLSession extension adds explicit recipient consent to caller-declared routes; each feature retains its medical and endpoint checks.",
        "URLSession":
            "The consentedData and consentedBytes extensions authorize caller-declared routes; the system session has no feature purpose of its own.",
        "BoundedHTTPClient":
            "Shared hardened transport. It carries whatever route its caller declares; guarding here would hide which feature actually sent the bytes.",
        "RealtimeWebSocketTransport":
            "Shared ordered WebSocket mechanics; the caller declares and guards its route, and start rechecks policy before opening the socket.",
        "RealtimeConnectionTransport":
            "Transport interface for the shared WebSocket engine and its deterministic test double; it originates no feature route.",
        "NetworkInterceptor":
            "A URLProtocol diagnostic observer. It re-issues a request another route already originated and guarded, so counting it again would double-count."
    ]

    /// Manifest declarations no single route owns, with why they are nonetheless correct.
    /// Kept short for the same reason as the transport exemptions: a list of excuses that grows is
    /// a manifest that has stopped describing the app.
    static let manifestDeclarationsWithoutADedicatedRoute: [String: String] = [
        "NSPrivacyCollectedDataTypeCoarseLocation":
            "WeatherKit rounds coordinates to approximately one kilometre before sending them to Apple; the shared locationCoordinate route category also covers precise coordinates on other tools, so both precision categories are declared.",
        "NSPrivacyCollectedDataTypeFitness":
            "HealthKit workout, step, heart-rate and sleep figures reach a provider inside llmCompletion's tool results rather than on a transport of their own, and only while Share Health Data with AI is on; the route records the clinical half of that payload as healthFact."
    ]

    /// Every `NSPrivacyCollectedDataType` the registry says the app must declare.
    static var requiredPrivacyManifestTypes: Set<String> {
        var types = Set(NetworkRoute.allCases
            .flatMap(\.dataClasses)
            .compactMap(\.privacyManifestType))
        // A search query is user content, but Apple has a narrower category for it and the app
        // sends one, so the narrower category is the honest declaration.
        if NetworkRoute.allCases.contains(.webSearch) {
            types.insert("NSPrivacyCollectedDataTypeSearchHistory")
        }
        return types
    }

    static func route(owningType: String) -> NetworkRoute? {
        NetworkRoute.allCases.first { $0.owningTypes.contains(owningType) }
    }

    static func routes(sending dataClass: NetworkDataClass) -> [NetworkRoute] {
        NetworkRoute.allCases.filter { $0.dataClasses.contains(dataClass) }
    }
}
