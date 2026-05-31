import Foundation
import AVFoundation
import Speech
import CallKit

/// Handles wake word detection using iOS Speech Recognition
/// Listens for "Hey Claude" to trigger voice queries
@MainActor
class WakeWordService: NSObject, ObservableObject {
    @Published var isListening: Bool = false
    @Published var lastDetectionTime: Date?
    @Published var errorMessage: String?
    @Published var debugTranscript: String = ""

    /// Called when a wake word is detected. Passes the matched phrase so the caller can route to the right persona.
    var onWakeWordDetected: ((String) -> Void)?
    var onStopCommand: (() -> Void)?
    /// Called when the user starts speaking during TTS (voice-activity barge-in).
    /// Passes the partial transcript so the app can use it as the start of a new query.
    var onBargeIn: ((String) -> Void)?
    /// Called when Bluetooth audio route is lost (glasses in case / powered off)
    var onBluetoothDisconnected: (() -> Void)?
    /// Called when sustained silence is detected (glasses likely in case).
    var onSilenceDetected: (() -> Void)?
    /// Called when audio resumes after silence (glasses taken out of case).
    var onAudioResumed: (() -> Void)?
    /// Called when Bluetooth audio reconnects (glasses powered back on / out of case).
    var onBluetoothReconnected: (() -> Void)?

    /// Whether the mic is currently paused due to silence (glasses in case).
    @Published var pausedForSilence: Bool = false

    /// Silence detection: number of consecutive low-RMS buffers.
    private var silentBufferCount: Int = 0
    /// RMS threshold below which a buffer is considered "silent".
    /// Glasses mic in a closed case typically produces near-zero signal.
    private let silenceRMSThreshold: Float = 0.005
    /// Number of consecutive silent buffers before declaring silence (~60 seconds at typical buffer rate).
    private let silenceBufferThreshold: Int = 600
    /// Whether silence was already reported (prevents repeated callbacks).
    private var silenceReported: Bool = false

    private var audioEngine: AVAudioEngine?
    /// Set before an *intentional* recognition cancel (e.g. pausing the wake-word task so
    /// only the buffer forwarder feeds TranscriptionService). Tells `handleRecognitionResult`
    /// to ignore the resulting cancellation error instead of auto-restarting a competing recognizer.
    private var suppressAutoRestart = false
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioSessionConfigured: Bool = false
    /// When true, don't start continuous wake word listening — only listen when explicitly triggered.
    /// Set to true when CarPlay is active so we don't hold a recording session open.
    var carPlayMode: Bool = false

    /// When true, also listen for "stop" commands (used during TTS playback)
    var listenForStop: Bool = false
    /// Track whether we already fired a stop for this listening session
    private var stopFired: Bool = false
    /// Track whether wake word already fired for this recognition session (prevent double-fire)
    private var wakeWordFired: Bool = false

    /// Multiple audio buffer consumers keyed by ID (transcription, captions, rewind, etc.)
    private var audioBufferForwarders: [String: @Sendable (AVAudioPCMBuffer) -> Void] = [:]

    /// All active wake phrases from all enabled personas.
    private var allWakePhrases: [String] { Config.allActiveWakePhrases }
    /// Legacy single phrase for backward compatibility.
    private var wakePhrase: String { Config.wakePhrase }
    private let stopPhrases = ["stop", "stop stop"]

    /// Dynamic stop phrases that include all persona wake words
    private var allStopPhrases: [String] {
        var phrases = stopPhrases
        for persona in Config.enabledPersonas {
            let base = persona.wakePhrase.replacingOccurrences(of: "hey ", with: "")
            phrases.append("\(persona.wakePhrase) stop")
            phrases.append("\(base) stop")
        }
        return phrases
    }

    override init() {
        super.init()
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }

    /// Force reconfigure audio session (e.g. when mic source changes)
    func reconfigureAudioSession() {
        audioSessionConfigured = false
        configureAudioSession()
    }

    /// Pause other audio (podcasts, music) while actively listening.
    /// Skips if a phone/FaceTime call is in progress so we don't interrupt it.
    /// Call when transitioning from wake-word standby to active conversation.
    /// Reference count for hold requests. The pause is applied once for the first holder
    /// and released only when the last holder asks to resume. This lets the mic-active
    /// flow and the TTS-speaking flow nest cleanly — Music/Podcasts stay paused for the
    /// whole interaction and only resume after everything finishes.
    private var pauseHoldCount: Int = 0

