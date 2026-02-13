import SwiftUI
import AVKit

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var showSettings = false
    @State private var apiKeyInput = Config.anthropicAPIKey
    @State private var elevenLabsKeyInput = Config.elevenLabsAPIKey
    @State private var selectedVoice = Config.elevenLabsVoiceId
    @State private var wakeWordInput = Config.wakePhrase
    @State private var wakeWordAltsInput = Config.alternativeWakePhrases.joined(separator: ", ")
    @State private var selectedPreset = Config.wakePhrase

    // Muted colour palette
    private let mutedRed = Color(red: 0.75, green: 0.30, blue: 0.30)
    private let mutedGreen = Color(red: 0.35, green: 0.62, blue: 0.45)
    private let mutedBlue = Color(red: 0.38, green: 0.52, blue: 0.68)
    private let mutedOrange = Color(red: 0.78, green: 0.56, blue: 0.32)
    private let mutedGray = Color(red: 0.55, green: 0.55, blue: 0.58)
    private let cardBg = Color(.systemGray6)

    private let wakeWordPresets = [
        "hey claude", "hey jarvis", "hey rayban", "hey computer", "hey assistant"
    ]

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    // Title
                    Text("OpenGlasses")
                        .font(.largeTitle.weight(.bold))
                        .foregroundColor(.primary)
                        .padding(.top, 8)

                    // Intro video
                    introVideo
                        .frame(height: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .padding(.horizontal)

                    // Connection status
                    HStack(spacing: 6) {
                        Circle()
                            .fill(appState.isConnected ? mutedGreen : mutedRed.opacity(0.6))
                            .frame(width: 10, height: 10)
                        Text(appState.isConnected ? "Glasses Connected" : "Glasses Disconnected")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    // Main status indicator
                    VStack(spacing: 12) {
                        Image(systemName: statusIcon)
                            .font(.system(size: 48))
                            .foregroundColor(statusColor)
                            .symbolEffect(.pulse, isActive: appState.isListening)

                        Text(statusText)
                            .font(.title3)
                            .fontWeight(.medium)
                            .foregroundColor(.primary.opacity(0.8))

                        if appState.isListening {
                            Text("Say \"Goodbye\" to end")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 8)

                    // Stop button — visible when speaking
                    if appState.speechService.isSpeaking {
                        Button {
                            appState.stopSpeakingAndResume()
                        } label: {
                            Label("Stop", systemImage: "stop.fill")
                                .font(.subheadline.weight(.medium))
                                .frame(width: 120)
                                .padding(.vertical, 10)
                                .background(mutedRed)
                                .foregroundColor(.white)
                                .cornerRadius(10)
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }

                    // Transcription display
                    if !appState.currentTranscription.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("You said:")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text(appState.currentTranscription)
                                .font(.callout)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(cardBg)
                                .cornerRadius(10)
                        }
                        .padding(.horizontal)
                    }

                    // Response display
                    if !appState.lastResponse.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Claude:")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text(appState.lastResponse)
                                .font(.callout)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(cardBg)
                                .cornerRadius(10)
                        }
                        .padding(.horizontal)
                    }

                    // Error message
                    if let error = appState.errorMessage {
                        Text(error)
                            .font(.caption2)
                            .foregroundColor(mutedRed)
                            .padding(.horizontal)
                    }

                    // Action buttons
                    VStack(spacing: 10) {
                        // Test mic button
                        Button {
                            Task {
                                do {
                                    try await appState.wakeWordService.startListening()
                                } catch {
                                    appState.errorMessage = error.localizedDescription
                                }
                            }
                        } label: {
                            Label(
                                appState.wakeWordService.isListening ? "Listening..." : "Test Microphone",
                                systemImage: "mic.fill"
                            )
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(appState.wakeWordService.isListening ? mutedOrange.opacity(0.15) : mutedOrange)
                            .foregroundColor(appState.wakeWordService.isListening ? mutedOrange : .white)
                            .cornerRadius(12)
                        }
                        .disabled(appState.wakeWordService.isListening)

                        // Connect button
                        Button {
                            Task {
                                await appState.glassesService.connect()
                            }
                        } label: {
                            Label(
                                appState.isConnected ? "Connected" : "Connect Glasses",
                                systemImage: appState.isConnected ? "eyeglasses" : "link"
                            )
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(appState.isConnected ? mutedGreen.opacity(0.15) : mutedBlue)
                            .foregroundColor(appState.isConnected ? mutedGreen : .white)
                            .cornerRadius(12)
                        }
                        .disabled(appState.isConnected)
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 16)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gear")
                            .foregroundColor(mutedGray)
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                settingsSheet
            }
            .animation(.easeInOut(duration: 0.25), value: appState.speechService.isSpeaking)
        }
    }

    // MARK: - Intro Video

    private var introVideo: some View {
        VideoPlayerView()
    }

    // MARK: - Settings Sheet

    private var settingsSheet: some View {
        NavigationView {
            Form {
                Section("Wake Word") {
                    Picker("Preset", selection: $selectedPreset) {
                        Text("Hey Claude").tag("hey claude")
                        Text("Hey Jarvis").tag("hey jarvis")
                        Text("Hey Rayban").tag("hey rayban")
                        Text("Hey Computer").tag("hey computer")
                        Text("Hey Assistant").tag("hey assistant")
                        if !wakeWordPresets.contains(wakeWordInput.lowercased()) && !wakeWordInput.isEmpty {
                            Text("Custom: \(wakeWordInput)").tag(wakeWordInput.lowercased())
                        }
                    }
                    .onChange(of: selectedPreset) { _, newValue in
                        wakeWordInput = newValue
                        let defaults = Config.defaultAlternativesForPhrase(newValue)
                        wakeWordAltsInput = defaults.joined(separator: ", ")
                    }

                    TextField("Custom wake phrase", text: $wakeWordInput)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: wakeWordInput) { _, newValue in
                            if !wakeWordPresets.contains(newValue.lowercased()) {
                                selectedPreset = newValue.lowercased()
                            }
                        }

                    if wakeWordInput.split(separator: " ").count < 2 {
                        Text("Use at least 2 words (e.g. \"hey jarvis\") to avoid false triggers")
                            .font(.caption)
                            .foregroundColor(mutedOrange)
                    }

                    TextField("Alternative spellings (comma separated)", text: $wakeWordAltsInput)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.caption)

                    Text("Alternatives catch misrecognitions, e.g. \"hey cloud\" for \"hey claude\"")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("Claude API (Required)") {
                    SecureField("sk-ant-...", text: $apiKeyInput)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Text("Get your key at console.anthropic.com")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("ElevenLabs Voice (Optional)") {
                    SecureField("ElevenLabs API key", text: $elevenLabsKeyInput)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    Picker("Voice", selection: $selectedVoice) {
                        Text("Rachel (warm female)").tag("21m00Tcm4TlvDq8ikWAM")
                        Text("Bella (young female)").tag("EXAVITQu4vr4xnSDxMaL")
                        Text("Adam (deep male)").tag("pNInz6obpgDQGcFmaJgB")
                        Text("Antoni (friendly male)").tag("ErXwobaYiN019PkySvjV")
                        Text("Daniel (British male)").tag("onwK4e9ZLuTAKqWW03F9")
                    }

                    Text("Free tier: 10k chars/month at elevenlabs.io")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if elevenLabsKeyInput.isEmpty {
                        Text("Without ElevenLabs, iOS built-in voice is used")
                            .font(.caption)
                            .foregroundColor(mutedOrange)
                    }
                }

            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { saveSettings() }
                }
            }
        }
    }

    // MARK: - Status Helpers

    private var statusIcon: String {
        if appState.isListening {
            return "waveform.circle.fill"
        } else if appState.speechService.isSpeaking {
            return "speaker.wave.3.fill"
        } else {
            return "mic.circle"
        }
    }

    private var statusColor: Color {
        if appState.isListening {
            return mutedBlue
        } else if appState.speechService.isSpeaking {
            return mutedOrange
        } else {
            return mutedGray
        }
    }

    private var statusText: String {
        if appState.isListening {
            return "Listening..."
        } else if appState.speechService.isSpeaking {
            return "Speaking..."
        } else {
            return "An open brain for Meta Glasses"
        }
    }

    // MARK: - Save Settings

    private func saveSettings() {
        // Save wake word
        Config.setWakePhrase(wakeWordInput)
        let alts = wakeWordAltsInput
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        Config.setAlternativeWakePhrases(alts)

        // Save API keys
        Config.setAnthropicAPIKey(apiKeyInput)
        Config.setElevenLabsAPIKey(elevenLabsKeyInput)
        Config.setElevenLabsVoiceId(selectedVoice)
        showSettings = false

        // Restart wake word listener to pick up new phrase
        Task {
            appState.wakeWordService.stopListening()
            try? await Task.sleep(nanoseconds: 300_000_000)
            try? await appState.wakeWordService.startListening()
        }
    }
}

// MARK: - Video Player

struct VideoPlayerView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.showsPlaybackControls = false
        controller.videoGravity = .resizeAspectFill

        if let url = Bundle.main.url(forResource: "intro", withExtension: "mp4") {
            let item = AVPlayerItem(url: url)
            let player = AVPlayer(playerItem: item)
            player.isMuted = true
            // Prevent auto-release of the last frame — keeps it visible when playback ends
            player.actionAtItemEnd = .pause
            controller.player = player
            player.play()
        }

        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {}
}
