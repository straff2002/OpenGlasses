import Foundation
import Speech
import Combine

/// Provides real-time ambient captions — continuous transcription of surrounding speech.
/// Runs independently of the wake word / AI conversation pipeline.
/// Subscribes to audio buffers from WakeWordService's shared audio engine.
@MainActor
class AmbientCaptionService: ObservableObject {
    @Published var isActive = false
    @Published var currentCaption = ""
    @Published var captionHistory: [CaptionEntry] = []

    struct CaptionEntry: Identifiable {
        let id = UUID()
        let text: String
        let timestamp: Date
        /// Diarized speaker id (`nil` = unlabeled / single-speaker path). Resolve to a display
        /// name via `speakerRegistry`.
        var speaker: Int? = nil
    }

    private var recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    /// Live diarized provider, used instead of `SFSpeechRecognizer` when
    /// `Config.isDiarizationConfigured`. Nil on the default (unlabeled) path.
    private var diarizer: DeepgramSTTService?

    /// Maps diarization speaker ids to names/colours for the caption chips.
    let speakerRegistry = SpeakerRegistry()

    /// Presence-suspended (Plan W v2): captions stay user-`isActive` but the recognition session is
    /// torn down while the user is *away* (disconnected/backgrounded), auto-resuming on return. Never
    /// triggered by mere idle — a user reading captions silently is still engaged.
    private(set) var presenceSuspended = false

    /// Reference to the wake word service for audio buffer forwarding
    weak var wakeWordService: WakeWordService?

    /// Set by AppState — the live caption line is mirrored to the in-lens HUD when the
    /// Glasses Display feature is on. No-ops on glasses without a display.
    weak var glassesDisplay: GlassesDisplayService?

    /// Previous buffer forwarder (if transcription was using it)
    private var previousForwarder: ((AVAudioPCMBuffer) -> Void)?

    /// Timer to detect silence and finalize captions
    private var silenceTimer: Timer?
    private let silenceThreshold: TimeInterval = 2.0

    /// Max history entries to keep
    private let maxHistory = 50

    /// Rolling transcript for current utterance
    private var lastFinalizedText = ""

    // Plan BY P1 — caption mechanics behind `Config.captionCompactionEnabled` (default on;
    // behavior-preserving for short utterances by construction — a single-segment caption renders
    // and finalizes identically). The compactor keeps one caption entry accumulating across the
    // recognizer's premature endpoints; the debouncer decides which endpoints were premature.
    private var compactor = CaptionCompactor()
    private var endpointDebouncer = EndpointDebouncer()
    private var endpointCommitTask: Task<Void, Never>?

    init() {
        recognizer = SFSpeechRecognizer(locale: SpeechLocaleResolver.current)
    }

    // MARK: - Public API

    func start() {
        guard !isActive else { return }
        guard let recognizer = recognizer, recognizer.isAvailable else {
            print("🎙️ Captions: Speech recognizer not available")
            return
        }

        isActive = true
        currentCaption = ""
        startRecognitionSession()
        print("🎙️ Ambient captions started")
    }

    func stop() {
        isActive = false
        presenceSuspended = false
        stopRecognitionSession()
        currentCaption = ""
        glassesDisplay?.clear()
        print("🎙️ Ambient captions stopped")
    }

    /// Presence-aware suspend (Plan W v2): a user-started caption stream pauses only when the user is
    /// fully *away* (disconnected/backgrounded) — never on mere idle, since they may be silently
    /// reading. Keeps `isActive` true so it knows to resume. No-op unless captions are active.
    func suspendForPresence() {
        guard isActive, !presenceSuspended else { return }
        presenceSuspended = true
        stopRecognitionSession()
        currentCaption = ""
        glassesDisplay?.clear()
        print("🎙️ Ambient captions suspended (presence away)")
    }

    /// Resume a presence-suspended caption stream when the user returns. No-op otherwise.
    func resumeForPresence() {
        guard isActive, presenceSuspended else { return }
        presenceSuspended = false
        startRecognitionSession()
        print("🎙️ Ambient captions resumed (presence)")
    }

    /// Re-pick the transcription backend after a mode/config change (e.g. HIPAA toggled). If a
    /// session is live, tear it down and restart on the now-correct path: under HIPAA the cloud
    /// diarizer is gone and the on-device `SFSpeechRecognizer` takes over, so any Deepgram socket
    /// closes deterministically instead of waiting for the next audio buffer. No-op when inactive
    /// or presence-suspended (the suspend path already picks the right backend on resume).
    func reconfigureForModeChange() {
        guard isActive, !presenceSuspended else { return }
        stopRecognitionSession()
        startRecognitionSession()
        print("🎙️ Ambient captions reconfigured (mode change)")
    }

    func clearHistory() {
        captionHistory.removeAll()
    }

    // MARK: - Recognition Session

