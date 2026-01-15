import SwiftUI
import MWDATCore

@main
struct ClaudeGlassesApp: App {
    @StateObject private var appState = AppState()

    init() {
        configureWearables()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
        }
    }

    private func configureWearables() {
        do {
            try Wearables.configure()
            print("Meta Wearables SDK configured successfully")
        } catch {
            print("Failed to configure Wearables SDK: (error)")
        }
    }
}

/// Global application state
@MainActor
class AppState: ObservableObject {
    @Published var isConnected: Bool = false
    @Published var isListening: Bool = false
    @Published var currentTranscription: String = ""
    @Published var lastResponse: String = ""
    @Published var errorMessage: String?

    // Service references
    let glassesService = GlassesConnectionService()
    let wakeWordService = WakeWordService()
    let transcriptionService = TranscriptionService()
    let claudeService = ClaudeAPIService()
    let speechService = TextToSpeechService()

    init() {
        setupServiceCallbacks()
    }

    private func setupServiceCallbacks() {
        // Wire up the audio pipeline
        wakeWordService.onWakeWordDetected = { [weak self] in
            Task { @MainActor in
                await self?.handleWakeWordDetected()
            }
        }

        transcriptionService.onTranscriptionComplete = { [weak self] text in
            Task { @MainActor in
                await self?.handleTranscription(text)
            }
        }
    }

    func handleWakeWordDetected() async {
        print("Wake word detected! Starting transcription...")
        isListening = true
        speechService.playAcknowledgmentTone()
        transcriptionService.startRecording()
    }

    func handleTranscription(_ text: String) async {
        currentTranscription = text
        isListening = false
        print("Transcription: (text)")

        do {
            let response = try await claudeService.sendMessage(text)
            lastResponse = response
            print("Claude: (response)")
            await speechService.speak(response)
        } catch {
            errorMessage = "Failed to get response: (error.localizedDescription)"
            await speechService.speak("Sorry, I encountered an error.")
        }
    }
}
