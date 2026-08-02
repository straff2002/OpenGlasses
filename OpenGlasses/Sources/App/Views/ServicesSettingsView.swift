import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

/// Sub-settings view for optional service integrations.
/// Accessed via NavigationLink from the main SettingsView.
struct ServicesSettingsView: View {
    @ObservedObject var appState: AppState

    // Text-to-Speech — self-contained: seeded from Config, persisted on change.
    @State private var elevenLabsKeyInput: String = Config.elevenLabsAPIKey
    @State private var selectedVoice: String = Config.elevenLabsVoiceId
    @State private var emotionAwareTTSEnabled: Bool = Config.emotionAwareTTSEnabled

    // Web Search
    @State private var perplexityKeyInput: String = Config.perplexityAPIKey
    @State private var tavilyKeyInput: String = Config.tavilyAPIKey

    // Live Streaming
    @State private var broadcastPlatform: String = Config.broadcastPlatform
    @State private var broadcastRTMPURL: String = Config.broadcastRTMPURL
    @State private var broadcastStreamKey: String = Config.broadcastStreamKey
    @State private var broadcastOrientation: String = Config.broadcastOrientation
    @State private var broadcastSource: String = Config.broadcastDefaultSource
    @State private var broadcastDualCapture: Bool = Config.broadcastDualCapture
    @State private var chatReadbackEnabled: Bool = Config.broadcastChatReadbackEnabled
    @State private var chatChannel: String = Config.broadcastChatChannel
    @State private var chatRateCap: Double = Double(Config.broadcastChatRateCap)
    @State private var chatMentionsOnly: Bool = Config.broadcastChatMentionsOnly

    // Camera
    @State private var cameraResolution: String = Config.cameraResolution
    @State private var cameraFrameRate: Int = Config.cameraFrameRate
    @State private var showFolderPicker = false

    // Home Assistant
    @State private var haURL: String = Config.homeAssistantURL
    @State private var haToken: String = Config.homeAssistantToken

    // TTS engine preference (Additional Capabilities #1 — Kokoro on-device tier)
    @State private var ttsEnginePreference: TTSEnginePreference = Config.ttsEnginePreference

    // iOS Voice
    @State private var iosVoiceId: String = Config.iosTTSVoiceId
    private var iosVoices: [AVSpeechSynthesisVoice] { TextToSpeechService.availableVoices() }

    /// Drives the on-device Kokoro model download + status row.
    @StateObject private var kokoroDownloader = KokoroModelDownloader()

    // Speech recognition (Additional Capabilities #8 — on-device SenseVoice ASR)
    @State private var asrEnginePreference: ASREnginePreference = Config.asrEnginePreference
    /// Drives the on-device SenseVoice model download + status row.
    @StateObject private var asrDownloader = ASRModelDownloader()

    // ElevenLabs account voices (loaded from the user's key)
    @State private var elevenLabsVoices: [TextToSpeechService.ElevenLabsVoice] = []
    @State private var elevenLabsVoicesLoading = false
    @State private var elevenLabsVoicesError: String?

