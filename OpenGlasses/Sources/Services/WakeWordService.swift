import Foundation
import AVFoundation
import Speech
import CallKit
import os.lock

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

    /// RMS threshold below which a buffer is considered "silent".
    /// Glasses mic in a closed case typically produces near-zero signal.
    private let silenceRMSThreshold: Float = 0.005
    /// Number of consecutive silent buffers before declaring silence. At 1024-frame buffers this is
    /// ~13s at 48kHz (Bluetooth) / ~38s at 16kHz — well short of a literal minute (comment corrected
    /// per Plan BE); tune here if the in-case mic shutoff feels too eager.
    private let silenceBufferThreshold: Int = 600
    /// Whether silence was already reported (prevents repeated callbacks).
    private var silenceReported: Bool = false

    private var audioEngine: AVAudioEngine?
    /// Set before an *intentional* recognition cancel (e.g. pausing the wake-word task so
    /// only the buffer forwarder feeds TranscriptionService). Tells `handleRecognitionResult`
    /// to ignore the resulting cancellation error instead of auto-restarting a competing recognizer.
    private var suppressAutoRestart = false
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest? {
        didSet { tapState.setRequest(recognitionRequest) }   // keep the tap's view in sync (Plan BE)
    }
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioSessionConfigured: Bool = false
    /// Our claim on the shared session with the coordinator. Wake word is the always-on baseline
    /// owner: it self-activates with its tuned config and registers ownership so a live session
    /// (Gemini/OpenAI) supersedes it cleanly, and its release deactivates only if still current.
    private var sessionLease: AudioSessionLease?
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

    /// Lock-guarded state the audio-render thread reads from the tap (Plan BE). The tap block used
    /// to touch `@MainActor` storage (`recognitionRequest`, `audioBufferForwarders`) directly from
    /// the Core Audio thread while the main actor mutated them — a torn read / EXC_BAD_ACCESS on
    /// the app's hottest path. The tap now only ever touches this box; the main actor publishes
    /// changes into it under the same lock.
    private let tapState = WakeTapState()

    /// Owned NotificationCenter observer tokens (Plan BE). Discarding these leaked a fresh
    /// interruption+route observer pair on every reconfigure, so after N glasses reconnects one
    /// route change fired N duplicate handlers.
    private var sessionObservers: [NSObjectProtocol] = []

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
        speechRecognizer = SFSpeechRecognizer(locale: SpeechLocaleResolver.current)
    }

    /// Force reconfigure audio session (e.g. when mic source changes)
    func reconfigureAudioSession() async {
        audioSessionConfigured = false
        await configureAudioSession()
    }

    /// Pause other audio (podcasts, music) while actively listening.
    /// Skips if a phone/FaceTime call is in progress so we don't interrupt it.
    /// Call when transitioning from wake-word standby to active conversation.
    /// Reference count for hold requests. The pause is applied once for the first holder
    /// and released only when the last holder asks to resume. This lets the mic-active
    /// flow and the TTS-speaking flow nest cleanly — Music/Podcasts stay paused for the
    /// whole interaction and only resume after everything finishes.
    private var pauseHoldCount: Int = 0

    func pauseOtherAudio() async {
        guard !carPlayMode else { return }
        // Never interrupt an active phone or FaceTime call
        let callObserver = CXCallObserver()
        let hasActiveCall = callObserver.calls.contains { $0.hasConnected && !$0.hasEnded && !$0.isOnHold }
        guard !hasActiveCall else {
            print("🎤 Active call detected — skipping audio pause")
            return
        }
        // BJ PR2: mutate the refcount synchronously *before* the first await, so nested
        // beginPause/endPause still nest cleanly across the suspension point below.
        pauseHoldCount += 1
        guard pauseHoldCount == 1 else {
            print("🎤 Audio already paused (hold count \(pauseHoldCount))")
            return
        }
        let useGlassesMic = Config.useGlassesMicForWakeWord
        // Omitting mixWithOthers/duckOthers causes iOS to interrupt (pause) other audio apps
        let options: AVAudioSession.CategoryOptions = useGlassesMic
            ? [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker]
            : [.defaultToSpeaker]
        // .default (NOT .measurement): .measurement disables system audio processing/gain,
        // which makes TTS playback extremely quiet on the iPhone speaker. The wake-word /
        // command capture works fine in .default (see resumeOtherAudio, which already does this).
        // BJ PR2: the blocking setCategory→setActive runs off-main through the coordinator's
        // `reconfigure` (no deactivate-first, no fallback — the hand-tuned options are preserved).
        try? await AudioSessionCoordinator.shared.reconfigure(
            category: .playAndRecord, mode: .default, options: options)
        // Cheap, non-blocking route hints stay inline (they are not the TPC hang source — the
        // blocking activation above is what moved off-main).
        let session = AVAudioSession.sharedInstance()
        let onBluetooth = session.currentRoute.outputs.contains {
            [.bluetoothHFP, .bluetoothA2DP, .bluetoothLE].contains($0.portType)
        }
        if !onBluetooth { try? session.overrideOutputAudioPort(.speaker) }
        preferGlassesMicIfAvailable(session)
        let outRoute = session.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ",")
        print("🎤 Pausing other audio for active listening — output route: \(outRoute)")
    }

    /// Restore other audio (podcasts, music) after active listening ends.
    /// The .notifyOthersOnDeactivation flag tells paused apps to resume.
    func resumeOtherAudio() async {
        guard !carPlayMode else { return }
        guard pauseHoldCount > 0 else { return }
        // BJ PR2: decrement synchronously before any await (see pauseOtherAudio).
        pauseHoldCount -= 1
        guard pauseHoldCount == 0 else {
            print("🎤 Audio still held by \(pauseHoldCount) other holder(s) — not resuming yet")
            return
        }
        let useGlassesMic = Config.useGlassesMicForWakeWord
        let options: AVAudioSession.CategoryOptions = useGlassesMic
            ? [.mixWithOthers, .allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker]
            : [.mixWithOthers, .defaultToSpeaker]
        // .default (not .measurement) so concurrent music/podcasts keep playing cleanly
        // while the wake-word listener runs — .measurement disables system audio
        // processing and fights other audio even with .mixWithOthers.
        // notifyOthersOnDeactivation tells paused apps (Music, Podcasts) they can resume.
        try? await AudioSessionCoordinator.shared.reconfigure(
            category: .playAndRecord, mode: .default, options: options,
            activeOptions: .notifyOthersOnDeactivation)
        print("🎤 Restored audio mix — other apps can resume")
    }

    /// Force release of any held pauses — used when listening is toggled off entirely.
    func forceResumeOtherAudio() async {
        guard pauseHoldCount > 0 else { return }
        pauseHoldCount = 1  // resumeOtherAudio will decrement to 0 and restore
        await resumeOtherAudio()
    }

    /// When "use glasses mic" is on, explicitly prefer a Bluetooth input belonging to the
    /// glasses (port name contains "Meta"/"Ray-Ban"). On iOS 26 Ray-Ban audio rides
    /// Bluetooth LE Audio (LC3), so the glasses mic can surface as `.bluetoothLE` rather
    /// than `.bluetoothHFP`, and the system default input may otherwise stay on the iPhone.
    /// No-op when the option is off or no such input is present, so the iPhone-mic fallback
    /// path is never affected. (Recipe from glassbridge's iOS 26 audio learnings; can't be
    /// verified without Ray-Ban hardware, so it's deliberately additive and guarded.)
    private func preferGlassesMicIfAvailable(_ session: AVAudioSession) {
        guard Config.useGlassesMicForWakeWord, let inputs = session.availableInputs else { return }
        let glassesPortTypes: [AVAudioSession.Port] = [.bluetoothHFP, .bluetoothLE, .headsetMic]
        guard let glassesInput = inputs.first(where: { port in
            glassesPortTypes.contains(port.portType) &&
            ["meta", "ray-ban", "rayban"].contains { port.portName.lowercased().contains($0) }
        }) else { return }
        do {
            try session.setPreferredInput(glassesInput)
            print("🎤 Preferred glasses mic input: \(glassesInput.portName) (\(glassesInput.portType.rawValue))")
        } catch {
            print("🎤 Could not set glasses mic as preferred input: \(error.localizedDescription)")
        }
    }

    /// Configure the shared audio session once — call before first use.
    ///
    /// BJ PR2: records baseline ownership (`assumeOwnership`) then activates **off-main** through the
    /// coordinator's `reconfigure` (no deactivate-first, no `.default` fallback — the hand-tuned
    /// `mixWithOthers` options must survive). `assumeOwnership` is deliberately kept rather than
    /// retired: wake word must not deactivate-first, so `acquireOffMain` (which does) is wrong here —
    /// ownership is recorded and the activation runs through the no-deactivate `reconfigure`.
    func configureAudioSession() async {
        guard !audioSessionConfigured else { return }
        // Register as the baseline owner first (supersedes any prior lease); the reconfigure below
        // performs the real activation while keeping the tuned config.
        sessionLease = AudioSessionCoordinator.shared.assumeOwnership(.wakeWord)

        let category: AVAudioSession.Category = .playAndRecord
        let mode: AVAudioSession.Mode
        let options: AVAudioSession.CategoryOptions
        if carPlayMode {
            // In CarPlay mode, only activate recording when explicitly requested (voice control
            // template showing). Otherwise use playback-only to avoid disrupting car audio.
            mode = .voiceChat
            options = [.mixWithOthers, .allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker]
        } else {
            let useGlassesMic = Config.useGlassesMicForWakeWord
            // .default (not .measurement) so other audio coexists cleanly with the always-on
            // listener — see resumeOtherAudio for the same rationale.
            mode = .default
            options = useGlassesMic
                ? [.mixWithOthers, .allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker]
                : [.mixWithOthers, .defaultToSpeaker]
        }

        do {
            try await AudioSessionCoordinator.shared.reconfigure(
                category: category, mode: mode, options: options,
                activeOptions: .notifyOthersOnDeactivation)
        } catch {
            print("🎤 Failed to configure audio session: \(error)")
            return
        }
        audioSessionConfigured = true

        let audioSession = AVAudioSession.sharedInstance()
        if carPlayMode {
            print("🎤 CarPlay mode: .playAndRecord + .voiceChat (voice control active)")
        } else {
            preferGlassesMicIfAvailable(audioSession)
            print("🎤 Mic source: \(Config.useGlassesMicForWakeWord ? "glasses (Bluetooth)" : "phone (built-in)")")
        }

        let route = audioSession.currentRoute
        for input in route.inputs {
            print("🎤 Audio input: \(input.portName) (\(input.portType.rawValue))")
        }
        for output in route.outputs {
            print("🔊 Audio output: \(output.portName) (\(output.portType.rawValue))")
        }
        print("🎤 Audio session configured: .playAndRecord with Bluetooth")

        // Handle audio interruptions + route changes. Tokens are owned and removed before any
        // re-registration (Plan BE) — the old code discarded them, leaking a fresh pair on
        // every reconfigure so one route change fired N duplicate handlers after N reconnects.
        installSessionObservers(audioSession: audioSession)
    }

    /// Register the interruption + route-change observers exactly once per configuration, removing
    /// any previously-owned tokens first so they can never accumulate.
    private func installSessionObservers(audioSession: AVAudioSession) {
        removeSessionObservers()
        let interruption = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: audioSession, queue: nil
        ) { [weak self] notification in
            Task { @MainActor in self?.handleAudioInterruption(notification) }
        }
        let route = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: audioSession, queue: nil
        ) { [weak self] notification in
            Task { @MainActor in self?.handleRouteChange(notification) }
        }
        sessionObservers = [interruption, route]
    }

    private func removeSessionObservers() {
        for token in sessionObservers { NotificationCenter.default.removeObserver(token) }
        sessionObservers.removeAll()
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
            // Don't fight a live session (Plan BE). If a Gemini/OpenAI realtime session now owns the
            // shared audio session, it handles its own interruption recovery — reactivating here
            // with our .playAndRecord/.default config would stomp its .videoChat setup and spin up a
            // second engine contending for the mic. Only reclaim when wake word is the owner.
            let owner = AudioSessionCoordinator.shared.currentOwner
            guard owner == nil || owner == .wakeWord else {
                print("🎤 Audio interruption ended — NOT restarting; session owned by \(owner!.rawValue)")
                return
            }
            // Only restart if Bluetooth (glasses) route is available
            let route = AVAudioSession.sharedInstance().currentRoute
            let hasBluetooth = route.inputs.contains { $0.portType == .bluetoothHFP }
            if hasBluetooth {
                print("🎤 Audio interruption ended — restarting listener (Bluetooth active)")
                // BJ PR2: reactivate off-main through the coordinator (was a main-thread setActive),
                // then restart — one Task so the reactivate precedes the listener start.
                Task {
                    await AudioSessionCoordinator.shared.ensureActiveOffMain()
                    try? await startListening()
                }
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
                    await configureAudioSession()
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
        // Push-to-Talk (Silent Mode): never run the always-on wake-word listener.
        // This is the single chokepoint — every auto-start path (launch, foreground,
        // glasses connect, returnToWakeWord, autoStart) funnels through here, so the
        // mic is never held for constant listening. On-demand triggers (Action Button →
        // startDirectTranscription) bypass this and still work.
        if Config.silentMode {
            print("🎤 Push-to-Talk mode — skipping always-on wake-word listener")
            return
        }
        stopFired = false
        wakeWordFired = false
        silenceTracker.reset()
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
        await configureAudioSession()

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
                // CoreAudio '!pla' (2003329396): the AVAudioSession lost activation — usually a
                // Bluetooth route flap mid-start (device-traced: Action-button intent in the
                // background burned all 3 attempts inside the same broken window, then went
                // silent). Re-activating the session before the retry is what actually
                // recovers; the half-second sleeps alone never did.
                if (error as NSError).code == 2003329396 || attempt > 1 {
                    audioSessionConfigured = false
                    await configureAudioSession()
                }
                let delay = UInt64(attempt) * 700_000_000
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
    func deactivateAudioSession() async {
        cleanupAudioEngine()
        isListening = false
        audioSessionConfigured = false
        if let lease = sessionLease {
            // Release through the coordinator: it deactivates only if wake word is still the
            // current owner, so this can't tear down a live Gemini/OpenAI session that preempted us.
            // The deactivation itself runs off-main on the coordinator's sessionIOQueue (BJ PR1).
            sessionLease = nil
            AudioSessionCoordinator.shared.release(lease)
            print("🎤 Audio session released (CarPlay voice ended)")
        } else {
            // BJ PR2: rare no-lease fallback — deactivate off-main via the coordinator too.
            await AudioSessionCoordinator.shared.deactivateOffMain()
            print("🎤 Audio session deactivated (CarPlay voice ended)")
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
        tapState.setForwarders(audioBufferForwarders)
    }

    /// Add a named audio buffer consumer. Multiple consumers can listen simultaneously.
    func addAudioBufferConsumer(id: String, handler: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        audioBufferForwarders[id] = handler
        tapState.setForwarders(audioBufferForwarders)
    }

    /// Remove a named audio buffer consumer.
    func removeAudioBufferConsumer(id: String) {
        audioBufferForwarders.removeValue(forKey: id)
        tapState.setForwarders(audioBufferForwarders)
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
        // On-device wake-word spotting (Plan BE): the always-on listener no longer streams mic
        // audio to Apple's servers 24/7 — the single largest steady battery/data drain. Short-phrase
        // spotting works well on-device (contextualStrings still apply); real queries keep server
        // recognition in TranscriptionService. Falls back to server if the locale can't do on-device.
        let wantsOnDevice = Config.onDeviceWakeWordEnabled
        let canDoOnDevice = speechRecognizer?.supportsOnDeviceRecognition ?? false
        recognitionRequest.requiresOnDeviceRecognition = wantsOnDevice && canDoOnDevice
        if wantsOnDevice && !canDoOnDevice {
            print("🎤 On-device wake recognition unsupported for this locale — using server recognition")
        }
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

        // The tap runs on the Core Audio render thread. It must NOT touch any @MainActor state —
        // it reads everything it needs from the lock-guarded `tapState` box (Plan BE).
        let tapState = self.tapState
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            tapState.dispatch(buffer)
            // Silence detection is nonisolated and does its own (batched) main-actor hop.
            self?.checkAudioLevel(buffer: buffer)
        }

        engine.prepare()
        try engine.start()
    }

    // MARK: - Silence Detection (Glasses in Case)

    /// Silence counting runs entirely on the audio thread (Plan BE); we hop to the main actor only
    /// on a state *transition* (silence entered / audio resumed) instead of spawning a MainActor
    /// Task per buffer (~10-15/sec, forever).
    private let silenceTracker = SilenceTracker()

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

        switch silenceTracker.observe(rms: rms, threshold: silenceRMSThreshold, limit: silenceBufferThreshold) {
        case .none:
            break
        case .enteredSilence(let count):
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.silenceReported = true
                self.pausedForSilence = true
                NSLog("[WakeWord] Sustained silence detected (%d buffers) — glasses likely in case", count)
                self.onSilenceDetected?()
            }
        case .resumed:
            Task { @MainActor [weak self] in
                guard let self else { return }
                NSLog("[WakeWord] Audio resumed after silence — glasses active again")
                self.silenceReported = false
                self.pausedForSilence = false
                self.onAudioResumed?()
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

    /// Whole-token stop matching, shared with `VoiceCommandParser` (see `PhraseMatcher`).
    ///
    /// This used to be `transcript.contains(phrase)`, which fired on any word *containing* "stop":
    /// "it stopped working yesterday", "nonstop", "stops" and "unstoppable" all cut the assistant
    /// off — and worse, routed the utterance to `onStopCommand` (discarded) rather than `onBargeIn`
    /// (answered), so the user's sentence vanished instead of being replied to.
    ///
    /// `.anywhere` here, unlike the parser's `.utteranceEdge`: this list is only "stop" plus persona
    /// variants, and a missed stop means the user cannot interrupt.
    private func containsStopPhrase(_ transcript: String) -> Bool {
        PhraseMatcher.containsStopPhrase(transcript, phrases: allStopPhrases, position: .anywhere)
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
    func reconfigureAudioSessionIfNeeded() async {
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
        await configureAudioSession()
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

/// Audio-thread silence accumulator (Plan BE). Counts consecutive low-RMS buffers and reports only
/// the two transitions the main actor cares about, so silence detection costs one locked increment
/// per buffer instead of a spawned MainActor Task per buffer.
final class SilenceTracker: @unchecked Sendable {
    enum Transition: Equatable { case none, enteredSilence(count: Int), resumed }

    private let lock = OSAllocatedUnfairLock<State>(initialState: State())
    private struct State { var count = 0; var reported = false }

    func observe(rms: Float, threshold: Float, limit: Int) -> Transition {
        lock.withLock { state in
            if rms < threshold {
                state.count += 1
                if state.count >= limit && !state.reported {
                    state.reported = true
                    return .enteredSilence(count: state.count)
                }
                return .none
            } else {
                let wasReported = state.reported
                state.reported = false
                state.count = 0
                return wasReported ? .resumed : .none
            }
        }
    }

    /// Reset when listening restarts so a fresh session starts from silence-clear.
    func reset() { lock.withLock { $0 = State() } }
}

/// Lock-guarded box the audio-render thread reads from the wake-word tap (Plan BE).
///
/// The tap runs on the Core Audio render thread and must never touch `@MainActor` state. The main
/// actor publishes the current recognition request and forwarder set into this box under the lock;
/// the tap reads a consistent snapshot under the same lock and never sees a torn dictionary or a
/// half-torn-down request. `SFSpeechAudioBufferRecognitionRequest.append` is itself thread-safe;
/// what wasn't safe was the concurrent mutation of the *references* the old tap dereferenced.
final class WakeTapState: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<State>(initialState: State())

    private struct State {
        var request: SFSpeechAudioBufferRecognitionRequest?
        var forwarders: [@Sendable (AVAudioPCMBuffer) -> Void] = []
    }

    func setRequest(_ request: SFSpeechAudioBufferRecognitionRequest?) {
        lock.withLock { $0.request = request }
    }

    func setForwarders(_ forwarders: [String: @Sendable (AVAudioPCMBuffer) -> Void]) {
        let values = Array(forwarders.values)
        lock.withLock { $0.forwarders = values }
    }

    /// Called from the audio thread: append to the recognizer and fan out to consumers, all from a
    /// single locked snapshot.
    func dispatch(_ buffer: AVAudioPCMBuffer) {
        let snapshot = lock.withLock { $0 }
        snapshot.request?.append(buffer)
        for handler in snapshot.forwarders { handler(buffer) }
    }
}


// BS P2: the broadcast's mic source is the same shared tap the video recorder and
// captions ride — the consumer API already matches; this just names the seam.
extension WakeWordService: BroadcastAudioProviding {}
