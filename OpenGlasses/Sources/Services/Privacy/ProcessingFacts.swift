import Foundation

/// Everything `ProcessingSummary.compose(facts:)` is allowed to look at.
///
/// A value type with no `Config`, no services and no I/O, for the same reason every other policy in
/// this app is shaped this way: the interesting part is the table, the table is what has to be
/// exercised for a configuration nobody in this room has, and a table that reads global state can
/// only be tested by mutating global state.
///
/// **It carries no secrets.** There is no key, no token and no full URL here — the custom-endpoint
/// case carries a *host*, reduced by `ProcessingFacts.host(of:)` before it ever reaches this value.
/// The summary is read aloud and screenshotted; a base URL with a key in its query would be read
/// aloud with it.
struct ProcessingFacts: Equatable {

    /// How the selected model is reached.
    enum ModelKind: Equatable {
        /// MLX or Apple's on-device model. Runs here.
        case onDevice
        /// A named cloud provider at its own published endpoint.
        case cloud
        /// An OpenAI-compatible endpoint the wearer configured.
        case customEndpoint
    }

    /// Which voice engine would actually speak, after preference and availability.
    var voiceEngine: TTSEngine

    /// The realtime provider holding the conversation, or `nil` in Direct mode.
    ///
    /// A live session is the case where four of the five rows collapse onto one destination: the
    /// audio, the frames, the reasoning and the spoken reply all travel on the same socket. Saying
    /// so plainly is more useful than five rows that each name the same provider by accident.
    var liveProviderName: String?

    // The answer
    var modelKind: ModelKind
    var modelProviderName: String
    /// Host only, never a path or a query. `nil` when the configured URL has none.
    var modelHost: String?
    /// What has to be downloaded for the selected on-device model to run.
    var modelAssetName: String
    var modelAssetPresent: Bool
    /// Whether the selected model would be given images at all.
    var modelAcceptsImages: Bool

    // What you say
    var speechRecognitionOnDevice: Bool
    var speechRecognitionProviderName: String
    var speechRecognitionAssetName: String
    var speechRecognitionAssetPresent: Bool
    var diarizationEnabled: Bool
    var diarizationProviderName: String?

    // The voice you hear
    var kokoroInstalled: Bool
    var kokoroAssetName: String

    // Tools on other machines
    var remoteToolsEnabled: Bool
    var remoteToolProviderName: String
    /// Host only. `nil` when the gateway is reached at a first-party address rather than one the
    /// wearer typed.
    var remoteToolHost: String?

    /// Medical Compliance's local-only rule. When on, a row that would leave the device is stopped
    /// rather than rerouted, and the summary says so.
    var medicalLocalOnly: Bool

    init(voiceEngine: TTSEngine = .system,
         liveProviderName: String? = nil,
         modelKind: ModelKind = .cloud,
         modelProviderName: String = "the selected provider",
         modelHost: String? = nil,
         modelAssetName: String = "the on-device model",
         modelAssetPresent: Bool = true,
         modelAcceptsImages: Bool = true,
         speechRecognitionOnDevice: Bool = false,
         speechRecognitionProviderName: String = "Apple's speech recognition",
         speechRecognitionAssetName: String = "the on-device speech recognizer",
         speechRecognitionAssetPresent: Bool = true,
         diarizationEnabled: Bool = false,
         diarizationProviderName: String? = nil,
         kokoroInstalled: Bool = false,
         kokoroAssetName: String = "the on-device voice",
         remoteToolsEnabled: Bool = false,
         remoteToolProviderName: String = "the agent gateway",
         remoteToolHost: String? = nil,
         medicalLocalOnly: Bool = false) {
        self.voiceEngine = voiceEngine
        self.liveProviderName = liveProviderName
        self.modelKind = modelKind
        self.modelProviderName = modelProviderName
        self.modelHost = modelHost
        self.modelAssetName = modelAssetName
        self.modelAssetPresent = modelAssetPresent
        self.modelAcceptsImages = modelAcceptsImages
        self.speechRecognitionOnDevice = speechRecognitionOnDevice
        self.speechRecognitionProviderName = speechRecognitionProviderName
        self.speechRecognitionAssetName = speechRecognitionAssetName
        self.speechRecognitionAssetPresent = speechRecognitionAssetPresent
        self.diarizationEnabled = diarizationEnabled
        self.diarizationProviderName = diarizationProviderName
        self.kokoroInstalled = kokoroInstalled
        self.kokoroAssetName = kokoroAssetName
        self.remoteToolsEnabled = remoteToolsEnabled
        self.remoteToolProviderName = remoteToolProviderName
        self.remoteToolHost = remoteToolHost
        self.medicalLocalOnly = medicalLocalOnly
    }

