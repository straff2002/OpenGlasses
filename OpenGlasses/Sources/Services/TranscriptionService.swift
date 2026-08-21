import Foundation
import AVFoundation
@preconcurrency import Speech

/// On-device speech transcription using iOS Speech Recognition
/// Reuses the shared audio engine from WakeWordService to avoid
/// stopping/restarting the engine (which fails when backgrounded).
@MainActor
class TranscriptionService: ObservableObject {
    @Published var isRecording: Bool = false
    @Published var currentTranscription: String = ""
    @Published var errorMessage: String?

    var onTranscriptionComplete: ((String) -> Void)?
    /// Called when recording times out with no speech detected at all
    var onSilenceTimeout: (() -> Void)?

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var silenceTimer: Timer?
    private var noSpeechTimer: Timer?
    /// CO Item 4: the silence window before the conversation ends. Normally
    /// `SpeechContinuationPolicy.baseWindow`, widened for the next turn when the assistant's own
    /// answer was a question the user still has to think about. Set via `noteAssistantSpoke`.
    private var silenceThreshold: TimeInterval = SpeechContinuationPolicy.baseWindow

    /// Tell the transcriber what the assistant just said, so the next silence window can account
    /// for a question. Called from the TTS completion path.
    func noteAssistantSpoke(_ text: String?) {
        let window = SpeechContinuationPolicy.silenceWindow(afterSpeaking: text)
        if window != silenceThreshold {
            NSLog("[CO] Silence window %.1fs → %.1fs (question-shaped: %@)",
                  silenceThreshold, window, window > SpeechContinuationPolicy.baseWindow ? "yes" : "no")
        }
        silenceThreshold = window
    }
    private let noSpeechTimeout: TimeInterval = 10.0
    private var didReceiveSpeech: Bool = false

    /// When the recognizer last reported hearing something — i.e. when the silence window that is
    /// running right now was armed.
    ///
    /// Plan CU P1: `stopRecording()` runs when that window *expires*, `silenceThreshold` seconds
    /// (2.0 s, or 6.0 s after a question-shaped reply) after the wearer actually stopped talking.
    /// Stamping speech-end there would fold the entire endpointing floor into the start of
    /// `perceivedLatency` — the headline metric would silently exclude the one stage P2 exists to
    /// remove, and the before/after would come out flat on a change that worked. Bounded by
    /// construction: the window is re-armed on every partial, so this is never more than one window
    /// old.
    private var lastSpeechObservedAt: Date?

    /// Shared audio engine — set by AppState from WakeWordService
    weak var sharedAudioEngineProvider: WakeWordService?

    // MARK: - On-device ASR (Additional Capabilities #8)
    //
    // SenseVoice is offline / whole-buffer (not streaming), so when it's the selected engine we
    // accumulate the utterance's PCM and decode once on stop, instead of Apple's streaming partials.
    // VAD-based endpointing + on-device partial results are the staged follow-up; for now the turn
    // ends on the caller's `stopRecording()` (or the no-speech timeout).
    private let onDeviceEngine = OnDeviceASREngine()
    private var useOnDevice = false
    private var accumulatedSamples: [Float] = []
    private var captureSampleRate: Double = 16000

    init() {
        speechRecognizer = SFSpeechRecognizer(locale: SpeechLocaleResolver.current)
    }

