import Foundation
import AVFoundation
import Speech

/// Handles wake word detection using iOS Speech Recognition
/// Listens for "Hey Claude" to trigger voice queries
@MainActor
class WakeWordService: NSObject, ObservableObject {
    @Published var isListening: Bool = false
    @Published var lastDetectionTime: Date?
    @Published var errorMessage: String?
    @Published var debugTranscript: String = ""

    var onWakeWordDetected: (() -> Void)?
    var onStopCommand: (() -> Void)?

    private var audioEngine: AVAudioEngine?
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioSessionConfigured: Bool = false
    /// When true, also listen for "stop" commands (used during TTS playback)
    var listenForStop: Bool = false
    /// Track whether we already fired a stop for this listening session
    private var stopFired: Bool = false
    /// Track whether wake word already fired for this recognition session (prevent double-fire)
    private var wakeWordFired: Bool = false

    /// Optional callback to forward audio buffers to TranscriptionService
    private var audioBufferForwarder: (@Sendable (AVAudioPCMBuffer) -> Void)?

    private var wakePhrase: String { Config.wakePhrase }
    private var alternativePhrases: [String] { Config.alternativeWakePhrases }
    private let stopPhrases = ["stop", "stop stop"]

    /// Dynamic stop phrases that include the current wake word
    private var allStopPhrases: [String] {
        let base = wakePhrase.replacingOccurrences(of: "hey ", with: "")  // e.g. "claude"
        return stopPhrases + ["\(wakePhrase) stop", "\(base) stop"]
    }

    override init() {
        super.init()
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }

