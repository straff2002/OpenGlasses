import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

/// Sub-settings view for optional service integrations.
/// Accessed via NavigationLink from the main SettingsView.
struct ServicesSettingsView: View {
    @ObservedObject var appState: AppState

    // Text-to-Speech
    @Binding var elevenLabsKeyInput: String
    @Binding var selectedVoice: String
    @Binding var emotionAwareTTSEnabled: Bool

    // Web Search
    @Binding var perplexityKeyInput: String

    // Live Streaming
    @Binding var broadcastPlatform: String
    @Binding var broadcastRTMPURL: String
    @Binding var broadcastStreamKey: String

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

    /// Whether the on-device Kokoro model bundle is installed.
    private var kokoroModelInstalled: Bool { KokoroModelStore.shared.isModelPresent }

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
                SecureField("API Key", text: $elevenLabsKeyInput)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

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
                HStack {
                    Label("On-Device Model", systemImage: "cpu")
                    Spacer()
                    Text(kokoroModelInstalled ? "Installed" : "Not downloaded")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("On-Device Voice (Kokoro)")
            } footer: {
                Text("A free, offline neural voice that can speak even when the app is in the background. The model (\(KokoroModelBundle.active.displayName), about 185 MB) downloads on first use; until then, on-device speech falls back to the iOS voice.")
            }

            // MARK: Web Search
            Section {
                SecureField("API Key", text: $perplexityKeyInput)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

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
            } header: {
                Text("Web Search")
            } footer: {
                if perplexityKeyInput.isEmpty {
                    Text("Add a Perplexity API key for AI-powered search with cited sources. Without one, DuckDuckGo is used.")
                } else {
                    Text("Web searches use Perplexity AI with cited sources.")
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
                    // Pre-fill RTMP ingest URL for known platforms
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

                SecureField("Stream Key", text: $broadcastStreamKey)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
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

                SecureField("Long-Lived Access Token", text: $haToken)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
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