    func startRecording() {
        guard !isRecording else { return }

        didReceiveSpeech = false
        lastSpeechObservedAt = nil
        currentTranscription = ""
        // Plan CU P1: a new utterance means the previous one has been dealt with, whatever became
        // of it — the turn that answered it has already claimed its stamps, and a voice command
        // that never became a turn must not leave one behind for the next one to inherit.
        TurnRecorder.forgetPendingUtterance()

        // Pick the recognizer: on-device SenseVoice when selected + its model is ready, else Apple.
        let availability = ASREngineSelector.Availability(
            appleSpeechReady: speechRecognizer?.isAvailable ?? false,
            onDeviceReady: onDeviceEngine.isReady,
            online: true
        )
        useOnDevice = ASREngineSelector.select(preference: Config.asrEnginePreference,
                                               availability: availability) == .onDevice
        accumulatedSamples.removeAll(keepingCapacity: true)

        // BJ PR2 follow-up: the fallback engine start may activate the shared session off the main
        // thread now, so setup is async. Keep `startRecording()` synchronous (its ~8 callers are
        // unchanged): mark recording optimistically, run setup on the next tick, roll back on failure.
        isRecording = true
        Task { @MainActor in
            do {
                try await setupAndStartRecording()
                print("🎙️ Recording started...")
                startNoSpeechTimer()
            } catch {
                print("🎙️ Recording setup failed: \(error)")
                errorMessage = error.localizedDescription
                isRecording = false
            }
        }
    }

    func stopRecording() {
        guard isRecording else { return }

        // Plan CU P1: the mic went quiet when the silence window now expiring was ARMED, not when
        // it expired — see `lastSpeechObservedAt`. Falls back to now for the stops that never armed
        // one: the on-device engine (whole-buffer, no partials at all), a recognizer error, or an
        // external stop before any speech arrived. Stamped before the on-device branch below, whose
        // SenseVoice decode runs after the mic went quiet and belongs to the wait, not the speech.
        TurnRecorder.noteSpeechEnd(at: lastSpeechObservedAt ?? Date())
        lastSpeechObservedAt = nil

        silenceTimer?.invalidate()
        silenceTimer = nil
        noSpeechTimer?.invalidate()
        noSpeechTimer = nil

        if useOnDevice {
            finishOnDeviceRecording()
            return
        }

        recognitionTask?.finish()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        isRecording = false

        if !currentTranscription.isEmpty {
            let finalText = currentTranscription
            currentTranscription = ""
            print("📤 Transcription complete, sending: \(finalText)")
            onTranscriptionComplete?(finalText)
        } else if !didReceiveSpeech {
            print("🤫 No speech detected, silence timeout")
            onSilenceTimeout?()
        }
    }

