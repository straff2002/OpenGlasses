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

    struct CaptionEntry: Identifiable, CaptionSequenced {
        let id = UUID()
        let text: String
        let timestamp: Date
        /// Monotonic id assigned on insert. `captionHistory` is capped, so consumers cannot track
        /// their position by array count — they track this instead (see `CaptionCursor`).
        let seq: UInt64
        /// Diarized speaker id (`nil` = unlabeled / single-speaker path). Resolve to a display
        /// name via `speakerRegistry`.
        var speaker: Int? = nil
        /// Source-language transcript when `text` is a translation (BY P2) — the show-original
        /// ribbon. Nil on plain transcription paths.
        var original: String? = nil
        /// Detected source language of a translated caption (BY P3) — routes the entry to its
        /// leg in the two-way split view. Nil on plain transcription paths.
        var language: String? = nil
    }

    private var recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    /// Live diarized provider, used instead of `SFSpeechRecognizer` when
    /// `Config.isDiarizationConfigured`. Nil on the default (unlabeled) path.
    private var diarizer: DeepgramSTTService?

    /// Translated-caption provider, cloud tier (BY P2). Nil unless the session picked it.
    private var translator: GeminiTranslationProvider?

    /// Translated-caption provider, on-device tier (BY P3): SenseVoice → Apple Translation.
    private var onDeviceTranslator: OnDeviceTranslationProvider?

    /// The direction the live translation session was started with; nil when not translating.
    private var translationDirection: TranslationDirectionPolicy?

    /// Set by AppState — the Apple Translation engine (hosted in the app root) the on-device
    /// tier translates through, and reachability for the offline → on-device tier rule.
    weak var translationEngine: AppleTranslationEngine?
    weak var reachability: Reachability?

    /// Own ASR engine instance (model presence is filesystem state; the ~240 MB model itself
    /// loads lazily inside the recognizer, shared via the model directory).
    private let onDeviceASR = OnDeviceASREngine()

    /// Whether the live session is a translation session (either tier) — drives the two-way
    /// split overlay.
    var translationActive: Bool { translator != nil || onDeviceTranslator != nil }

    /// Maps diarization speaker ids to names/colours for the caption chips.
    let speakerRegistry = SpeakerRegistry()

    /// Presence-suspended (Plan W v2): captions stay user-`isActive` but the recognition session is
    /// torn down while the user is *away* (disconnected/backgrounded), auto-resuming on return. Never
    /// triggered by mere idle — a user reading captions silently is still engaged.
    private(set) var presenceSuspended = false

    /// Whether a live recognition session is actually running: user-`isActive` minus the presence
    /// suspension, which tears the session down without the wearer switching anything off.
    var isTranscribing: Bool { isActive && !presenceSuspended }

    /// Fired when `isTranscribing` changes. Set by AppState so continuous scene narration knows
    /// the ear is spoken for (Plan CV).
    ///
    /// Captions never speak, so this is not two voices competing — it is two things narration
    /// must not do while a transcript is being made: put its own synthesized voice into the
    /// wearer's caption history (this path runs `.playAndRecord`/`.default` with no voice
    /// processing, so narration's output is transcribed as if a person had said it, and flows on
    /// into summaries, Spotlight and Brain), and speak one sentence at a wearer who is reading a
    /// different one. Captions win because a caption is another person talking and cannot be
    /// repeated; a description of a room can wait, and `FrameGate` will describe the room again
    /// if it changes meanwhile.
    var onTranscribingChanged: ((Bool) -> Void)?

    /// Last value handed to `onTranscribingChanged`, so it fires on genuine edges only.
    private var lastTranscribing = false

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

    /// Ever-increasing caption id. Never reset — a consumer holding an older `seq` must not have
    /// it silently reused, or it would stop seeing new captions.
    private var nextSeq: UInt64 = 0

    private func makeSeq() -> UInt64 {
        nextSeq += 1
        return nextSeq
    }

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
            PrivacyLog.speech(.ambientCaptions, .recognizerUnavailable)
            return
        }

        isActive = true
        currentCaption = ""
        startRecognitionSession()
        syncTranscribing()
        PrivacyLog.speech(.ambientCaptions, .started)
    }

    func stop() {
        isActive = false
        presenceSuspended = false
        stopRecognitionSession()
        currentCaption = ""
        glassesDisplay?.clear()
        syncTranscribing()
        PrivacyLog.speech(.ambientCaptions, .stopped)
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
        syncTranscribing()
        PrivacyLog.speech(.ambientCaptions, .suspended, detail: PrivacyToken("presenceAway"))
    }

    /// Resume a presence-suspended caption stream when the user returns. No-op otherwise.
    func resumeForPresence() {
        guard isActive, presenceSuspended else { return }
        presenceSuspended = false
        startRecognitionSession()
        syncTranscribing()
        PrivacyLog.speech(.ambientCaptions, .resumed, detail: PrivacyToken("presence"))
    }

    /// Fire `onTranscribingChanged` if the live-session state actually changed. Called from every
    /// path that starts or tears one down, rather than from the recognizer callbacks: a session
    /// restarting for continuous recognition is not a gap anyone downstream should react to.
    private func syncTranscribing() {
        let now = isTranscribing
        guard now != lastTranscribing else { return }
        lastTranscribing = now
        onTranscribingChanged?(now)
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
        PrivacyLog.speech(.ambientCaptions, .reconfigured, detail: PrivacyToken("modeChange"))
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

        // Translated-caption path (BY P2/P3 — opt-in): tier picked per session — HIPAA/offline
        // route on-device, else cloud (`TranslationTierPolicy`). Takes precedence over
        // diarization (whether the two compose is an open BY decision, deferred with the
        // speaker-chip rail). An unavailable tier falls through to plain transcription.
        if Config.translationCaptionsEnabled, startTranslationSession() {
            return
        }

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
                        PrivacyLog.speech(.ambientCaptions, .recognitionFailed,
                                          error: SafeErrorSummary(error))
                        if self.isActive {
                            self.restartAfterDelay()
                        }
                    }
                }
            }
        }
    }

    /// Translated captions (BY P2/P3), fed by the same shared-engine buffer fan-out (no second
    /// mic session). Picks the tier per session and returns false when none is usable, so the
    /// caller falls through to plain transcription in the same invocation. Device-pending; the
    /// tier policy, stream folding, and utterance segmentation it relies on are unit-tested.
    private func startTranslationSession() -> Bool {
        let tier = TranslationTierPolicy.tier(
            hipaa: Config.hipaaMode,
            offline: !(reachability?.isOnline ?? true),
            cloudConfigured: Config.isTranslationCloudConfigured,
            onDeviceAvailable: onDeviceASR.isReady && translationEngine != nil)
        let direction = TranslationRouting.currentDirection()

        switch tier {
        case .cloud:
            let translator = GeminiTranslationProvider()
            translator.onSegment = { [weak self] segment in
                self?.handleTranslationSegment(segment)
            }
            do {
                try translator.start(direction: direction)
            } catch {
                PrivacyLog.speech(.liveTranslation, .providerUnavailable,
                                  detail: PrivacyToken("cloud"), error: SafeErrorSummary(error))
                return false
            }
            self.translator = translator
            translationDirection = direction
            wakeWordService?.addAudioBufferConsumer(id: "ambient_captions") { [weak self] buffer in
                Task { @MainActor in self?.translator?.sendAudio(buffer) }
            }
            return true

        case .onDevice:
            guard let engine = translationEngine else { return false }
            let provider = OnDeviceTranslationProvider(asr: onDeviceASR, engine: engine)
            provider.onSegment = { [weak self] segment in
                self?.handleTranslationSegment(segment)
            }
            do {
                try provider.start(direction: direction)
            } catch {
                PrivacyLog.speech(.liveTranslation, .providerUnavailable,
                                  detail: PrivacyToken("onDevice"), error: SafeErrorSummary(error))
                return false
            }
            onDeviceTranslator = provider
            translationDirection = direction
            wakeWordService?.addAudioBufferConsumer(id: "ambient_captions") { [weak self] buffer in
                Task { @MainActor in self?.onDeviceTranslator?.sendAudio(buffer) }
            }
            return true

        case .unavailable:
            PrivacyLog.speech(.liveTranslation, .translationUnavailable)
            return false
        }
    }

    /// Both tiers land here. The phone surface shows every leg; the in-lens HUD shows only the
    /// wearer's leg — in two-way, the line addressed to *them* (BY P3). Finals repeat the HUD
    /// text (a no-op for the cloud tier, where final == last interim; the only text the
    /// interim-less on-device tier ever shows).
    private func handleTranslationSegment(_ segment: TranslationSegment) {
        guard isActive else { return }
        let direction = translationDirection ?? .oneWay(target: Config.translationTargetLanguage)
        let wearerLeg = TranslationRouting.isWearerLeg(
            detected: segment.language, direction: direction,
            wearerLanguage: Config.translationWearerLanguage)
        if segment.isFinal {
            let renderLanguage = direction.renderLanguage(forDetected: segment.language)
                ?? Config.translationWearerLanguage
            if wearerLeg { glassesDisplay?.showText(segment.text) }
            finalizeCaption(segment.text, original: segment.original,
                            language: segment.language, expectedLocale: renderLanguage)
        } else {
            currentCaption = segment.text
            if wearerLeg { glassesDisplay?.showText(segment.text) }
            resetSilenceTimer()
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
        translator?.stop()
        translator = nil
        onDeviceTranslator?.stop()
        onDeviceTranslator = nil
        translationDirection = nil
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
        let entry = CaptionEntry(text: note, timestamp: Date(), seq: makeSeq())
        captionHistory.insert(entry, at: 0)
        if captionHistory.count > maxHistory {
            captionHistory = Array(captionHistory.prefix(maxHistory))
        }
        PrivacyLog.speech(.ambientCaptions, .noteInserted)
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

    private func finalizeCaption(_ text: String, speaker: Int? = nil, original: String? = nil,
                                 language: String? = nil, expectedLocale: String? = nil) {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        // BS P1: captions feed summaries, the Spotlight index, and Brain — drop
        // unmistakable silence-decode artifacts regardless of which engine produced them
        // (the filter is conservative; real speech passes). Translated captions pass their
        // target language as the expected locale — judging Chinese output against the device's
        // STT locale would flag every caption as a CJK hallucination (BY P2).
        let locale = expectedLocale ?? Config.speechRecognitionLocale
        guard TranscriptGuard.filter(text, expectedLocaleIdentifier: locale) != nil else {
            // The rejected text is still a transcript of what someone near the wearer said;
            // failing a quality filter does not reclassify it.
            PrivacyLog.speech(.ambientCaptions, .artifactDropped,
                              language: PrivacyToken(locale), characters: text.count)
            return
        }

        // Only add if it's meaningfully different from the last finalized text
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != lastFinalizedText else { return }

        lastFinalizedText = trimmed
        let entry = CaptionEntry(text: trimmed, timestamp: Date(), seq: makeSeq(),
                                 speaker: speaker, original: original, language: language)
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
                    // On the translation path the caption is target-language text — judge it
                    // against that locale, not the device STT locale (BY P2; see finalizeCaption).
                    let translating = self.translator != nil || self.onDeviceTranslator != nil
                    let locale = translating ? Config.translationWearerLanguage : nil
                    self.finalizeCaption(self.currentCaption, expectedLocale: locale)
                }
            }
        }
    }
}
