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

    // iOS Voice
    @State private var iosVoiceId: String = Config.iosTTSVoiceId
    private var iosVoices: [AVSpeechSynthesisVoice] { TextToSpeechService.availableVoices() }

    var body: some View {
        Form {
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

                Picker("Voice", selection: $selectedVoice) {
                    // Female voices
                    Text("Rachel — calm, American").tag("21m00Tcm4TlvDq8ikWAM")
                    Text("Sarah — soft, American").tag("EXAVITQu4vr4xnSDxMaL")
                    Text("Matilda — warm, American").tag("XrExE9yKIg1WjnnlVkGX")
                    Text("Emily — calm, American").tag("LcfcDJNUP1GQjkzn1xUU")
                    Text("Charlotte — English-Swedish").tag("XB0fDUnXU5powFXDhCwa")
                    Text("Alice — confident, British").tag("Xb7hH8MSUJpSbSDYk0k2")
                    Text("Lily — raspy, British").tag("pFZP5JQG7iQjIQuC4Bku")
                    Text("Dorothy — pleasant, British").tag("ThT5KcBeYPX3keUQqHPh")
                    Text("Serena — pleasant, American").tag("pMsXgVXv3BLzUgSXRplE")
                    Text("Nicole — whisper, American").tag("piTKgcLEGmPE4e6mEKli")
                    // Male voices
                    Text("Brian — deep, American").tag("nPczCjzI2devNBz1zQrb")
                    Text("Adam — deep, American").tag("pNInz6obpgDQGcFmaJgB")
                    Text("Daniel — deep, British").tag("onwK4e9ZLuTAKqWW03F9")
                    Text("George — raspy, British").tag("JBFqnCBsd6RMkjVDRZzb")
                    Text("Chris — casual, American").tag("iP95p4xoKVk53GoZ742B")
                    Text("Charlie — casual, Australian").tag("IKne3meq5aSn9XLyUdCD")
                    Text("James — calm, Australian").tag("ZQe5CZNOzWyzPSCn5a3c")
                    Text("Dave — conversational, British").tag("CYw3kZ02Hs0563khs1Fj")
                    Text("Drew — well-rounded, American").tag("29vD33N1CtxCmqQRPOHJ")
                    Text("Callum — hoarse, American").tag("N2lVS1w4EtoT3dr4eOWO")
                    Text("Bill — strong, American").tag("pqHfZKP75CvOlQylNhV4")
                    Text("Fin — Irish").tag("D38z5RcWu1voky8WS1ja")
                    Text("Liam — American").tag("TX3LPaxmHKxFdv7VOQHJ")
                    Text("Thomas — calm, American").tag("GBv7mTt0atIp3Br8iCZE")
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
}