    private func startNoSpeechTimer() {
        noSpeechTimer?.invalidate()
        noSpeechTimer = Timer.scheduledTimer(withTimeInterval: noSpeechTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRecording, !self.didReceiveSpeech else { return }
                print("🤫 No speech after \(self.noSpeechTimeout)s, stopping")
                self.stopRecording()
            }
        }
    }

    private func setupAndStartRecording() async throws {
        if useOnDevice {
            try await setupOnDeviceCapture()
            return
        }

        recognitionTask?.cancel()
        recognitionTask = nil

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else {
            throw TranscriptionError.setupFailed("Could not create recognition request")
        }
        recognitionRequest.shouldReportPartialResults = true

        // Try to reuse the shared audio engine from WakeWordService
        // This avoids stopping/starting the engine which fails in background
        if let provider = sharedAudioEngineProvider, provider.getAudioEngine() != nil {
            print("🎙️ Reusing shared audio engine via buffer forwarding")
            // Capture request directly — the closure is @Sendable so can't access @MainActor self
            let request = recognitionRequest
            provider.setAudioBufferForwarder { buffer in
                request.append(buffer)
            }
        } else {
            // Fallback: create our own engine (works in foreground only)
            print("🎙️ Creating dedicated audio engine (no shared engine available)")
            let audioEngine = AVAudioEngine()
            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)

            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
                self?.recognitionRequest?.append(buffer)
            }

            // BJ PR2 follow-up: activate the shared session off-main before the engine starts, so
            // the (usually-already-active) activation never blocks the main thread. Idempotent.
            await AudioSessionCoordinator.shared.ensureActiveOffMain()
            audioEngine.prepare()
            try audioEngine.start()
            self.fallbackAudioEngine = audioEngine
        }

        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            Task { @MainActor in
                self?.handleRecognitionResult(result: result, error: error)
            }
        }
    }

    /// Fallback engine used only when shared engine isn't available
    private var fallbackAudioEngine: AVAudioEngine?

    /// Clean up fallback engine and buffer forwarder when stopping
    private func cleanupEngine() {
        sharedAudioEngineProvider?.setAudioBufferForwarder(nil)
        if let engine = fallbackAudioEngine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            fallbackAudioEngine = nil
        }
    }

    // MARK: - On-device capture (SenseVoice)

    /// Accumulate the utterance's mono float samples (the recognizer resamples to 16 kHz on decode).
    private func setupOnDeviceCapture() async throws {
        let accumulate: @Sendable (AVAudioPCMBuffer) -> Void = { [weak self] buffer in
            guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
            let samples = Array(UnsafeBufferPointer(start: channels[0], count: Int(buffer.frameLength)))
            let rate = buffer.format.sampleRate
            Task { @MainActor [weak self] in
                guard let self, self.isRecording else { return }
                self.captureSampleRate = rate
                self.accumulatedSamples.append(contentsOf: samples)
                if !self.didReceiveSpeech {
                    self.didReceiveSpeech = true
                    self.noSpeechTimer?.invalidate()
                    self.noSpeechTimer = nil
                }
            }
        }

        if let provider = sharedAudioEngineProvider, provider.getAudioEngine() != nil {
            print("🎙️ On-device ASR: reusing shared audio engine")
            provider.setAudioBufferForwarder { buffer in accumulate(buffer) }
        } else {
            print("🎙️ On-device ASR: dedicated audio engine")
            let audioEngine = AVAudioEngine()
            let inputNode = audioEngine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in accumulate(buffer) }
            // BJ PR2 follow-up: activate off-main before the engine starts (see setupAndStartRecording).
            await AudioSessionCoordinator.shared.ensureActiveOffMain()
            audioEngine.prepare()
            try audioEngine.start()
            self.fallbackAudioEngine = audioEngine
        }
    }

    /// On stop, decode the accumulated buffer with SenseVoice and report the result (whole-utterance —
    /// no streaming partials).
    private func finishOnDeviceRecording() {
        cleanupEngine()
        isRecording = false
        let samples = accumulatedSamples
        let rate = captureSampleRate
        accumulatedSamples.removeAll(keepingCapacity: false)

        Task { @MainActor in
            do {
                let text = try await onDeviceEngine.transcribe(samples: samples, sampleRate: rate)
                if text.isEmpty {
                    print("🤫 On-device ASR: no speech recognized")
                    onSilenceTimeout?()
                } else {
                    print("📤 On-device transcription: \(text)")
                    currentTranscription = ""
                    onTranscriptionComplete?(text)
                }
            } catch {
                print("🎙️ On-device ASR failed: \(error)")
                errorMessage = error.localizedDescription
                onSilenceTimeout?()
            }
        }
    }

    private func handleRecognitionResult(result: SFSpeechRecognitionResult?, error: Error?) {
        if let result = result {
            currentTranscription = result.bestTranscription.formattedString
            if !didReceiveSpeech {
                didReceiveSpeech = true
                noSpeechTimer?.invalidate()
                noSpeechTimer = nil
            }
            resetSilenceTimer()

            if result.isFinal {
                cleanupEngine()
                stopRecording()
            }
        }

        if let error = error {
            print("Transcription error: \(error.localizedDescription)")
            cleanupEngine()
            stopRecording()
        }
    }

    private func resetSilenceTimer() {
        // Plan CU P1: purely a stamp — the window's length and firing are untouched. Arming it is
        // the last moment speech was observed, and that is what `stopRecording` records.
        lastSpeechObservedAt = Date()
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: silenceThreshold, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.cleanupEngine()
                self.stopRecording()
            }
        }
    }
}

enum TranscriptionError: LocalizedError {
    case setupFailed(String)
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .setupFailed(let msg): return "Setup failed: \(msg)"
        case .permissionDenied: return "Speech recognition permission denied"
        }
    }
}