    /// Reduce a configured URL to the host a wearer would recognise.
    ///
    /// Host and, when it is not the scheme's own, the port. Never the path, never the query, never
    /// the user-info component — an OpenAI-compatible base URL can legitimately carry a key in any
    /// of the three, and this string is spoken aloud.
    static func host(of urlString: String) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // A bare host with no scheme is common in a hand-typed field, and `URLComponents` puts it
        // in `path` rather than `host`, so try the normalised form too.
        let candidates = [trimmed, trimmed.contains("://") ? trimmed : "https://" + trimmed]
        for candidate in candidates {
            guard let components = URLComponents(string: candidate),
                  let host = components.host, !host.isEmpty else { continue }
            if let port = components.port { return "\(host):\(port)" }
            return host
        }
        return nil
    }
}

/// Reads the app's real settings into `ProcessingFacts`.
///
/// Deliberately the only place that touches `Config` for the summary, and deliberately not a
/// second source of truth: every value below is read from the owner that already decides it —
/// `Config.activeModel`, `TTSEngineSelector`, `ASREngineSelector`, the Kokoro model store, the
/// gateway configuration and the medical local-only flag.
@MainActor
enum ProcessingFactsProvider {

    /// What is configured right now.
    static func current() -> ProcessingFacts {
        var facts = ProcessingFacts()

        // Which realtime backend, if the wearer is in one of the live modes.
        facts.liveProviderName = liveProviderName()

        // The answer.
        let model = Config.activeModel
        let provider = model?.llmProvider ?? .custom
        facts.modelProviderName = provider.displayName
        facts.modelAcceptsImages = model?.visionEnabled ?? false
        switch provider {
        case .local:
            facts.modelKind = .onDevice
            let id = model?.model ?? ""
            facts.modelAssetName = id.isEmpty ? "the on-device model" : id
            facts.modelAssetPresent = !id.isEmpty && LocalLLMService().isModelDownloaded(id)
        case .appleOnDevice:
            facts.modelKind = .onDevice
            facts.modelAssetName = "Apple Intelligence"
            // Apple's own model ships with the OS; there is nothing for this app to download.
            facts.modelAssetPresent = true
        case .custom:
            facts.modelKind = .customEndpoint
            facts.modelHost = ProcessingFacts.host(of: model?.baseURL ?? "")
        default:
            facts.modelKind = .cloud
        }

        // What you say.
        let onDeviceASRReady = OnDeviceASREngine().isReady
        let chosenASR = ASREngineSelector.select(
            preference: Config.asrEnginePreference,
            availability: ASREngineSelector.Availability(appleSpeechReady: true,
                                                         onDeviceReady: onDeviceASRReady,
                                                         online: true))
        facts.speechRecognitionOnDevice = (chosenASR == .onDevice)
        facts.speechRecognitionAssetName = ASRModelBundle.active.displayName
        facts.speechRecognitionAssetPresent = onDeviceASRReady
        // `isDiarizationConfigured` rather than the raw switch: opted in, keyed, and not suppressed
        // by medical mode. A switch that is on but cannot run is not an egress.
        facts.diarizationEnabled = Config.isDiarizationConfigured
        facts.diarizationProviderName = facts.diarizationEnabled ? "Deepgram" : nil

        // The voice you hear.
        facts.kokoroInstalled = KokoroTTSEngine().isReady
        facts.kokoroAssetName = KokoroModelBundle.active.displayName
        facts.voiceEngine = TTSEngineSelector.select(
            preference: Config.ttsEnginePreference,
            availability: TTSEngineSelector.Availability(
                elevenLabsReady: !Config.elevenLabsAPIKey
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                kokoroReady: facts.kokoroInstalled))

        // Tools on other machines. Gated by Agent Mode like every other autonomous capability, so
        // a configured gateway with Agent Mode off reads as switched off — which is what it is.
        facts.remoteToolsEnabled = Config.isOpenClawAgentActive
        facts.remoteToolProviderName = "the agent gateway"
        facts.remoteToolHost = facts.remoteToolsEnabled ? gatewayHost() : nil

        facts.medicalLocalOnly = Config.hipaaLocalOnly
        return facts
    }

    private static func liveProviderName() -> String? {
        switch Config.appMode {
        case .geminiLive: return "Google (Gemini Live)"
        case .openaiRealtime: return "OpenAI (Realtime)"
        case .direct: return nil
        }
    }

    /// The host the highest-priority enabled gateway is reached at. Host only — a gateway
    /// configuration carries a token beside it, and nothing but the address belongs on this screen.
    private static func gatewayHost() -> String? {
        guard let gateway = Config.enabledGateways.first else { return nil }
        let candidates = [gateway.tunnelHost, gateway.lanHost]
        for candidate in candidates where !candidate.trimmingCharacters(in: .whitespaces).isEmpty {
            if let host = ProcessingFacts.host(of: candidate) { return host }
        }
        return nil
    }
}