    /// Configure the shared audio session once — call before first use
    func configureAudioSession() {
        guard !audioSessionConfigured else { return }
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .allowBluetooth, .defaultToSpeaker])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            audioSessionConfigured = true

            let route = audioSession.currentRoute
            for input in route.inputs {
                print("🎤 Audio input: \(input.portName) (\(input.portType.rawValue))")
            }
            for output in route.outputs {
                print("🔊 Audio output: \(output.portName) (\(output.portType.rawValue))")
            }
            print("🎤 Audio session configured: .playAndRecord with Bluetooth")

            // Handle audio interruptions (phone calls, Siri, etc.)
            NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: audioSession,
                queue: nil
            ) { [weak self] notification in
                Task { @MainActor in
                    self?.handleAudioInterruption(notification)
                }
            }

            // Handle audio route changes (Bluetooth disconnect/reconnect)
            NotificationCenter.default.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: audioSession,
                queue: nil
            ) { [weak self] notification in
                Task { @MainActor in
                    self?.handleRouteChange(notification)
                }
            }
        } catch {
            print("🎤 Failed to configure audio session: \(error)")
        }
    }

    private func handleAudioInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            print("🎤 Audio interrupted (phone call, Siri, etc.)")
            stopListening()
        case .ended:
            print("🎤 Audio interruption ended — restarting listener")
            // Re-activate audio session and restart
            try? AVAudioSession.sharedInstance().setActive(true)
            Task { try? await startListening() }
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }

        let route = AVAudioSession.sharedInstance().currentRoute
        let inputName = route.inputs.first?.portName ?? "none"
        let outputName = route.outputs.first?.portName ?? "none"
        print("🎤 Audio route changed: reason=\(reason.rawValue) input=\(inputName) output=\(outputName)")

        switch reason {
        case .oldDeviceUnavailable:
            // Bluetooth device disconnected — kill the engine so it's recreated fresh
            print("🎤 Bluetooth device disconnected — stopping audio engine")
            cleanupAudioEngine()
            isListening = false
        case .newDeviceAvailable:
            // New device connected (glasses back on) — restart with fresh engine
            print("🎤 New audio device available — restarting with fresh engine")
            cleanupAudioEngine()
            isListening = false
            Task {
                // Small delay for the new route to stabilize
                try? await Task.sleep(nanoseconds: 500_000_000)
                // Re-configure audio session to pick up new route
                audioSessionConfigured = false
                configureAudioSession()
                try? await startListening()
            }
        case .override, .categoryChange:
            // Check if format is still valid — if not, rebuild engine
            if let engine = audioEngine {
                let format = engine.inputNode.outputFormat(forBus: 0)
                if format.sampleRate == 0 || format.channelCount == 0 {
                    print("🎤 Audio format invalid after route change — rebuilding engine")
                    cleanupAudioEngine()
                    isListening = false
                }
            }
        default:
            break
        }
    }

    func startListening() async throws {
        guard !isListening else { return }
        stopFired = false
        wakeWordFired = false

        let hasPermission = await requestPermissions()
        guard hasPermission else {
            errorMessage = "Speech recognition permission denied"
            throw WakeWordError.microphonePermissionDenied
        }

        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            errorMessage = "Speech recognition not available"
            throw WakeWordError.configurationError("Speech recognizer not available")
        }

        // Ensure audio session is configured
        configureAudioSession()

        // Retry up to 3 times with increasing delay if audio engine fails
        var lastError: Error?
        for attempt in 1...3 {
            do {
                try startRecognition()
                isListening = true
                print("🎤 Wake word listening (attempt \(attempt))")
                return
            } catch {
                lastError = error
                print("🎤 WakeWord: attempt \(attempt) failed: \(error.localizedDescription)")
                cleanupAudioEngine()
                let delay = UInt64(attempt) * 500_000_000
                try? await Task.sleep(nanoseconds: delay)
            }
        }
        throw lastError ?? WakeWordError.configurationError("Failed to start after 3 attempts")
    }

    func stopListening() {
        cleanupAudioEngine()
        isListening = false
    }

    func resumeListening() {
        guard !isListening else { return }
        Task { try? await startListening() }
    }

    // MARK: - Shared Audio Engine (for TranscriptionService)

    /// Get the current audio engine (for shared use by TranscriptionService)
    func getAudioEngine() -> AVAudioEngine? {
        return audioEngine
    }

    /// Set a callback to forward audio buffers to another service (e.g. TranscriptionService)
    func setAudioBufferForwarder(_ forwarder: (@Sendable (AVAudioPCMBuffer) -> Void)?) {
        audioBufferForwarder = forwarder
    }

    private func cleanupAudioEngine() {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        if let engine = audioEngine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        audioEngine = nil
    }

    private func startRecognition() throws {
        // Cancel any existing recognition task
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else {
            throw WakeWordError.configurationError("Unable to create recognition request")
        }

        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.requiresOnDeviceRecognition = false
        recognitionRequest.taskHint = .search  // Short phrase detection
        // Boost recognition of the wake phrase and its alternatives
        let allPhrases = [wakePhrase] + alternativePhrases
        recognitionRequest.contextualStrings = allPhrases
        print("🎤 Wake phrase: '\(wakePhrase)', alternatives: \(alternativePhrases), contextualStrings: \(allPhrases)")

        // Reuse existing engine if it's already running AND has a valid format
        if let engine = audioEngine, engine.isRunning {
            let format = engine.inputNode.outputFormat(forBus: 0)
            if format.sampleRate > 0 && format.channelCount > 0 {
                print("🎤 Reusing existing audio engine")
            } else {
                // Engine is running but format is invalid (Bluetooth route lost)
                print("🎤 Running engine has invalid format (\(format.sampleRate)Hz, \(format.channelCount)ch) — rebuilding")
                engine.stop()
                engine.inputNode.removeTap(onBus: 0)
                audioEngine = nil
                // Fall through to create a new engine below
                try createAndStartAudioEngine()
            }
        } else {
            // Clean up old engine if it exists but isn't running
            if let oldEngine = audioEngine {
                oldEngine.inputNode.removeTap(onBus: 0)
                audioEngine = nil
            }
            try createAndStartAudioEngine()
        }

        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            Task { @MainActor in
                self?.handleRecognitionResult(result: result, error: error)
            }
        }
    }

    private func createAndStartAudioEngine() throws {
        let engine = AVAudioEngine()
        audioEngine = engine

        let inputNode = engine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        // Validate format before installing tap — prevents crash on invalid Bluetooth route
        guard recordingFormat.sampleRate > 0 && recordingFormat.channelCount > 0 else {
            audioEngine = nil
            print("🎤 Audio format invalid (\(recordingFormat.sampleRate)Hz, \(recordingFormat.channelCount)ch) — cannot start engine")
            throw WakeWordError.configurationError("Audio input format invalid — is Bluetooth connected?")
        }

        print("🎤 New audio engine: \(recordingFormat.sampleRate)Hz, \(recordingFormat.channelCount)ch")

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
            self?.audioBufferForwarder?(buffer)
        }

        engine.prepare()
        try engine.start()
    }

    private func handleRecognitionResult(result: SFSpeechRecognitionResult?, error: Error?) {
        if let error = error {
            let nsError = error as NSError
            // Code 1110 = "No speech detected" — just restart
            if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 1110 {
                restartRecognition()
                return
            }
            print("🎤 Recognition error: \(error.localizedDescription)")
            restartRecognition()
            return
        }

        guard let result = result else { return }
        let transcript = result.bestTranscription.formattedString.lowercased()
        debugTranscript = transcript

        // Check for stop command first (during TTS playback)
        if listenForStop && !stopFired && containsStopPhrase(transcript) {
            print("🛑 Stop command detected in: '\(transcript)'")
            stopFired = true
            pauseRecognition()  // Keep engine alive
            onStopCommand?()
            return
        }

        if !wakeWordFired && containsWakePhrase(transcript) {
            print("🎤 Wake word detected in: '\(transcript)'")
            wakeWordFired = true
            handleWakeWordDetected()
        }

        if result.isFinal { restartRecognition() }
    }

    private func containsStopPhrase(_ transcript: String) -> Bool {
        for phrase in allStopPhrases {
            if transcript.contains(phrase) { return true }
        }
        // Also match if the transcript is just "stop" with minor noise
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "stop" || trimmed.hasSuffix(" stop") { return true }
        return false
    }

    private func containsWakePhrase(_ transcript: String) -> Bool {
        // Log every transcript so we can see what the recognizer hears
        print("🎤 Heard: '\(transcript)' (looking for: '\(wakePhrase)')")
        if transcript.contains(wakePhrase) { return true }
        for phrase in alternativePhrases {
            if transcript.contains(phrase) { return true }
        }
        return false
    }

    private func handleWakeWordDetected() {
        lastDetectionTime = Date()
        // Stop recognition task but KEEP the audio engine running
        // so TranscriptionService can reuse it (crucial for background mode)
        pauseRecognition()
        onWakeWordDetected?()
    }

    /// Stop the recognition task without killing the audio engine
    private func pauseRecognition() {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        isListening = false
    }

    /// Public version of pauseRecognition — stops recognition but keeps engine alive
    func pauseRecognitionPublic() {
        pauseRecognition()
    }

    /// Re-configure audio session if Bluetooth route changed (glasses disconnect/reconnect)
    /// Call this before startListening() when recovering from background or route change
    func reconfigureAudioSessionIfNeeded() {
        let route = AVAudioSession.sharedInstance().currentRoute
        let hasBluetooth = route.inputs.contains { $0.portType == .bluetoothHFP } ||
                           route.outputs.contains { $0.portType == .bluetoothHFP || $0.portType == .bluetoothA2DP }

        // Check if current engine format is valid
        if let engine = audioEngine {
            let format = engine.inputNode.outputFormat(forBus: 0)
            if format.sampleRate == 0 || format.channelCount == 0 {
                print("🎤 Engine format invalid — cleaning up for fresh start")
                cleanupAudioEngine()
            }
        }

        if hasBluetooth {
            print("🎤 Bluetooth route active — reconfiguring audio session")
        } else {
            print("🎤 No Bluetooth route — reconfiguring audio session for built-in mic")
        }

        // Force reconfigure to pick up new route
        audioSessionConfigured = false
        configureAudioSession()
    }

    private func restartRecognition() {
        guard isListening else { return }
        Task {
            // Pause recognition (keep engine alive) and restart just the task
            pauseRecognition()
            try? await Task.sleep(nanoseconds: 300_000_000)
            try? await startListening()
        }
    }

    private func requestPermissions() async -> Bool {
        let micPermission = await AVAudioApplication.requestRecordPermission()
        guard micPermission else { return false }

        let speechPermission = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        return speechPermission
    }
}

enum WakeWordError: LocalizedError {
    case microphonePermissionDenied
    case configurationError(String)
    case activationError(String)

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied: return "Microphone permission required"
        case .configurationError(let msg): return "Configuration error: \(msg)"
        case .activationError(let msg): return "Activation error: \(msg)"
        }
    }
}