    func pauseOtherAudio() {
        guard !carPlayMode else { return }
        // Never interrupt an active phone or FaceTime call
        let callObserver = CXCallObserver()
        let hasActiveCall = callObserver.calls.contains { $0.hasConnected && !$0.hasEnded && !$0.isOnHold }
        guard !hasActiveCall else {
            print("🎤 Active call detected — skipping audio pause")
            return
        }
        pauseHoldCount += 1
        guard pauseHoldCount == 1 else {
            print("🎤 Audio already paused (hold count \(pauseHoldCount))")
            return
        }
        let session = AVAudioSession.sharedInstance()
        let useGlassesMic = Config.useGlassesMicForWakeWord
        // Omitting mixWithOthers/duckOthers causes iOS to interrupt (pause) other audio apps
        let options: AVAudioSession.CategoryOptions = useGlassesMic
            ? [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker]
            : [.defaultToSpeaker]
        try? session.setCategory(.playAndRecord, mode: .measurement, options: options)
        try? session.setActive(true)
        print("🎤 Pausing other audio for active listening")
    }

    /// Restore other audio (podcasts, music) after active listening ends.
    /// The .notifyOthersOnDeactivation flag tells paused apps to resume.
    func resumeOtherAudio() {
        guard !carPlayMode else { return }
        guard pauseHoldCount > 0 else { return }
        pauseHoldCount -= 1
        guard pauseHoldCount == 0 else {
            print("🎤 Audio still held by \(pauseHoldCount) other holder(s) — not resuming yet")
            return
        }
        let session = AVAudioSession.sharedInstance()
        let useGlassesMic = Config.useGlassesMicForWakeWord
        let options: AVAudioSession.CategoryOptions = useGlassesMic
            ? [.mixWithOthers, .allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker]
            : [.mixWithOthers, .defaultToSpeaker]
        try? session.setCategory(.playAndRecord, mode: .measurement, options: options)
        // notifyOthersOnDeactivation tells paused apps (Music, Podcasts) they can resume.
        try? session.setActive(true, options: .notifyOthersOnDeactivation)
        print("🎤 Restored audio mix — other apps can resume")
    }

    /// Force release of any held pauses — used when listening is toggled off entirely.
    func forceResumeOtherAudio() {
        guard pauseHoldCount > 0 else { return }
        pauseHoldCount = 1  // resumeOtherAudio will decrement to 0 and restore
        resumeOtherAudio()
    }

