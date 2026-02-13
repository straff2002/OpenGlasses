import SwiftUI
import MWDATCore

@main
struct OpenGlassesApp: App {
    @StateObject private var appState = AppState()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        configureWearables()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .onOpenURL { url in
                    print("🔗 Received URL callback: \(url)")
                    Task {
                        do {
                            let result = try await Wearables.shared.handleUrl(url)
                            print("✅ handleUrl result: \(result)")
                        } catch {
                            print("❌ handleUrl failed: \(error)")
                        }
                    }
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                print("📱 App moved to background — keeping audio alive")
                // Audio session stays active thanks to UIBackgroundModes: audio
                // The wake word listener keeps running because AVAudioEngine
                // continues in background with an active audio session
            case .active:
                print("📱 App became active")
                // If wake word listener died in background, restart it
                Task {
                    if !appState.wakeWordService.isListening && !appState.isListening {
                        print("🎤 Restarting wake word listener after foreground...")
                        // Re-configure audio session in case Bluetooth route changed
                        appState.wakeWordService.reconfigureAudioSessionIfNeeded()
                        // Small delay for route to stabilize after foregrounding
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        try? await appState.wakeWordService.startListening()
                    }
                }
            case .inactive:
                break
            @unknown default:
                break
            }
        }
    }

    private func configureWearables() {
        do {
            try Wearables.configure()
            print("✅ Meta Wearables SDK configured successfully")
            let state = Wearables.shared.registrationState
            print("📋 Registration state: \(state)")
        } catch {
            print("❌ Failed to configure Wearables SDK: \(error)")
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

    let glassesService = GlassesConnectionService()
    let wakeWordService = WakeWordService()
    let transcriptionService = TranscriptionService()
    let claudeService = ClaudeAPIService()
    let speechService = TextToSpeechService()
    let cameraService = CameraService()

    private var cancellables: [Any] = []
    private var isProcessing: Bool = false
    private var hasEverRegistered: Bool = false
    private var inConversation: Bool = false

    init() {
        // Share the audio engine so transcription works in background
        transcriptionService.sharedAudioEngineProvider = wakeWordService
        setupServiceCallbacks()
        observeGlassesConnection()
        autoConnectGlasses()
        autoStartListening()
    }

    private func setupServiceCallbacks() {
        wakeWordService.onWakeWordDetected = { [weak self] in
            Task { @MainActor in
                await self?.handleWakeWordDetected()
            }
        }

        wakeWordService.onStopCommand = { [weak self] in
            Task { @MainActor in
                self?.stopSpeakingAndResume()
            }
        }

        transcriptionService.onTranscriptionComplete = { [weak self] text in
            Task { @MainActor in
                await self?.handleTranscription(text)
            }
        }

        // When user doesn't say anything after Claude responds, end conversation
        transcriptionService.onSilenceTimeout = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                print("💤 User silent — ending conversation, back to wake word")
                await self.returnToWakeWord()
            }
        }
    }

    private func observeGlassesConnection() {
        // Monitor devices list
        let deviceToken = Wearables.shared.addDevicesListener { [weak self] deviceIds in
            Task { @MainActor in
                guard let self else { return }
                print("📋 Devices changed: \(deviceIds)")
                if !deviceIds.isEmpty {
                    self.hasEverRegistered = true
                    self.isConnected = true
                }
            }
        }
        cancellables.append(deviceToken)

        // Monitor registration state
        // Registration bounces between states 0-3, so once we see state 3,
        // consider connected for the session (don't disconnect on state changes)
        let regToken = Wearables.shared.addRegistrationStateListener { [weak self] newState in
            Task { @MainActor in
                guard let self else { return }
                print("📋 Registration state changed: \(newState.rawValue)")
                if newState.rawValue >= 2 {
                    // State 2 = registering, 3 = registered — both mean we're talking to glasses
                    self.hasEverRegistered = true
                    self.isConnected = true
                }
            }
        }
        cancellables.append(regToken)

        // Check initial state
        let initialState = Wearables.shared.registrationState
        print("📋 Initial registration state: \(initialState.rawValue)")
        if initialState.rawValue >= 2 {
            hasEverRegistered = true
            isConnected = true
            print("📋 Already registered on launch")
        }
    }

    /// Auto-connect to glasses on launch — no need to press Connect button
    /// Only calls startRegistration() if we haven't successfully registered before,
    /// so it won't open the Meta AI app on every launch.
    private func autoConnectGlasses() {
        Task {
            // Small delay to let SDK initialize
            try? await Task.sleep(nanoseconds: 500_000_000)  // 0.5s
            let state = Wearables.shared.registrationState
            let hasRegisteredBefore = UserDefaults.standard.bool(forKey: "hasRegisteredWithMeta")
            print("📋 Auto-connect check: state=\(state.rawValue), registeredBefore=\(hasRegisteredBefore)")

            if state.rawValue >= 2 {
                // Already registered this session
                self.hasEverRegistered = true
                self.isConnected = true
                UserDefaults.standard.set(true, forKey: "hasRegisteredWithMeta")
            } else if hasRegisteredBefore {
                // Registered before — SDK should reconnect on its own via Bluetooth
                // Wait a few seconds for it to happen, then mark connected if state changes
                print("📋 Previously registered — waiting for SDK to reconnect...")
                try? await Task.sleep(nanoseconds: 3_000_000_000)  // 3s
                let newState = Wearables.shared.registrationState
                if newState.rawValue >= 2 {
                    self.hasEverRegistered = true
                    self.isConnected = true
                } else {
                    print("📋 SDK didn't auto-reconnect (state=\(newState.rawValue)) — user can press Connect")
                }
            } else {
                // First time — need to register (this opens Meta AI app)
                print("📋 First-time registration...")
                do {
                    try await Wearables.shared.startRegistration()
                    let newState = Wearables.shared.registrationState
                    print("📋 Registration result: state=\(newState.rawValue)")
                    if newState.rawValue >= 2 {
                        self.hasEverRegistered = true
                        self.isConnected = true
                        UserDefaults.standard.set(true, forKey: "hasRegisteredWithMeta")
                    }
                } catch {
                    print("📋 Registration failed: \(error) — user can press Connect")
                }
            }
        }
    }

    /// Auto-start wake word listener on app launch (don't wait for "Connect" or "Test Mic")
    private func autoStartListening() {
        Task {
            // Small delay to let the app finish initializing
            try? await Task.sleep(nanoseconds: 1_000_000_000)  // 1s
            if !wakeWordService.isListening {
                print("🎤 Auto-starting wake word listener...")
                do {
                    try await wakeWordService.startListening()
                    print("✅ Wake word listener auto-started")
                } catch {
                    print("⚠️ Auto-start failed: \(error.localizedDescription)")
                    // Not fatal — user can still use Test Microphone button
                }
            }
        }
    }

    func stopSpeakingAndResume() {
        print("🛑 User tapped stop")
        speechService.stopSpeaking()
        isProcessing = false
        // Stay in conversation — listen for follow-up right away
        if inConversation {
            print("💬 Listening for follow-up after stop...")
            isListening = true
            transcriptionService.startRecording()
        } else {
            Task { await returnToWakeWord() }
        }
    }

    func handleWakeWordDetected() async {
        print("🎤 Wake word detected! Starting conversation...")
        inConversation = true
        isListening = true
        speechService.playAcknowledgmentTone()
        transcriptionService.startRecording()
    }

    // MARK: - Voice Commands

    private static let stopPhrases = ["stop", "nevermind", "never mind", "cancel", "shut up", "be quiet", "quiet"]
    private static let goodbyePhrases = ["goodbye", "good bye", "bye", "that's all", "thats all",
                                          "thanks claude", "thank you claude", "i'm done", "im done",
                                          "end conversation", "go to sleep"]
    private static let photoPhrases = ["take a picture", "take a photo", "take photo", "take picture",
                                        "capture photo", "snap a photo", "snap a picture", "take a snap"]

    private func isStopCommand(_ text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.stopPhrases.contains(where: { lower == $0 || lower.hasPrefix($0 + " ") || lower.hasSuffix(" " + $0) })
    }

    private func isGoodbyeCommand(_ text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.goodbyePhrases.contains(where: { lower.contains($0) })
    }

    private func isPhotoCommand(_ text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.photoPhrases.contains(where: { lower.contains($0) })
    }

    func handleTranscription(_ text: String) async {
        guard !isProcessing else {
            print("⚠️ Already processing, ignoring: \(text)")
            return
        }

        currentTranscription = text
        isListening = false
        errorMessage = nil
        speechService.playEndListeningTone()
        print("📝 Transcription: \(text)")

        // Voice command: "stop" — interrupt TTS, stay in conversation
        if isStopCommand(text) {
            print("🛑 Voice command: stop")
            speechService.stopSpeaking()
            if inConversation {
                print("💬 Stopped — listening for next question...")
                isListening = true
                transcriptionService.startRecording()
            } else {
                await returnToWakeWord()
            }
            return
        }

        // Voice command: "goodbye" — end conversation, back to wake word
        if isGoodbyeCommand(text) {
            print("👋 Voice command: goodbye")
            speechService.stopSpeaking()
            inConversation = false
            lastResponse = "Goodbye!"
            await speechService.speak("Goodbye!")
            await returnToWakeWord()
            return
        }

        // Voice command: "take a picture" — capture photo from glasses camera
        if isPhotoCommand(text) {
            print("📸 Voice command: take a picture")
            isProcessing = true
            await speechService.speak("Taking a picture.")
            do {
                let photoData = try await cameraService.capturePhoto()
                cameraService.saveToPhotoLibrary(photoData)
                lastResponse = "Photo saved!"
                await speechService.speak("Got it! Photo saved to your camera roll.")
            } catch {
                print("📸 Photo capture failed: \(error)")
                lastResponse = "Photo failed: \(error.localizedDescription)"
                await speechService.speak("Sorry, I couldn't take a photo. \(error.localizedDescription)")
            }
            isProcessing = false
            if inConversation {
                isListening = true
                transcriptionService.startRecording()
            } else {
                await returnToWakeWord()
            }
            return
        }

        // Normal message — send to Claude
        isProcessing = true

        do {
            let response = try await claudeService.sendMessage(text)
            lastResponse = response
            print("🤖 Claude: \(response)")

            // Start wake word listener during TTS so user can say "stop"
            startStopListener()
            await speechService.speak(response)
            stopStopListener()
        } catch {
            errorMessage = "Failed to get response: \(error.localizedDescription)"
            await speechService.speak("Sorry, I encountered an error.")
        }

        // After responding, stay in conversation — listen for follow-up
        isProcessing = false
        if inConversation {
            print("💬 Continuing conversation — listening for follow-up...")
            isListening = true
            transcriptionService.startRecording()
        } else {
            await returnToWakeWord()
        }
    }

    /// Start wake word listener in "stop detection" mode during TTS playback
    /// Only starts if the audio engine is already running (don't create a new one during TTS)
    private func startStopListener() {
        wakeWordService.listenForStop = true
        // Only try if the engine is already alive — don't create a new one during playback
        if wakeWordService.getAudioEngine()?.isRunning == true {
            Task {
                do {
                    try await wakeWordService.startListening()
                    print("🎤 Stop listener active during TTS")
                } catch {
                    print("⚠️ Could not start stop listener: \(error)")
                }
            }
        } else {
            print("🎤 No running engine for stop listener — skipping")
        }
    }

    /// Stop the stop-detection listener before resuming normal flow
    /// Uses pauseRecognition to keep the engine alive
    private func stopStopListener() {
        wakeWordService.listenForStop = false
        wakeWordService.pauseRecognitionPublic()
    }

    private func returnToWakeWord() async {
        isListening = false
        inConversation = false
        wakeWordService.listenForStop = false
        speechService.playDisconnectTone()
        do {
            try await wakeWordService.startListening()
            print("✅ Wake word restarted")
        } catch {
            print("❌ Failed to restart listener: \(error)")
            errorMessage = "Tap Test Microphone to restart"
        }
    }
}