    var body: some View {
        Form {
            // MARK: Voice Engine
            Section {
                Picker("Voice Engine", selection: $ttsEnginePreference) {
                    ForEach(TTSEnginePreference.allCases) { preference in
                        Text(preference.displayName).tag(preference)
                    }
                }
                .onChange(of: ttsEnginePreference) { _, newValue in
                    Config.setTTSEnginePreference(newValue)
                }
            } header: {
                Text("Voice Engine")
            } footer: {
                Text(ttsEnginePreference.detail)
            }

            // MARK: Text-to-Speech
            Section {
                SecretInputField(placeholder: "API Key", text: $elevenLabsKeyInput)
                    .onChange(of: elevenLabsKeyInput) { _, newValue in
                        Config.setElevenLabsAPIKey(newValue)
                        // Reset quota cache in case the user added credits or changed key.
                        appState.speechService.resetElevenLabsQuota()
                    }

                if elevenLabsKeyInput.isEmpty {
                    Link(destination: URL(string: "https://elevenlabs.io/app/settings/api-keys")!) {
                        HStack {
                            Label("Get API Key", systemImage: "arrow.up.right.square")
                            Spacer()
                            Text("elevenlabs.io")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if !elevenLabsKeyInput.isEmpty {
                    // Voices the user's key can actually use (public-library voices are
                    // often rejected on free accounts, so we load the account's voices).
                    if elevenLabsVoices.isEmpty {
                        Button {
                            loadElevenLabsVoices()
                        } label: {
                            Label(elevenLabsVoicesLoading ? "Loading Voices…" : "Load My ElevenLabs Voices",
                                  systemImage: "person.wave.2")
                        }
                        .disabled(elevenLabsVoicesLoading)
                    } else {
                        Picker("Voice", selection: $selectedVoice) {
                            ForEach(elevenLabsVoices) { voice in
                                Text(elevenLabsVoiceLabel(voice)).tag(voice.voiceId)
                            }
                        }
                        .onChange(of: selectedVoice) { _, newValue in
                            Config.setElevenLabsVoiceId(newValue)
                            appState.speechService.resetElevenLabsQuota()
                        }
                    }

                    // Paste any Voice ID (custom/cloned voices not in the list).
                    TextField("Voice ID", text: $selectedVoice)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.system(.body, design: .monospaced))
                        .onChange(of: selectedVoice) { _, newValue in
                            Config.setElevenLabsVoiceId(newValue.trimmingCharacters(in: .whitespacesAndNewlines))
                            appState.speechService.resetElevenLabsQuota()
                        }

                    if let elevenLabsVoicesError {
                        Text(elevenLabsVoicesError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                InfoToggle(
                    title: "Expressive Voice",
                    isOn: $emotionAwareTTSEnabled,
                    info: "Detects the emotional tone of responses (happy, calm, concerned, excited) and adjusts the voice to match. ElevenLabs voices change stability and style parameters; iOS voices adjust rate and pitch. Makes the assistant sound more natural and empathetic."
                )
                .onChange(of: emotionAwareTTSEnabled) { _, newValue in
                    Config.setEmotionAwareTTSEnabled(newValue)
                }
            } header: {
                Text("Text-to-Speech")
            } footer: {
                if elevenLabsKeyInput.isEmpty {
                    Text("Add an ElevenLabs API key for natural-sounding voices. Without one, the built-in iOS voice is used.")
                } else {
                    Text("Free ElevenLabs accounts may reject public-library voices — load voices from your account, or paste a Voice ID your key can use. The iOS voice is still used as a fallback.")
                }
            }
            .onAppear {
                if !elevenLabsKeyInput.isEmpty, elevenLabsVoices.isEmpty {
                    loadElevenLabsVoices()
                }
            }

            // MARK: iOS Voice (fallback)
            Section {
                Picker("iOS Voice", selection: $iosVoiceId) {
                    Text("Auto (best available)").tag("")
                    ForEach(iosVoices, id: \.identifier) { voice in
                        Text("\(voice.name) — \(qualityLabel(voice.quality))")
                            .tag(voice.identifier)
                    }
                }
                .onChange(of: iosVoiceId) { _, newValue in
                    Config.setIosTTSVoiceId(newValue)
                }
            } header: {
                Text("iOS Voice")
            } footer: {
                Text("Used when ElevenLabs is unavailable or quota is exhausted. Download more voices in iOS Settings → Accessibility → Spoken Content → Voices.")
            }

            // MARK: On-Device Voice (Kokoro)
            Section {
                switch kokoroDownloader.state {
                case .ready:
                    HStack {
                        Label("On-Device Model", systemImage: "cpu")
                        Spacer()
                        Text("Installed").foregroundStyle(.secondary)
                    }
                    Button("Remove Download", role: .destructive) {
                        kokoroDownloader.deleteModel()
                    }
                case .downloading(let progress):
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Downloading… \(Int(progress * 100))%")
                        ProgressView(value: progress)
                    }
                case .verifying:
                    HStack {
                        Text("Verifying…")
                        Spacer()
                        ProgressView()
                    }
                case .failed(let reason):
                    Text(reason).font(.caption).foregroundStyle(.red)
                    Button("Download Model (~185 MB)") {
                        Task { await kokoroDownloader.download() }
                    }
                case .notDownloaded:
                    Button("Download Model (~185 MB)") {
                        Task { await kokoroDownloader.download() }
                    }
                }
            } header: {
                Text("On-Device Voice (Kokoro)")
            } footer: {
                Text("A free, offline neural voice that can speak even when the app is in the background. Downloads \(KokoroModelBundle.active.displayName) (~185 MB) over Wi-Fi; until it's installed, on-device speech falls back to the iOS voice.")
            }
            .onAppear { kokoroDownloader.refreshState() }

            // MARK: Speech Recognition (Additional Capabilities #8)
            Section {
                Picker("Recognizer", selection: $asrEnginePreference) {
                    ForEach(ASREnginePreference.allCases) { preference in
                        Text(preference.displayName).tag(preference)
                    }
                }
                .onChange(of: asrEnginePreference) { _, newValue in
                    Config.setASREnginePreference(newValue)
                }

                switch asrDownloader.state {
                case .ready:
                    HStack {
                        Label("On-Device Model", systemImage: "cpu")
                        Spacer()
                        Text("Installed").foregroundStyle(.secondary)
                    }
                    Button("Remove Download", role: .destructive) {
                        asrDownloader.deleteModel()
                    }
                case .downloading(let progress):
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Downloading… \(Int(progress * 100))%")
                        ProgressView(value: progress)
                    }
                case .verifying:
                    HStack {
                        Text("Verifying…")
                        Spacer()
                        ProgressView()
                    }
                case .failed(let reason):
                    Text(reason).font(.caption).foregroundStyle(.red)
                    Button("Download Model (~240 MB)") {
                        Task { await asrDownloader.download() }
                    }
                case .notDownloaded:
                    Button("Download Model (~240 MB)") {
                        Task { await asrDownloader.download() }
                    }
                }
            } header: {
                Text("Speech Recognition")
            } footer: {
                Text("On-device \(ASRModelBundle.active.displayName) (~240 MB) transcribes offline and privately — no audio leaves the device. Until it's installed, recognition uses Apple Speech.")
            }
            .onAppear { asrDownloader.refreshState() }

            // MARK: Diarization
            Section {
                NavigationLink {
                    DiarizationSettingsView()
                } label: {
                    HStack {
                        Label("Diarization", systemImage: "person.2.wave.2")
                        Spacer()
                        Text(Config.isDiarizationConfigured ? "On" : "Off")
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("Label captions and meeting transcripts by speaker (\u{201C}who said what\u{201D}) via Deepgram. Off by default.")
            }

            // MARK: Walking Navigation
            Section {
                NavigationLink {
                    NavigationSettingsView()
                } label: {
                    Label("Walking Navigation", systemImage: "figure.walk")
                }
            } footer: {
                Text("Turn-by-turn pedestrian directions on the HUD — \u{201C}navigate to\u{2026}\u{201D}.")
            }

            // MARK: Notification Digest
            Section {
                NavigationLink {
                    DigestSettingsView()
                } label: {
                    HStack {
                        Label("Notification Digest", systemImage: "list.bullet.rectangle")
                        Spacer()
                        Text(Config.digestEnabled ? "On" : "Off")
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("\u{201C}What's new\u{201D} — one ranked glance of pending notifications on the HUD or spoken.")
            }

            // MARK: Translation
            Section {
                NavigationLink {
                    TranslationSettingsView()
                } label: {
                    HStack {
                        Label("Translation", systemImage: "globe")
                        Spacer()
                        Text(Config.isTranslationCloudConfigured ? "On" : "Off")
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("Translated captions — surrounding speech rendered in your language. Off by default.")
            }

            // MARK: Web Search
            Section {
                SecretInputField(placeholder: "Perplexity API Key", text: $perplexityKeyInput)
                    .onChange(of: perplexityKeyInput) { _, newValue in
                        Config.setPerplexityAPIKey(newValue)
                    }

                if perplexityKeyInput.isEmpty {
                    Link(destination: URL(string: "https://www.perplexity.ai/settings/api")!) {
                        HStack {
                            Label("Get API Key", systemImage: "arrow.up.right.square")
                            Spacer()
                            Text("perplexity.ai")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                SecretInputField(placeholder: "Tavily API Key", text: $tavilyKeyInput)
                    .onChange(of: tavilyKeyInput) { _, newValue in
                        Config.setTavilyAPIKey(newValue)
                    }

                if tavilyKeyInput.isEmpty {
                    Link(destination: URL(string: "https://app.tavily.com/home")!) {
                        HStack {
                            Label("Get API Key", systemImage: "arrow.up.right.square")
                            Spacer()
                            Text("tavily.com")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Web Search")
            } footer: {
                if perplexityKeyInput.isEmpty && tavilyKeyInput.isEmpty {
                    Text("Add a Perplexity or Tavily API key for AI-powered search with cited sources. Without one, DuckDuckGo is used.")
                } else if !perplexityKeyInput.isEmpty {
                    Text("Web searches use Perplexity AI with cited sources\(tavilyKeyInput.isEmpty ? "" : ", then Tavily").")
                } else {
                    Text("Web searches use Tavily with cited sources.")
                }
            }

            // MARK: Camera Quality
            Section {
                Picker("Resolution", selection: $cameraResolution) {
                    Text("360p (Low)").tag("low")
                    Text("504p (Medium)").tag("medium")
                    Text("720p (High)").tag("high")
                }
                .onChange(of: cameraResolution) { _, value in
                    Config.setCameraResolution(value)
                }

                Picker("Frame Rate", selection: $cameraFrameRate) {
                    Text("2 FPS (Battery Saver)").tag(2)
                    Text("7 FPS").tag(7)
                    Text("15 FPS (Default)").tag(15)
                    Text("24 FPS").tag(24)
                    Text("30 FPS (Max)").tag(30)
                }
                .onChange(of: cameraFrameRate) { _, value in
                    Config.setCameraFrameRate(value)
                }
            } header: {
                Text("Camera")
            } footer: {
                Text("Changes take effect next time the camera session starts. Higher settings use more battery.")
            }

            // MARK: Recording & Transcripts
            Section {
                if let folderURL = Config.transcriptFolderURL {
                    HStack {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(.secondary)
                        Text(folderURL.lastPathComponent)
                            .lineLimit(1)
                        Spacer()
                        Button("Change") {
                            showFolderPicker = true
                        }
                        .font(.caption)
                    }
                    Button("Reset to Default", role: .destructive) {
                        Config.clearTranscriptFolder()
                    }
                } else {
                    Button {
                        showFolderPicker = true
                    } label: {
                        HStack {
                            Text("Transcript Save Location")
                            Spacer()
                            Text("Documents/Transcripts")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Recording & Transcripts")
            } footer: {
                Text("Choose where transcripts are saved. Videos always save to the Glasses album in Photos. Transcripts are also accessible via the Files app.")
            }
            .fileImporter(isPresented: $showFolderPicker, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result {
                    Config.setTranscriptFolderURL(url)
                }
            }

            // MARK: Streaming
            Section {
                Picker("Platform", selection: $broadcastPlatform) {
                    Text("YouTube").tag("youtube")
                    Text("Twitch").tag("twitch")
                    Text("Kick").tag("kick")
                    Text("TikTok").tag("tiktok")
                    Text("Custom RTMP").tag("custom")
                }
                .onChange(of: broadcastPlatform) { _, platform in
                    Config.setBroadcastPlatform(platform)
                    // Pre-fill RTMP ingest URL for known platforms (persisted via the
                    // RTMP URL field's own onChange below).
                    switch platform {
                    case "youtube": broadcastRTMPURL = "rtmp://a.rtmp.youtube.com/live2"
                    case "twitch": broadcastRTMPURL = "rtmp://live.twitch.tv/app"
                    case "kick": broadcastRTMPURL = "rtmps://fa723fc1b171.global-contribute.live-video.net/app"
                    case "tiktok": broadcastRTMPURL = "rtmp://push.tiktokcdn.com/live"
                    default: break
                    }
                }

                TextField("RTMP URL", text: $broadcastRTMPURL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onChange(of: broadcastRTMPURL) { _, newValue in
                        Config.setBroadcastRTMPURL(newValue)
                    }

                SecretInputField(placeholder: "Stream Key", text: $broadcastStreamKey)
                    .onChange(of: broadcastStreamKey) { _, newValue in
                        Config.setBroadcastStreamKey(newValue)
                    }

                Picker("Orientation", selection: $broadcastOrientation) {
                    Text("Portrait").tag("portrait")
                    Text("Landscape").tag("landscape")
                }
                .onChange(of: broadcastOrientation) { _, value in
                    Config.setBroadcastOrientation(value)
                }

                Picker("Camera", selection: $broadcastSource) {
                    ForEach(BroadcastVideoSource.allCases, id: \.rawValue) { source in
                        Text(source.displayLabel).tag(source.rawValue)
                    }
                }
                .onChange(of: broadcastSource) { _, value in
                    Config.setBroadcastDefaultSource(value)
                }

                Toggle("Dual Capture (picture-in-picture)", isOn: $broadcastDualCapture)
                    .onChange(of: broadcastDualCapture) { _, value in
                        Config.setBroadcastDualCapture(value)
                    }

                // Plan CI: chat read-aloud — read-only Twitch chat spoken to the wearer.
                Toggle("Chat Read-Aloud (Twitch)", isOn: $chatReadbackEnabled)
                    .onChange(of: chatReadbackEnabled) { _, value in
                        Config.setBroadcastChatReadbackEnabled(value)
                    }
                if chatReadbackEnabled {
                    TextField("Twitch Channel", text: $chatChannel)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: chatChannel) { _, value in
                            Config.setBroadcastChatChannel(value)
                        }
                    VStack(alignment: .leading) {
                        Text("Spoken messages per minute: \(Int(chatRateCap))")
                        Slider(value: $chatRateCap, in: 2...15, step: 1)
                            .onChange(of: chatRateCap) { _, value in
                                Config.setBroadcastChatRateCap(Int(value))
                            }
                    }
                    Toggle("Mentions Only", isOn: $chatMentionsOnly)
                        .onChange(of: chatMentionsOnly) { _, value in
                            Config.setBroadcastChatMentionsOnly(value)
                        }
                }
            } header: {
                Text("Live Streaming")
            } footer: {
                if broadcastRTMPURL.isEmpty || broadcastStreamKey.isEmpty {
                    Text("Enter both the RTMP URL and stream key from your streaming platform to go live.")
                } else {
                    Text("Stream what your glasses see directly to \(broadcastPlatform.capitalized).")
                }
            }

            // MARK: Home Assistant
            Section {
                TextField("HA URL (e.g. http://192.168.1.100:8123)", text: $haURL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .onChange(of: haURL) { _, newValue in
                        Config.setHomeAssistantURL(newValue)
                    }

                SecretInputField(placeholder: "Long-Lived Access Token", text: $haToken)
                    .onChange(of: haToken) { _, newValue in
                        Config.setHomeAssistantToken(newValue)
                    }
            } header: {
                Text("Home Assistant")
            } footer: {
                Text("Direct REST API control — works alongside or instead of HomeKit. Generate a token in HA → Profile → Security → Long-Lived Access Tokens.")
            }
        }
        .navigationTitle("Services")
    }

    private func qualityLabel(_ quality: AVSpeechSynthesisVoiceQuality) -> String {
        switch quality {
        case .premium:  return "Premium"
        case .enhanced: return "Enhanced"
        default:        return "Default"
        }
    }

    private func loadElevenLabsVoices() {
        let apiKey = elevenLabsKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty, !elevenLabsVoicesLoading else { return }
        elevenLabsVoicesLoading = true
        elevenLabsVoicesError = nil
        Task {
            do {
                let voices = try await TextToSpeechService.fetchElevenLabsVoices(apiKey: apiKey)
                await MainActor.run {
                    elevenLabsVoices = voices
                    elevenLabsVoicesLoading = false
                    elevenLabsVoicesError = voices.isEmpty ? "No voices returned for this API key." : nil
                    // If the saved voice isn't in the account list, default to the first.
                    if !voices.isEmpty, !voices.contains(where: { $0.voiceId == selectedVoice }),
                       let first = voices.first {
                        selectedVoice = first.voiceId
                        Config.setElevenLabsVoiceId(first.voiceId)
                        appState.speechService.resetElevenLabsQuota()
                    }
                }
            } catch {
                await MainActor.run {
                    elevenLabsVoicesLoading = false
                    elevenLabsVoicesError = "Could not load voices: \(error.localizedDescription)"
                }
            }
        }
    }

    private func elevenLabsVoiceLabel(_ voice: TextToSpeechService.ElevenLabsVoice) -> String {
        if let category = voice.category, !category.isEmpty {
            return "\(voice.name) — \(category)"
        }
        return voice.name
    }
}