    /// Configure the shared audio session once — call before first use
    func configureAudioSession() {
        guard !audioSessionConfigured else { return }
        do {
            let audioSession = AVAudioSession.sharedInstance()

            // In CarPlay mode, only activate recording when explicitly requested
            // (voice control template showing). Otherwise use playback-only to
            // avoid disrupting car audio.
            if carPlayMode {
                try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [.mixWithOthers, .allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker])
                try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
                audioSessionConfigured = true
                print("🎤 CarPlay mode: .playAndRecord + .voiceChat (voice control active)")
            } else {
                let useGlassesMic = Config.useGlassesMicForWakeWord
                let options: AVAudioSession.CategoryOptions = useGlassesMic
                    ? [.mixWithOthers, .allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker]
                    : [.mixWithOthers, .defaultToSpeaker]
                try audioSession.setCategory(.playAndRecord, mode: .measurement, options: options)
                try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
                audioSessionConfigured = true
                print("🎤 Mic source: \(useGlassesMic ? "glasses (Bluetooth)" : "phone (built-in)")")
            }

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
            // Only restart if Bluetooth (glasses) route is available
            let route = AVAudioSession.sharedInstance().currentRoute
            let hasBluetooth = route.inputs.contains { $0.portType == .bluetoothHFP }
            if hasBluetooth {
                print("🎤 Audio interruption ended — restarting listener (Bluetooth active)")
                try? AVAudioSession.sharedInstance().setActive(true)
                Task { try? await startListening() }
            } else {
                print("🎤 Audio interruption ended — NOT restarting (no Bluetooth)")
            }
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
            let lostBluetooth = !route.inputs.contains { $0.portType == .bluetoothHFP }
            print("🎤 Bluetooth device disconnected — stopping audio engine (BT lost: \(lostBluetooth))")
            cleanupAudioEngine()
            isListening = false
            if lostBluetooth {
                onBluetoothDisconnected?()
            }
        case .newDeviceAvailable:
            // New device connected — only restart if it's Bluetooth (glasses back on)
            let newRoute = AVAudioSession.sharedInstance().currentRoute
            let isBluetooth = newRoute.inputs.contains { $0.portType == .bluetoothHFP }
            if isBluetooth {
                print("🎤 Bluetooth device reconnected — restarting with fresh engine")
                cleanupAudioEngine()
                isListening = false
                onBluetoothReconnected?()
                Task {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    audioSessionConfigured = false
                    configureAudioSession()
                    try? await startListening()
                }
            } else {
                print("🎤 New audio device (non-Bluetooth) — NOT restarting mic for privacy")
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
        silentBufferCount = 0
        silenceReported = false
        pausedForSilence = false

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

    /// Fully deactivate the audio session — use when CarPlay voice control is dismissed
    /// so car audio (FM radio, other apps) can resume.
    func deactivateAudioSession() {
        cleanupAudioEngine()
        isListening = false
        audioSessionConfigured = false
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            print("🎤 Audio session deactivated (CarPlay voice ended)")
        } catch {
            print("🎤 Failed to deactivate audio session: \(error)")
        }
    }

    func resumeListening() {
        guard !isListening else { return }
        Task { try? await startListening() }
    }

    // MARK: - Shared Audio Engine (for TranscriptionService)

    /// Ensure the shared audio engine is running (creates one if needed).
    /// Call this before `TranscriptionService.startRecording()` to guarantee
    /// the buffer-forwarding path is alive — e.g. after TTS playback which
    /// may have interrupted or stopped the engine.
    func ensureAudioEngineRunning() async throws {
        if let engine = audioEngine, engine.isRunning { return }
        // Engine is nil or stopped — restart it (without starting recognition)
        print("🎤 Audio engine not running — restarting for shared use")
        try await startListening()
        // Pause recognition so only the buffer forwarder is active. Mark the cancel as
        // intentional so its error callback doesn't auto-restart a competing recognizer
        // (which would fight TranscriptionService and make tap-to-talk stop immediately).
        suppressAutoRestart = true
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
    }

    /// Get the current audio engine (for shared use by TranscriptionService)
    func getAudioEngine() -> AVAudioEngine? {
        return audioEngine
    }

    /// Legacy single-forwarder API — routes through the multi-consumer system with key "default"
    func setAudioBufferForwarder(_ forwarder: (@Sendable (AVAudioPCMBuffer) -> Void)?) {
        if let forwarder = forwarder {
            audioBufferForwarders["default"] = forwarder
        } else {
            audioBufferForwarders.removeValue(forKey: "default")
        }
    }

    /// Add a named audio buffer consumer. Multiple consumers can listen simultaneously.
    func addAudioBufferConsumer(id: String, handler: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        audioBufferForwarders[id] = handler
    }

    /// Remove a named audio buffer consumer.
    func removeAudioBufferConsumer(id: String) {
        audioBufferForwarders.removeValue(forKey: id)
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
        // Boost recognition of all persona wake phrases
        let personaPhrases = Config.allActiveWakePhrases
        let contextPhrases = personaPhrases.isEmpty ? [wakePhrase] : personaPhrases
        recognitionRequest.contextualStrings = contextPhrases
        let personaNames = Config.enabledPersonas.map(\.name)
        print("🎤 Personas: \(personaNames), contextualStrings: \(contextPhrases)")

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
            // Fan out to all registered audio consumers
            if let forwarders = self?.audioBufferForwarders {
                for (_, handler) in forwarders {
                    handler(buffer)
                }
            }
            // Monitor audio levels for silence detection (glasses in case)
            self?.checkAudioLevel(buffer: buffer)
        }

        engine.prepare()
        try engine.start()
    }

    // MARK: - Silence Detection (Glasses in Case)

    private nonisolated func checkAudioLevel(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }

        // Calculate RMS of the buffer
        var sum: Float = 0
        let data = channelData[0]
        for i in 0..<frames {
            let sample = data[i]
            sum += sample * sample
        }
        let rms = sqrtf(sum / Float(frames))

