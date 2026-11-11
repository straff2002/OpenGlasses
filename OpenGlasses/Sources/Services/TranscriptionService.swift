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
    /// CO Item 4 + Plan FE P3: the silence window before the conversation ends. The wearer's
    /// chosen window, widened when the assistant's own answer was a question they still have to
    /// think about. The ledger is what makes "a settings change applies from the next turn" true:
    /// the value is fixed once, in `startRecording()`, and nothing moves it mid-utterance.
    private var turnWindow = SpeechTurnWindowLedger()

    private var silenceThreshold: TimeInterval { turnWindow.currentWindow }

    /// Where the wearer's chosen pause comes from. A closure rather than a direct `Config` read so
    /// the adoption rule can be exercised without `UserDefaults`; the default reads the preference
    /// live, every turn, which is the point.
    var userPauseWindowProvider: () -> TimeInterval = { Config.speechPauseWindow }

    /// Tell the transcriber what the assistant just said, so the next silence window can account
    /// for a question. Called from the TTS completion path.
    ///
    /// Deliberately does not re-arm anything: if a turn is somehow still running, it keeps the
    /// window it started with, exactly as it does across a settings change.
    func noteAssistantSpoke(_ text: String?) {
        turnWindow.noteAssistantSpoke(text)
    }
    private let noSpeechTimeout: TimeInterval = 10.0
    private var didReceiveSpeech: Bool = false

    // MARK: - The last word (stopped Apple turns)

    /// An Apple Speech turn that has stopped capturing and is waiting, bounded, for the
    /// recogniser's final result — the one that carries the word the partials were still holding.
    private struct StoppedAppleTurn {
        let generation: Int
        var transcript: StoppedTurnTranscript
        let heardSpeech: Bool
        let task: SFSpeechRecognitionTask?
        let stoppedAt: Date
        var timeout: Task<Void, Never>?
    }
    private var stoppedAppleTurn: StoppedAppleTurn?
    /// Which recognition task a result belongs to, so a stopped turn's late final is never taken
    /// for the next turn's partial.
    private var appleTurnGeneration = 0
    /// How the recogniser ended this turn itself (its final result, or an error), when it did — a
    /// stop then has nothing more to wait for.
    private var appleRecognizerEnded: StoppedTurnTranscript.Settlement?

    /// How long capture runs on after the wearer presses stop. The last word is often still on
    /// its way when the press lands — a Bluetooth mic delivers audio a beat behind the voice — and
    /// a stop that ends the request at once cuts it off. Short enough not to be felt.
    static let wearerStopTail: TimeInterval = 0.35
    private var pendingTailStop: Task<Void, Never>?

    // MARK: - Acoustic end-of-turn (Plan CU P2)

    /// The detector, when one is installed. Nil — or installed but unavailable — takes
    /// `EndOfTurnPolicy` rule 1, where the silence timer decides alone and this file behaves exactly
    /// as it did before P2.
    var speechActivityDetector: SpeechActivityDetecting? {
        didSet {
            oldValue?.onEvent = nil
            speechActivityDetector?.onEvent = { [weak self] event in
                self?.handleSpeechActivity(event)
            }
        }
    }

    /// When the detector says the wearer stopped — the moment silence began, not when it was
    /// confirmed. Nil while they are still talking, and nil again for each new utterance.
    private var acousticSpeechEndedAt: Date?

    /// Whether the detector has heard speech in this utterance. Kept apart from `didReceiveSpeech`
    /// (the recognizer's opinion) because `EndOfTurnPolicy` rule 3 turns on *neither* having heard
    /// anything, and a voice the recognizer cannot parse is still a wearer who is talking.
    private var acousticSpeechObserved: Bool = false

    /// Which signal ended this utterance, once one has.
    private var endOfTurnReason: EndOfTurnPolicy.Reason?

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

    // MARK: - Hearing the words we know are coming (Plan JM P0)

    /// The contextual strings for the next Apple Speech turn, built by `DictationVocabulary` from
    /// the job, the van, the vaults, the wake phrases and the trade. Read once per turn in
    /// `setupAndStartRecording()`, so a job change applies from the next turn. The on-device
    /// engine takes no hints and never calls it. Empty by default: AppState installs the real one.
    var vocabularyProvider: () -> [String] = { [] }

    /// The conversation mic the wearer chose, and the developer switch for the phone-mic voice
    /// processing experiment. Closures so `DictationCapturePolicy`'s inputs are read live per turn.
    var micRouteProvider: () -> MicRoute = { Config.conversationMicRoute }
    var voiceProcessingSwitchProvider: () -> Bool = { Config.dictationVoiceProcessingEnabled }

    // MARK: - Engines (Additional Capabilities #8, Plan JM P2)
    //
    // Three capture shapes (`ASREngine.CaptureShape`):
    // - Apple streaming: buffers into `SFSpeechAudioBufferRecognitionRequest`, partials as spoken.
    // - Whole utterance: the on-device SenseVoice engine and OpenAI's transcription endpoint. The
    //   utterance's PCM is accumulated and decoded (or uploaded) once on stop. For SenseVoice the
    //   turn ends on the caller's `stopRecording()` (or the no-speech timeout), as it always has;
    //   for OpenAI an energy gate over the same buffers arms the silence window, because an upload
    //   engine has no partials to arm it with.
    // - Cloud streaming: Deepgram. Buffers stream to the socket; partials arrive as spoken and arm
    //   the silence window exactly as Apple's do.
    private let onDeviceEngine = OnDeviceASREngine()
    /// The engine this turn runs on — chosen once, in `startRecording()`.
    private(set) var activeEngine: ASREngine = .appleSpeech
    /// The next engine in the chain, taken if a cloud engine cannot be set up for this turn.
    private var fallbackEngine: ASREngine?
    private var accumulatedSamples: [Float] = []
    private var captureSampleRate: Double = 16000

    /// Plan JM P2: whether the question's audio may go to a cloud recogniser right now. Read when
    /// the engine is chosen, by the Deepgram service on every buffer, and before the OpenAI upload.
    var cloudDictationGate: CloudDictationGate = .live
    /// Whether the phone is online. A cloud preference offline behaves as `.auto` for the turn.
    /// AppState installs the live reachability; the default keeps today's "assume online".
    var onlineProvider: () -> Bool = { true }
    private let deepgramDictation = DeepgramDictationService()
    private let openAIDictation = OpenAIDictationService()
    /// The vocabulary read at the start of this turn, for the cloud engines.
    private var turnVocabulary: [String] = []
    /// The energy gate that stands in for partials on the OpenAI upload path.
    private var utteranceScorer = EnergySpeechScorer(gateConfiguration: .default)
    private var utteranceGate = SpeechActivityGate(configuration: .default)

    // MARK: - The last question, kept for the recogniser comparison (Plan JM P3)

    /// Whether this turn's audio may be kept: the developer switch, and (installed by AppState) the
    /// app on screen. Read when a turn starts and again when it ends.
    var comparisonRetentionAllowedProvider: () -> Bool = { Config.recognizerComparisonEnabled }
    private var utteranceRetention = UtteranceRetention()
    /// The most recent question that heard speech, while the comparison switch is on. Memory only;
    /// replaced by the next one, forgotten by `forgetKeptUtterance()`.
    @Published private(set) var lastUtterance: KeptUtterance?

    /// Dictation's own on-device engine, so the comparison does not load the model a second time.
    var onDeviceRecognizer: OnDeviceASREngine { onDeviceEngine }

    /// Forget the kept question — the switch went off, or the app left the screen.
    func forgetKeptUtterance() {
        utteranceRetention.clear()
        if lastUtterance != nil { lastUtterance = nil }
    }

    /// A tap that copies each buffer into the retention, or nil when this turn keeps nothing. Bound
    /// to this turn, so a buffer that lands after the next turn began is dropped.
    private func comparisonTap() -> (@Sendable (AVAudioPCMBuffer) -> Void)? {
        guard utteranceRetention.isCollecting else { return nil }
        let turn = utteranceRetention.turn
        return { [weak self] buffer in
            guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
            let samples = Array(UnsafeBufferPointer(start: channels[0], count: Int(buffer.frameLength)))
            let rate = buffer.format.sampleRate
            Task { @MainActor [weak self] in
                self?.utteranceRetention.append(samples, sampleRate: rate, turn: turn)
            }
        }
    }

    /// The turn ended: keep it if it heard speech and keeping is still allowed. Only the count is
    /// logged.
    private func keepLastUtterance(heardSpeech: Bool) {
        if activeEngine.captureShape == .wholeUtterance, utteranceRetention.isCollecting {
            // The whole-utterance engines already hold the samples; no second tap.
            utteranceRetention.append(accumulatedSamples, sampleRate: captureSampleRate,
                                      turn: utteranceRetention.turn)
        }
        let allowed = comparisonRetentionAllowedProvider()
        if let count = utteranceRetention.endTurn(heardSpeech: heardSpeech, allowed: allowed, at: Date()) {
            lastUtterance = utteranceRetention.kept
            PrivacyLog.speech(.dictation, .utteranceKept, count: count)
        } else if !allowed, lastUtterance != nil {
            lastUtterance = nil
        }
    }

    init() {
        speechRecognizer = SFSpeechRecognizer(locale: SpeechLocaleResolver.current)
    }

    /// Recreate the recogniser for the current speech-language setting (built once at init).
    /// Takes effect from the next turn; a turn in progress keeps the recogniser it started on.
    func reloadRecognizer() {
        speechRecognizer = SFSpeechRecognizer(locale: SpeechLocaleResolver.current)
    }

    func startRecording() {
        // A second start on a live recorder is a no-op, and a silent one used to leave no trace
        // at all — the other half of "the assistant spoke and then nothing happened".
        guard !isRecording else {
            PrivacyLog.speech(.dictation, .startSkippedAlreadyRecording)
            return
        }
        // A stopped turn still waiting for its final result goes out first, with what it has, so
        // turns are delivered in the order they were spoken.
        settleStoppedAppleTurn(timedOut: true)

        // Plan FE P3: the one moment the window is chosen. Read the preference now, hold it for
        // the whole turn — a change made while the wearer is mid-sentence applies to the next one.
        let window = turnWindow.beginTurn(userWindow: userPauseWindowProvider())
        PrivacyLog.speech(.dictation, .reconfigured, seconds: window,
                          detail: PrivacyToken(turnWindow.isQuestionWidened ? "questionShaped" : "base"))

        didReceiveSpeech = false
        lastSpeechObservedAt = nil
        acousticSpeechEndedAt = nil
        acousticSpeechObserved = false
        endOfTurnReason = nil
        speechActivityDetector?.begin()
        currentTranscription = ""
        // Plan CU P1: a new utterance means the previous one has been dealt with, whatever became
        // of it — the turn that answered it has already claimed its stamps, and a voice command
        // that never became a turn must not leave one behind for the next one to inherit.
        TurnRecorder.forgetPendingUtterance()

        // Pick the recognizer: a chosen cloud engine when it is allowed and we are online, else
        // on-device SenseVoice when selected + its model is ready, else Apple.
        chooseEngine()
        accumulatedSamples.removeAll(keepingCapacity: true)
        // Plan JM P3: this turn's audio is kept only with the comparison switch on.
        utteranceRetention.beginTurn(allowed: comparisonRetentionAllowedProvider())
        if !utteranceRetention.isCollecting, lastUtterance != nil { lastUtterance = nil }
        utteranceScorer.reset()
        utteranceGate = SpeechActivityGate(configuration: .default)

        // BJ PR2 follow-up: the fallback engine start may activate the shared session off the main
        // thread now, so setup is async. Keep `startRecording()` synchronous (its ~8 callers are
        // unchanged): mark recording optimistically, run setup on the next tick, roll back on failure.
        isRecording = true
        Task { @MainActor in
            do {
                do {
                    try await setupAndStartRecording()
                } catch where activeEngine.isCloud {
                    // A cloud engine that cannot start this turn hands it to the next engine in
                    // the chain, once — the wearer is mid-question, not choosing a recognizer.
                    PrivacyLog.speech(.dictation, .cloudFallback, detail: PrivacyToken("setupFailed"),
                                      error: SafeErrorSummary(error))
                    cleanupEngine()
                    activeEngine = fallbackEngine ?? .appleSpeech
                    try await setupAndStartRecording()
                }
                PrivacyLog.speech(.dictation, .started)
                startNoSpeechTimer()
            } catch {
                PrivacyLog.speech(.dictation, .engineFailed, error: SafeErrorSummary(error))
                errorMessage = error.localizedDescription
                isRecording = false
            }
        }
    }

    /// Choose this turn's engine from the selector, with the live cloud gate and reachability.
    private func chooseEngine() {
        let gate = cloudDictationGate
        let preference = gate.preference()
        let hipaa = gate.hipaa()
        let online = onlineProvider()
        let availability = ASREngineSelector.Availability(
            appleSpeechReady: speechRecognizer?.isAvailable ?? false,
            onDeviceReady: onDeviceEngine.isReady,
            online: online,
            deepgramReady: gate.isConfigured(provider: .deepgram),
            openAIReady: gate.isConfigured(provider: .openAI)
        )
        let chain = ASREngineSelector.chain(preference: preference, availability: availability, hipaa: hipaa)
        activeEngine = chain.first ?? .appleSpeech
        fallbackEngine = chain.dropFirst().first
        turnVocabulary = activeEngine.isCloud ? vocabularyProvider() : []

        // A chosen cloud engine that did not take the turn says why, as a token — never silently.
        if let cloud = preference.cloudEngine, activeEngine != cloud {
            let reason: String
            if hipaa { reason = "hipaa" }
            else if !availability.isReady(cloud) { reason = "notConfigured" }
            else { reason = "offline" }
            PrivacyLog.speech(.dictation, .cloudFallback, detail: PrivacyToken(reason))
        }
    }

    /// The wearer pressed stop (the Tap to stop button, the watch): let the word they were finishing
    /// reach the recogniser, then end the turn. Returns once the turn has stopped capturing — its
    /// transcript is delivered when the recogniser settles, as for every stop.
    func stopRecordingAfterTail() async {
        guard isRecording else { return }
        if pendingTailStop == nil {
            pendingTailStop = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.wearerStopTail * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                self.pendingTailStop = nil
                self.stopRecording()
            }
        }
        await pendingTailStop?.value
    }

    func stopRecording() {
        // Any stop supersedes a tail still running; the tail's own stop arrives here too.
        pendingTailStop?.cancel()
        pendingTailStop = nil
        guard isRecording else { return }

        // Plan CU P1: the mic went quiet when the silence window now expiring was ARMED, not when
        // it expired — see `lastSpeechObservedAt`. Falls back to now for the stops that never armed
        // one: the on-device engine (whole-buffer, no partials at all), a recognizer error, or an
        // external stop before any speech arrived. Stamped before the on-device branch below, whose
        // SenseVoice decode runs after the mic went quiet and belongs to the wait, not the speech.
        //
        // Plan CU P2: when the detector ended the turn, its stamp is the better one — the moment
        // the wearer actually went quiet, rather than the last time the recognizer happened to emit
        // a partial (which lags it by up to a burst gap). Preferring it here is what lets
        // `perceivedLatency` show the floor being removed instead of absorbing it.
        TurnRecorder.noteSpeechEnd(at: acousticSpeechEndedAt ?? lastSpeechObservedAt ?? Date())
        if let reason = endOfTurnReason { TurnRecorder.noteEndOfTurnReason(reason) }
        TurnRecorder.noteTranscriber(activeEngine)
        lastSpeechObservedAt = nil
        acousticSpeechEndedAt = nil
        speechActivityDetector?.end()

        silenceTimer?.invalidate()
        silenceTimer = nil
        noSpeechTimer?.invalidate()
        noSpeechTimer = nil
        keepLastUtterance(heardSpeech: didReceiveSpeech)

        switch activeEngine.captureShape {
        case .wholeUtterance:
            finishWholeUtteranceRecording()
            return
        case .cloudStreaming:
            finishCloudStreamingRecording()
            return
        case .appleStreaming:
            finishAppleStreamingRecording()
        }
    }

    /// On stop, end the Apple request and wait (bounded) for the final result before delivering.
    ///
    /// The last partial is not the transcript: the recogniser holds back the word being spoken and
    /// settles it only in the final result that `endAudio()` produces. Delivering the partial at
    /// the stop dropped that word. When the recogniser has already ended the turn itself (its final
    /// arrived, or it failed) there is nothing to wait for.
    private func finishAppleStreamingRecording() {
        // No more buffers: the request is about to end. The external stops used to leave the
        // forwarder (or the dedicated engine) appending to an ended request until the next turn.
        cleanupEngine()
        isRecording = false
        let request = recognitionRequest
        let task = recognitionTask
        recognitionRequest = nil
        recognitionTask = nil

        var stopped = StoppedAppleTurn(generation: appleTurnGeneration,
                                       transcript: StoppedTurnTranscript(shown: currentTranscription),
                                       heardSpeech: didReceiveSpeech, task: task, stoppedAt: Date())
        guard task != nil, appleRecognizerEnded == nil else {
            if appleRecognizerEnded == .final {
                stopped.transcript.noteResult(currentTranscription, isFinal: true)
            } else {
                stopped.transcript.noteEnded()
            }
            deliverStoppedAppleTurn(stopped)
            return
        }
        request?.endAudio()
        let generation = stopped.generation
        stopped.timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(StoppedTurnTranscript.finalResultTimeout * 1_000_000_000))
            guard let self, !Task.isCancelled, self.stoppedAppleTurn?.generation == generation else { return }
            self.settleStoppedAppleTurn(timedOut: true)
        }
        stoppedAppleTurn = stopped
    }

    /// Deliver the stopped turn now: with its final result if it came, else with what was heard.
    private func settleStoppedAppleTurn(timedOut: Bool) {
        guard var stopped = stoppedAppleTurn else { return }
        stoppedAppleTurn = nil
        stopped.timeout?.cancel()
        if timedOut, !stopped.transcript.isSettled {
            stopped.transcript.noteTimedOut()
            stopped.task?.cancel()
        }
        deliverStoppedAppleTurn(stopped)
    }

    /// The one delivery for Apple turns — unchanged in what it does with the words: a transcript
    /// goes to `onTranscriptionComplete`; a turn that never heard speech ends on the no-speech path.
    private func deliverStoppedAppleTurn(_ stopped: StoppedAppleTurn) {
        let finalText = stopped.transcript.text
        // Only clear the live transcript when no new turn has started showing its own.
        if !isRecording { currentTranscription = "" }
        if !finalText.isEmpty {
            PrivacyLog.speech(.dictation, .transcriptDelivered, characters: finalText.count,
                              seconds: Date().timeIntervalSince(stopped.stoppedAt),
                              detail: PrivacyToken(stopped.transcript.settlement?.rawValue ?? "shown"))
            onTranscriptionComplete?(finalText)
        } else if !stopped.heardSpeech {
            PrivacyLog.speech(.dictation, .noSpeechDetected, detail: PrivacyToken("silenceWindow"))
            onSilenceTimeout?()
        }
    }

    private func startNoSpeechTimer() {
        noSpeechTimer?.invalidate()
        noSpeechTimer = Timer.scheduledTimer(withTimeInterval: noSpeechTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRecording, !self.didReceiveSpeech else { return }
                PrivacyLog.speech(.dictation, .noSpeechDetected, seconds: self.noSpeechTimeout,
                                  detail: PrivacyToken("timeout"))
                self.stopRecording()
            }
        }
    }

    private func setupAndStartRecording() async throws {
        switch activeEngine.captureShape {
        case .wholeUtterance:
            try await setupWholeUtteranceCapture()
            return
        case .cloudStreaming:
            try await setupCloudStreamingCapture()
            return
        case .appleStreaming:
            break
        }

        recognitionTask?.cancel()
        recognitionTask = nil
        appleTurnGeneration += 1
        appleRecognizerEnded = nil
        let generation = appleTurnGeneration

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else {
            throw TranscriptionError.setupFailed("Could not create recognition request")
        }
        recognitionRequest.shouldReportPartialResults = true
        // Plan JM P0: tell the recogniser which words are likely. The count is logged, never a word.
        let vocabulary = vocabularyProvider()
        if !vocabulary.isEmpty {
            recognitionRequest.contextualStrings = vocabulary
            PrivacyLog.speech(.dictation, .vocabularyApplied, count: vocabulary.count)
        }

        // Try to reuse the shared audio engine from WakeWordService
        // This avoids stopping/starting the engine which fails in background
        if let provider = sharedAudioEngineProvider, provider.getAudioEngine() != nil {
            PrivacyLog.speech(.dictation, .engineShared)
            // Capture request directly — the closure is @Sendable so can't access @MainActor self
            let request = recognitionRequest
            let keep = comparisonTap()
            provider.setAudioBufferForwarder { buffer in
                request.append(buffer)
                keep?(buffer)
            }
        } else {
            // Fallback: create our own engine (works in foreground only)
            PrivacyLog.speech(.dictation, .engineDedicated)
            // BJ PR2 follow-up: activate the shared session off-main before the engine starts, so
            // the (usually-already-active) activation never blocks the main thread. Idempotent.
            // Activated BEFORE the input format is read: an inactive session reports an empty
            // input format, and a tap on that is the uncatchable crash `requireUsableTapFormat`
            // guards against.
            await AudioSessionCoordinator.shared.ensureActiveOffMain()
            var audioEngine = AVAudioEngine()
            // Plan JM P0: the phone-mic voice-processing experiment. Turned on BEFORE the format is
            // read and the tap installed — it reformats the input node — and only on an engine this
            // service owns. A failure, or the dead-IO format it can leave behind, falls back to a
            // fresh engine without it: the turn is never lost to the experiment.
            fallbackVoiceProcessing = false
            if DictationCapturePolicy.voiceProcessing(route: Self.liveCaptureRoute(configured: micRouteProvider()),
                                                      engine: .dedicated,
                                                      developerSwitch: voiceProcessingSwitchProvider()) {
                do {
                    try audioEngine.inputNode.setVoiceProcessingEnabled(true)
                    let processed = audioEngine.inputNode.outputFormat(forBus: 0)
                    switch VoiceProcessingProbe.verdict(sampleRate: processed.sampleRate,
                                                        channelCount: processed.channelCount) {
                    case .usable:
                        fallbackVoiceProcessing = true
                        PrivacyLog.speech(.dictation, .voiceProcessingOn)
                    case .deadIO:
                        PrivacyLog.speech(.dictation, .voiceProcessingFailed, detail: PrivacyToken("deadIO"))
                        audioEngine = AVAudioEngine()
                    }
                } catch {
                    PrivacyLog.speech(.dictation, .voiceProcessingFailed, error: SafeErrorSummary(error))
                    audioEngine = AVAudioEngine()
                }
            }
            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            try Self.requireUsableTapFormat(recordingFormat, channel: .dictation)

            let keep = comparisonTap()
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
                self?.recognitionRequest?.append(buffer)
                keep?(buffer)
            }

            audioEngine.prepare()
            try audioEngine.start()
            self.fallbackAudioEngine = audioEngine
        }

        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            Task { @MainActor in
                self?.handleRecognitionResult(result: result, error: error, generation: generation)
            }
        }
    }

    /// Fallback engine used only when shared engine isn't available
    private var fallbackAudioEngine: AVAudioEngine?
    /// Whether the fallback engine's input node has voice processing on, so cleanup turns it off.
    private var fallbackVoiceProcessing = false

    /// The route `DictationCapturePolicy` judges: the wearer's chosen route, but only while the
    /// session's live input really is the phone's built-in mic. A conversation that was meant for
    /// the phone and landed on a Bluetooth input — or meant for the glasses and fell back to the
    /// phone — is not treated as the phone mic, so the experiment never touches a hands-free link.
    private static func liveCaptureRoute(configured: MicRoute) -> MicRoute {
        guard configured == .phone else { return configured }
        let inputs = AVAudioSession.sharedInstance().currentRoute.inputs.map(\.portType)
        let onBuiltInMic = inputs.contains(.builtInMic) && !MicRoutePolicy.containsBluetoothMic(inputs)
        // Not the built-in mic despite the choice: judge it as the external input it is.
        return onBuiltInMic ? .phone : .headset
    }

    /// The dedicated-engine guard. The microphone is unavailable — backgrounded behind another
    /// app that holds it (the "in background with Meta AI open" crash in TestFlight build 463),
    /// or a route mid-change — exactly when the input node reports an empty format, and
    /// `installTap` on an empty format raises an Objective-C exception that no `catch` sees.
    /// Refuse here instead, with the error `startRecording()` already logs and rolls back on.
    private static func requireUsableTapFormat(_ format: AVAudioFormat,
                                               channel: PrivacyLog.SpeechChannel) throws {
        guard AudioFormatFactory.isUsableTapFormat(format) else {
            PrivacyLog.speech(channel, .engineFailed, detail: PrivacyToken("formatInvalid"))
            throw TranscriptionError.setupFailed("Microphone unavailable")
        }
    }

    /// Clean up fallback engine and buffer forwarder when stopping
    private func cleanupEngine() {
        sharedAudioEngineProvider?.setAudioBufferForwarder(nil)
        if let engine = fallbackAudioEngine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            if fallbackVoiceProcessing {
                try? engine.inputNode.setVoiceProcessingEnabled(false)
                fallbackVoiceProcessing = false
            }
            fallbackAudioEngine = nil
        }
    }

    // MARK: - Capture for the whole-utterance and cloud-streaming engines

    /// Hand every captured buffer to `forward`: through the wake-word engine's tap when it is
    /// running, else on a dedicated engine of our own (foreground only). One tap either way.
    private func installCapture(channel: PrivacyLog.SpeechChannel,
                                forward: @escaping @Sendable (AVAudioPCMBuffer) -> Void) async throws {
        if let provider = sharedAudioEngineProvider, provider.getAudioEngine() != nil {
            PrivacyLog.speech(channel, .engineShared)
            provider.setAudioBufferForwarder { buffer in forward(buffer) }
        } else {
            PrivacyLog.speech(channel, .engineDedicated)
            // BJ PR2 follow-up: activate off-main before the engine starts — and before the input
            // format is read (see setupAndStartRecording).
            await AudioSessionCoordinator.shared.ensureActiveOffMain()
            let audioEngine = AVAudioEngine()
            let inputNode = audioEngine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            try Self.requireUsableTapFormat(format, channel: channel)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in forward(buffer) }
            audioEngine.prepare()
            try audioEngine.start()
            self.fallbackAudioEngine = audioEngine
        }
    }

    /// Accumulate the utterance's mono float samples (SenseVoice resamples to 16 kHz on decode; the
    /// OpenAI upload resamples to 16 kHz before encoding).
    private func setupWholeUtteranceCapture() async throws {
        let engine = activeEngine
        let accumulate: @Sendable (AVAudioPCMBuffer) -> Void = { [weak self] buffer in
            guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
            let samples = Array(UnsafeBufferPointer(start: channels[0], count: Int(buffer.frameLength)))
            let rate = buffer.format.sampleRate
            Task { @MainActor [weak self] in
                guard let self, self.isRecording, self.activeEngine == engine else { return }
                self.captureSampleRate = rate
                self.accumulatedSamples.append(contentsOf: samples)
                if engine == .onDevice {
                    // Unchanged: the first buffer counts as speech for the on-device engine.
                    if !self.didReceiveSpeech {
                        self.didReceiveSpeech = true
                        self.noSpeechTimer?.invalidate()
                        self.noSpeechTimer = nil
                    }
                } else {
                    self.observeUtteranceEnergy(samples, sampleRate: rate)
                }
            }
        }
        try await installCapture(channel: engine == .onDevice ? .onDeviceASR : .cloudDictation,
                                 forward: accumulate)
    }

    /// The upload engine's stand-in for partials: while the energy gate hears speech, the silence
    /// window is re-armed, so the turn ends that window after the wearer stops — and a turn in which
    /// nothing was ever heard ends on the no-speech timeout without uploading anything.
    private func observeUtteranceEnergy(_ samples: [Float], sampleRate: Double) {
        let score = utteranceScorer.score(samples, sampleRate: sampleRate)
        _ = utteranceGate.observe(score: score, at: Date())
        guard utteranceGate.isSpeaking else { return }
        if !didReceiveSpeech {
            didReceiveSpeech = true
            noSpeechTimer?.invalidate()
            noSpeechTimer = nil
        }
        resetSilenceTimer()
    }

    /// Deepgram: stream each buffer, as linear16 mono at its own rate, to the dictation socket.
    /// The service re-reads the gate on every buffer.
    private func setupCloudStreamingCapture() async throws {
        let service = deepgramDictation
        let gate = cloudDictationGate
        service.isAllowed = { gate.isConfigured(provider: .deepgram) }
        service.onTranscript = { [weak self] text in self?.handleCloudTranscript(text) }
        service.onStopped = { [weak self] reason in self?.handleCloudStreamStopped(reason) }
        guard service.start(vocabulary: turnVocabulary) else {
            throw TranscriptionError.setupFailed("Cloud dictation unavailable")
        }
        if !turnVocabulary.isEmpty {
            PrivacyLog.speech(.cloudDictation, .vocabularyApplied, count: turnVocabulary.count)
        }
        do {
            let keep = comparisonTap()
            try await installCapture(channel: .cloudDictation) { buffer in
                keep?(buffer)
                let data = PCMConverter.linear16Mono(from: buffer)
                let rate = Int(buffer.format.sampleRate.rounded())
                Task { @MainActor in service.sendAudio(data, sampleRate: rate) }
            }
        } catch {
            service.cancel()
            throw error
        }
    }

    /// A Deepgram partial or final: the live transcript, and a re-armed silence window.
    private func handleCloudTranscript(_ text: String) {
        guard isRecording, activeEngine == .deepgram else { return }
        currentTranscription = text
        if !didReceiveSpeech {
            didReceiveSpeech = true
            noSpeechTimer?.invalidate()
            noSpeechTimer = nil
        }
        resetSilenceTimer()
    }

    /// The Deepgram stream stopped mid-turn: the gate closed (HIPAA, the choice revoked, a pin) or
    /// the socket failed. The audio has already stopped leaving; end the turn with what was heard,
    /// which is the ordinary no-speech path when nothing was.
    private func handleCloudStreamStopped(_ reason: String) {
        guard isRecording, activeEngine == .deepgram else { return }
        PrivacyLog.speech(.dictation, .cloudFallback, detail: PrivacyToken(reason))
        cleanupEngine()
        stopRecording()
    }

    /// On stop, close the Deepgram stream, wait (bounded) for its last final, and deliver through
    /// the same `onTranscriptionComplete` every engine uses.
    private func finishCloudStreamingRecording() {
        cleanupEngine()
        isRecording = false
        let service = deepgramDictation
        let shown = currentTranscription
        Task { @MainActor in
            let heard = await service.finish()
            deliverTranscript(heard.isEmpty ? shown : heard, channel: .cloudDictation)
        }
    }

    /// On stop, decode the accumulated buffer with SenseVoice — or upload it to OpenAI — and report
    /// the result (whole-utterance — no streaming partials).
    private func finishWholeUtteranceRecording() {
        cleanupEngine()
        isRecording = false
        let samples = accumulatedSamples
        let rate = captureSampleRate
        let engine = activeEngine
        let heardSpeech = didReceiveSpeech
        let vocabulary = turnVocabulary
        accumulatedSamples.removeAll(keepingCapacity: false)

        Task { @MainActor in
            switch engine {
            case .openAI:
                await finishOpenAIUtterance(samples: samples, sampleRate: rate,
                                            heardSpeech: heardSpeech, vocabulary: vocabulary)
            default:
                await decodeOnDevice(samples: samples, sampleRate: rate)
            }
        }
    }

    /// One upload, timed into the log. On failure the same samples go to the on-device engine when
    /// it is ready; otherwise the turn ends on the ordinary no-speech path. Never retried.
    private func finishOpenAIUtterance(samples: [Float], sampleRate: Double, heardSpeech: Bool,
                                       vocabulary: [String]) async {
        guard heardSpeech else {
            // Nothing was ever heard: nothing is uploaded.
            PrivacyLog.speech(.cloudDictation, .noSpeechDetected, detail: PrivacyToken("openAI"))
            onSilenceTimeout?()
            return
        }
        let started = Date()
        do {
            let text = try await openAIDictation.transcribe(samples: samples, sampleRate: sampleRate,
                                                            vocabulary: vocabulary)
            // The upload is the gap between speech end and commit in the turn ledger; the log
            // carries it on its own as well.
            PrivacyLog.speech(.cloudDictation, .analysisCompleted,
                              seconds: Date().timeIntervalSince(started), detail: PrivacyToken("openAI"))
            deliverTranscript(text, channel: .cloudDictation)
        } catch {
            let token = (error as? OpenAIDictationError)?.token
                ?? ((error is MedicalEgressRefusal) ? "medicalLocalOnly" : "transportFailed")
            PrivacyLog.speech(.cloudDictation, .recognitionFailed,
                              seconds: Date().timeIntervalSince(started), detail: PrivacyToken(token))
            if onDeviceEngine.isReady {
                PrivacyLog.speech(.dictation, .cloudFallback, detail: PrivacyToken("onDevice"))
                await decodeOnDevice(samples: samples, sampleRate: sampleRate)
            } else {
                errorMessage = error.localizedDescription
                onSilenceTimeout?()
            }
        }
    }

    /// The SenseVoice decode of a whole utterance.
    private func decodeOnDevice(samples: [Float], sampleRate: Double) async {
        do {
            let text = try await onDeviceEngine.transcribe(samples: samples, sampleRate: sampleRate)
            deliverTranscript(text, channel: .onDeviceASR)
        } catch {
            PrivacyLog.speech(.onDeviceASR, .recognitionFailed, error: SafeErrorSummary(error))
            errorMessage = error.localizedDescription
            onSilenceTimeout?()
        }
    }

    /// The one delivery for the non-Apple engines: a transcript to `onTranscriptionComplete`, or
    /// the no-speech path for an empty one. The count is logged, never the words.
    private func deliverTranscript(_ text: String, channel: PrivacyLog.SpeechChannel) {
        if text.isEmpty {
            PrivacyLog.speech(channel, .noSpeechDetected)
            onSilenceTimeout?()
        } else {
            PrivacyLog.speech(channel, .transcriptDelivered, characters: text.count)
            currentTranscription = ""
            onTranscriptionComplete?(text)
        }
    }

    private func handleRecognitionResult(result: SFSpeechRecognitionResult?, error: Error?,
                                         generation: Int) {
        // A turn already stopped: these are the words it was waiting for.
        if var stopped = stoppedAppleTurn, stopped.generation == generation {
            if let result {
                stopped.transcript.noteResult(result.bestTranscription.formattedString,
                                              isFinal: result.isFinal)
                if !isRecording { currentTranscription = stopped.transcript.text }
            }
            // After `endAudio()` an error is usually "no speech" — the words already heard stand.
            if error != nil { stopped.transcript.noteEnded() }
            stoppedAppleTurn = stopped
            if stopped.transcript.isSettled { settleStoppedAppleTurn(timedOut: false) }
            return
        }
        // A task from an earlier turn — cancelled, or settled on its timeout — has nothing to add.
        guard generation == appleTurnGeneration, isRecording else { return }

        if let result = result {
            currentTranscription = result.bestTranscription.formattedString
            if !didReceiveSpeech {
                didReceiveSpeech = true
                noSpeechTimer?.invalidate()
                noSpeechTimer = nil
            }
            resetSilenceTimer()

            if result.isFinal {
                appleRecognizerEnded = .final
                cleanupEngine()
                stopRecording()
                return
            }
        }

        if let error = error {
            PrivacyLog.speech(.dictation, .recognitionFailed, error: SafeErrorSummary(error))
            appleRecognizerEnded = .ended
            cleanupEngine()
            stopRecording()
        }
    }

    private func resetSilenceTimer() {
        // Plan CU P1: the stamp. Arming the window is the last moment speech was observed, and that
        // is what `stopRecording` records — P2 added a better stamp for the turns a detector ends,
        // but this one still carries every turn the timer ends, which is all of them today.
        lastSpeechObservedAt = Date()
        // Plan CU P2: the window's length and firing now come from `EndOfTurnPolicy` rather than
        // from `silenceThreshold` directly. With no detector installed it returns this same
        // deadline; the name is kept because ~all callers mean "speech happened, re-arm".
        evaluateEndOfTurn()
    }

    // MARK: - End-of-turn arbitration (Plan CU P2)

    /// Ask `EndOfTurnPolicy` whether this utterance is over, and either commit or re-arm one timer
    /// for the deadline it names.
    ///
    /// Every deadline in the voice path now comes from the policy rather than from a
    /// `silenceThreshold` scattered across call sites — with no detector installed the policy
    /// returns the same deadline the old timer used, which is what makes "unchanged when
    /// unavailable" a property of the code rather than a claim about it.
    private func evaluateEndOfTurn() {
        guard isRecording else { return }

        let detector = speechActivityDetector
        let decision = EndOfTurnPolicy.decide(.init(
            now: Date(),
            detectorAvailable: detector?.isAvailable ?? false,
            speechObserved: didReceiveSpeech || acousticSpeechObserved,
            lastRecognizerActivityAt: lastSpeechObservedAt,
            acousticSpeechEndedAt: acousticSpeechEndedAt,
            timerWindow: silenceThreshold
        ))

        switch decision {
        case .commit(let reason):
            endOfTurnReason = reason
            silenceTimer?.invalidate()
            silenceTimer = nil
            cleanupEngine()
            stopRecording()

        case .wait(let deadline):
            silenceTimer?.invalidate()
            // Never schedule in the past: a deadline that has already passed but did not commit
            // means some other rule holds the turn, and a zero-interval repeat would spin.
            let interval = max(deadline.timeIntervalSinceNow, 0.05)
            silenceTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.evaluateEndOfTurn() }
            }
        }
    }

    /// A transition from the detector. Only two things can arrive here, a few times per turn.
    private func handleSpeechActivity(_ event: SpeechActivityGate.Event) {
        guard isRecording else { return }
        switch event {
        case .speechStarted:
            acousticSpeechObserved = true
            acousticSpeechEndedAt = nil        // whatever we thought had ended, has not
        case .speechEnded(let at):
            acousticSpeechEndedAt = at
        }
        evaluateEndOfTurn()
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