    private func startRecognitionSession() {
        // Plan W v2: never (re)start while presence-suspended — guards the continuous-recognition
        // self-restart paths (final-result / no-speech / error) from reviving a suspended stream.
        guard !presenceSuspended else { return }
        stopRecognitionSession()

        // Diarized path (opt-in, keyed, non-HIPAA): label captions with speaker chips via
        // Deepgram. When off/unconfigured this is skipped entirely and the on-device
        // SFSpeechRecognizer path below runs exactly as before.
        if Config.isDiarizationConfigured {
            startDiarizedSession()
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        self.recognitionRequest = request

        // Hook into the shared audio engine's buffer stream (named consumer)
        wakeWordService?.addAudioBufferConsumer(id: "ambient_captions") { [weak self] buffer in
            Task { @MainActor in
                self?.recognitionRequest?.append(buffer)
            }
        }

        recognitionTask = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self = self, self.isActive else { return }

                if let result = result {
                    let text = result.bestTranscription.formattedString
                    if Config.captionCompactionEnabled {
                        // Tokens arriving cancel a held endpoint: the previous "final" was a
                        // premature split, and this session's text continues the same caption.
                        if self.endpointDebouncer.tokensArrived(now: Date()) {
                            self.endpointCommitTask?.cancel()
                            self.compactor.beginContinuation()
                        }
                        self.compactor.acceptSegmentInterim(text)
                        let rendered = self.compactor.rendered
                        self.currentCaption = rendered
                        self.glassesDisplay?.showText(rendered)
                    } else {
                        self.currentCaption = text
                        self.glassesDisplay?.showText(text)
                    }
                    self.resetSilenceTimer()

                    if result.isFinal {
                        if Config.captionCompactionEnabled {
                            self.holdEndpointThenCommit()
                        } else {
                            self.finalizeCaption(text)
                        }
                        // Restart for continuous recognition
                        if self.isActive {
                            self.startRecognitionSession()
                        }
                    }
                }

                if let error = error {
                    let nsError = error as NSError
                    // Ignore cancellation errors and "no speech detected"
                    if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 1110 {
                        // No speech detected — restart
                        if self.isActive {
                            self.restartAfterDelay()
                        }
                    } else if nsError.code != 216 { // 216 = cancelled
                        print("🎙️ Captions error: \(error.localizedDescription)")
                        if self.isActive {
                            self.restartAfterDelay()
                        }
                    }
                }
            }
        }
    }

    /// Live diarized recognition via Deepgram, fed by the same shared-engine buffer fan-out the
    /// SFSpeech path uses (no second mic session). Device-pending; the JSON→segment parsing it
    /// relies on is unit-tested.
    private func startDiarizedSession() {
        let diarizer = DeepgramSTTService()
        diarizer.onSegment = { [weak self] segment in
            guard let self, self.isActive else { return }
            self.currentCaption = segment.text
            self.glassesDisplay?.showText(segment.text)
            self.resetSilenceTimer()
            if segment.isFinal {
                self.finalizeCaption(segment.text, speaker: segment.speaker)
            }
        }
        self.diarizer = diarizer
        diarizer.start()

        wakeWordService?.addAudioBufferConsumer(id: "ambient_captions") { [weak self] buffer in
            Task { @MainActor in self?.diarizer?.sendAudio(buffer) }
        }
    }

    private func stopRecognitionSession() {
        // Session teardown commits any pending caption rather than dropping it.
        endpointCommitTask?.cancel()
        endpointCommitTask = nil
        if Config.captionCompactionEnabled {
            endpointDebouncer.committed()
            let pending = compactor.finalize()
            if !pending.isEmpty { finalizeCaption(pending) }
        }
        silenceTimer?.invalidate()
        silenceTimer = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        diarizer?.stop()
        diarizer = nil
        wakeWordService?.removeAudioBufferConsumer(id: "ambient_captions")
    }

    private func restartAfterDelay() {
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
            if self.isActive {
                self.startRecognitionSession()
            }
        }
    }

    // MARK: - Caption Management

    /// Inject a visual description (photo caption) into the caption history.
    /// Used when a photo is taken during an audio recording so the meeting
    /// transcript and assistant have context about what was seen.
    func insertVisualNote(_ description: String) {
        let note = "[Visual: \(description)]"
        let entry = CaptionEntry(text: note, timestamp: Date())
        captionHistory.insert(entry, at: 0)
        if captionHistory.count > maxHistory {
            captionHistory = Array(captionHistory.prefix(maxHistory))
        }
        print("🎙️ Visual note inserted into caption history")
    }

    /// Hold the endpoint for the debounce window; commit only if no more tokens arrive (Plan BY).
    /// A premature endpoint is cancelled by `tokensArrived` in the recognition callback, and the
    /// caption keeps accumulating instead of splitting mid-sentence.
    private func holdEndpointThenCommit() {
        endpointDebouncer.endpointSignaled(now: Date())
        endpointCommitTask?.cancel()
        endpointCommitTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(self.endpointDebouncer.holdInterval * 1_000_000_000))
            guard !Task.isCancelled, self.endpointDebouncer.shouldCommit(now: Date()) else { return }
            self.endpointDebouncer.committed()
            let final = self.compactor.finalize()
            self.finalizeCaption(final)
        }
    }

    private func finalizeCaption(_ text: String, speaker: Int? = nil) {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        // BS P1: captions feed summaries, the Spotlight index, and Brain — drop
        // unmistakable silence-decode artifacts regardless of which engine produced them
        // (the filter is conservative; real speech passes).
        guard TranscriptGuard.filter(text, expectedLocaleIdentifier: Config.speechRecognitionLocale) != nil else {
            NSLog("[Captions] Artifact filter dropped caption: %@", String(text.prefix(60)))
            return
        }

        // Only add if it's meaningfully different from the last finalized text
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != lastFinalizedText else { return }

        lastFinalizedText = trimmed
        let entry = CaptionEntry(text: trimmed, timestamp: Date(), speaker: speaker)
        captionHistory.insert(entry, at: 0)

        // Trim history
        if captionHistory.count > maxHistory {
            captionHistory = Array(captionHistory.prefix(maxHistory))
        }

        currentCaption = ""
    }

    private func resetSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: silenceThreshold, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                if !self.currentCaption.isEmpty {
                    self.finalizeCaption(self.currentCaption)
                }
            }
        }
    }
}