        Task { @MainActor [weak self] in
            guard let self else { return }
            if rms < self.silenceRMSThreshold {
                self.silentBufferCount += 1
                if self.silentBufferCount >= self.silenceBufferThreshold && !self.silenceReported {
                    self.silenceReported = true
                    self.pausedForSilence = true
                    NSLog("[WakeWord] Sustained silence detected (%d buffers) — glasses likely in case", self.silentBufferCount)
                    self.onSilenceDetected?()
                }
            } else {
                if self.silenceReported {
                    NSLog("[WakeWord] Audio resumed after silence — glasses active again")
                    self.silenceReported = false
                    self.pausedForSilence = false
                    self.onAudioResumed?()
                }
                self.silentBufferCount = 0
            }
        }
    }

    private func handleRecognitionResult(result: SFSpeechRecognitionResult?, error: Error?) {
        // An intentional cancel (ensureAudioEngineRunning pausing the wake-word task so
        // the buffer forwarder can feed TranscriptionService) surfaces here as an error.
        // Consume it once and don't auto-restart — otherwise a second recognizer spins up
        // and fights the transcription task, making tap-to-talk stop the instant it starts.
        if suppressAutoRestart {
            suppressAutoRestart = false
            return
        }
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

        // During TTS playback: detect any speech as barge-in interrupt
        if listenForStop && !stopFired {
            // Explicit stop command
            if containsStopPhrase(transcript) {
                print("🛑 Stop command detected in: '\(transcript)'")
                stopFired = true
                pauseRecognition()
                onStopCommand?()
                return
            }

            // Wake word during TTS — interrupt and start new conversation
            if let matched = matchedWakePhrase(transcript) {
                print("⚡ Barge-in (wake word): '\(matched)' during TTS")
                stopFired = true
                wakeWordFired = true
                pauseRecognition()
                onStopCommand?()
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    self.onWakeWordDetected?(matched)
                }
                return
            }

            // Voice-activity barge-in: any meaningful speech interrupts TTS
            let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            let wordCount = trimmed.split(separator: " ").count
            if wordCount >= 2 {
                print("⚡ Barge-in (voice activity): '\(trimmed)' during TTS")
                stopFired = true
                pauseRecognition()
                onBargeIn?(trimmed)
                return
            }
        }

        // Normal wake word detection (not during TTS)
        if let matched = matchedWakePhrase(transcript) {
            if !wakeWordFired {
                // Normal wake word detection (not during TTS)
                print("🎤 Wake word detected: '\(matched)' in: '\(transcript)'")
                wakeWordFired = true
                handleWakeWordDetected(matchedPhrase: matched)
            }
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

    /// Check all persona wake phrases and return the matched one, or nil.
    /// Uses exact matching first, then fuzzy Levenshtein distance matching
    /// to handle speech recognition errors ("Hey Clause", "Hey Cloud" → "Hey Claude").
    private func matchedWakePhrase(_ transcript: String) -> String? {
        let lower = transcript.lowercased()
        let words = lower.split(separator: " ").map(String.init)

        // Pass 1: Exact substring match (fast path)
        for persona in Config.enabledPersonas {
            if lower.contains(persona.wakePhrase) { return persona.wakePhrase }
            for alt in persona.alternativeWakePhrases {
                if lower.contains(alt) { return persona.wakePhrase }
            }
        }
        if lower.contains(wakePhrase) { return wakePhrase }

        // Pass 2: Fuzzy match — check sliding window of word pairs/triples against wake phrases
        let allPhrases: [(phrase: String, primary: String)] = Config.enabledPersonas.flatMap { persona in
            [(persona.wakePhrase, persona.wakePhrase)] +
            persona.alternativeWakePhrases.map { ($0, persona.wakePhrase) }
        } + [(wakePhrase, wakePhrase)]

        for (phrase, primary) in allPhrases {
            let phraseWords = phrase.split(separator: " ").map(String.init)
            let windowSize = phraseWords.count
            guard windowSize > 0, words.count >= windowSize else { continue }

            for i in 0...(words.count - windowSize) {
                let window = words[i..<(i + windowSize)].joined(separator: " ")
                let distance = levenshteinDistance(window, phrase)
                // Allow up to 2 character edits for short phrases, 3 for longer ones
                let threshold = phrase.count <= 10 ? 2 : 3
                if distance <= threshold && distance > 0 {
                    print("🎤 Fuzzy wake word match: '\(window)' ≈ '\(phrase)' (distance: \(distance))")
                    return primary
                }
            }
        }

        return nil
    }

    /// Levenshtein edit distance between two strings.
    private func levenshteinDistance(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        let m = aChars.count
        let n = bChars.count
        if m == 0 { return n }
        if n == 0 { return m }

        var prev = Array(0...n)
        var curr = [Int](repeating: 0, count: n + 1)

        for i in 1...m {
            curr[0] = i
            for j in 1...n {
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            prev = curr
        }
        return prev[n]
    }

    private func handleWakeWordDetected(matchedPhrase: String) {
        lastDetectionTime = Date()
        pauseRecognition()
        onWakeWordDetected?(matchedPhrase)
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
