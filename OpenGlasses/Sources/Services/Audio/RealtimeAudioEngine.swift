import AVFoundation
import Foundation

/// Injected differences between the two realtime audio paths (Plan BG P4). Everything the twin
/// `GeminiLiveAudioManager` / `OpenAIRealtimeAudioManager` classes differed by lives here; the engine
/// logic is otherwise identical.
struct RealtimeAudioEngineConfig {
    /// Owner identity for the shared `AudioSessionCoordinator` lease.
    let owner: AudioSessionOwner
    /// NSLog prefix, e.g. `[Audio]` / `[OpenAI Audio]`.
    let logPrefix: String
    let lifecycleQueueLabel: String
    let accumulatorQueueLabel: String
    /// Mic capture is resampled to this rate before sending (Gemini 16 kHz, OpenAI 24 kHz).
    let inputSampleRate: Double
    /// Received playback PCM is at this rate (both 24 kHz today, but kept independent).
    let outputSampleRate: Double
    let channels: UInt32
    let bitsPerSample: UInt32
    /// Client-side voice-activity interrupt detection. `nil` disables it (Gemini relies on server VAD).
    let vad: VAD?

    struct VAD {
        /// RMS amplitude above which a buffer counts as speech.
        let amplitudeThreshold: Float
        /// Consecutive above-threshold buffers required to fire an interrupt.
        let requiredHighFrames: Int
    }

    /// ~100 ms of input PCM — the chunk size we accumulate before sending.
    var minSendBytes: Int { Int(inputSampleRate / 10) * Int(channels) * Int(bitsPerSample / 8) }
    /// Preferred hardware sample-rate hint (matches the capture rate).
    var preferredSampleRate: Double { inputSampleRate }

    static let geminiLive = RealtimeAudioEngineConfig(
        owner: .geminiLive,
        logPrefix: "[Audio]",
        lifecycleQueueLabel: "gemini.audio.lifecycle",
        accumulatorQueueLabel: "audio.accumulator",
        inputSampleRate: Config.geminiLiveInputSampleRate,
        outputSampleRate: Config.geminiLiveOutputSampleRate,
        channels: Config.geminiLiveAudioChannels,
        bitsPerSample: Config.geminiLiveAudioBitsPerSample,
        vad: nil
    )

    static let openAIRealtime = RealtimeAudioEngineConfig(
        owner: .openAIRealtime,
        logPrefix: "[OpenAI Audio]",
        lifecycleQueueLabel: "openai.audio.lifecycle",
        accumulatorQueueLabel: "openai.audio.accumulator",
        inputSampleRate: 24000,
        outputSampleRate: 24000,
        channels: 1,
        bitsPerSample: 16,
        vad: VAD(amplitudeThreshold: 0.05, requiredHighFrames: 3)
    )
}

/// Single realtime audio engine for both Gemini Live and OpenAI Realtime modes (Plan BG P4 —
/// replaces the ~90%-identical `GeminiLiveAudioManager` / `OpenAIRealtimeAudioManager`). Captures the
/// microphone as Int16 PCM (resampled to `config.inputSampleRate`) and plays back Int16 PCM at
/// `config.outputSampleRate`. Separate from `WakeWordService`'s engine — the two cannot coexist.
///
/// Self-healing across OS audio interruptions (phone calls, Siri) and Bluetooth/LE-Audio route
/// changes: the `AVAudioEngine` is kept permanent for the engine's lifetime (teardown only stops and
/// detaches child nodes), all graph mutations run on a single serial lifecycle queue, and a
/// generation counter discards stale tap buffers so audio from a torn-down session can't bleed into
/// the next one. The interruption/route → action decisions live in pure, tested policies
/// (`AudioInterruptionPolicy`, `AudioRoutePolicy`); this class only executes them.
///
/// ## Queue-ordering contract (Plan BO — off-main session activation)
///
/// Three serial queues are in play; the rule that keeps them deadlock-free is **the two `.sync`
/// waiters never wait on the queue that performs session I/O**:
///
///  - **`audioLifecycleQueue`** — owns every engine-graph mutation. Entered via
///    `syncOnAudioLifecycleQueue`, which runs inline when already on the queue (re-entrancy guard
///    via `audioLifecycleQueueKey`) and otherwise `.sync`s onto it. `sendQueue.sync` is the only
///    other blocking wait. Neither ever waits on the coordinator's `sessionIOQueue`.
///  - **coordinator `sessionIOQueue`** — owns `setActive`/`setCategory`. `setupAudioSession` reaches
///    it through `acquireOffMain`, which `await`s an `async` hop (`withCheckedThrowingContinuation`
///    + `sessionIOQueue.async`) — a **suspension, not a thread-block** — and never calls back into
///    `audioLifecycleQueue`. So `sessionIOQueue` waits on nobody here.
///  - **main actor** — the managers and the recovery `Task` call `await setupAudioSession`.
///
/// The recovery path is the one that could cycle and does not: `attemptAudioResetOnQueue` runs on
/// `audioLifecycleQueue`, tears the graph down, then **hops off that queue** to a `@MainActor Task`
/// that `await`s `setupAudioSession` (session activation on `sessionIOQueue`) and then `startCapture`
/// (`.sync` back onto the — now free — `audioLifecycleQueue`). Because the reset dispatches
/// asynchronously and never `.sync`-waits, the lifecycle queue is released before the re-setup
/// re-enters it; the async activation suspends rather than blocking. No `A waits on B waits on A`.
final class RealtimeAudioEngine {
    var onAudioCaptured: ((Data) -> Void)?

    /// Fires when the user's voice amplitude exceeds the interrupt threshold while the model is
    /// speaking (OpenAI client-side VAD). Never fires when `config.vad` is `nil`.
    var onVoiceInterrupt: (() -> Void)?

    /// Fires with the milliseconds of scheduled-but-unheard audio a graph rebuild destroyed
    /// (Plan CW P2). The listener owes the backend the same truncate-on-loss it sends on barge-in:
    /// a reply the wearer never heard must not stay in the model's context as though they had.
    /// Invoked on the audio-lifecycle queue.
    var onPlaybackDiscarded: ((Int) -> Void)?

    /// Ceiling on mirrored playback — ~10 s of 24 kHz mono Int16, comfortably past the longest
    /// burst a realtime server sends ahead of real time, and small enough that a session cannot
    /// grow into it. Past this, new buffers still play; they just cannot be carried, and the
    /// mirror counts them so the loss report stays honest.
    private static let pendingPlaybackByteLimit = 512 * 1024

    private let config: RealtimeAudioEngineConfig

    // The engine container is stable for the lifetime of a capture: teardown only stops and
    // detaches child nodes. It is REPLACED in exactly one place — `prepareEngineOnQueue`, at
    // capture start, on the lifecycle queue — because voice processing (Plan CC) only behaves when
    // enabled on a fresh engine before any wiring or format read. Never swapped mid-capture, so
    // the recovery paths (interruption/route reset) always see the live container.
    private var audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()

    /// What this capture actually achieved (Plan CC): `.echoCancelled` when voice-processing IO
    /// came up alive, `.halfDuplex` otherwise. Written on the lifecycle queue at capture start —
    /// before any buffer flows — and read by the session managers' capture callbacks to drive
    /// `EchoSuppressionPolicy`.
    private(set) var duplexCapability: DuplexAudioCapability = .halfDuplex

    // All engine-graph mutations run here so observer-driven recovery can't race start/stop.
    private let audioLifecycleQueue: DispatchQueue
    private let audioLifecycleQueueKey = DispatchSpecificKey<Void>()

    private var isCapturing = false
    private var isInputTapInstalled = false
    private var isPlayerNodeAttached = false
    /// Confirmed-played frame accounting for barge-in truncation (CJ item 6). Confined to
    /// `audioLifecycleQueue`, like all playback state.
    private var playbackLedger = PlaybackProgressLedger()
    /// What the player node still owes us, mirrored so a rebuild can carry it (CW P2).
    /// Confined to `audioLifecycleQueue`; updated at the same three points as `playbackLedger`.
    private var pendingPlayback = PendingPlaybackMirror(byteLimit: pendingPlaybackByteLimit)
    /// Buffers drained ahead of a rebuild, waiting for the new graph. Non-empty only across the
    /// asynchronous middle of `attemptAudioResetOnQueue`.
    private var carriedPlayback: [PendingPlaybackMirror.Entry] = []
    private var useIPhoneMode = false
    /// The input format the current tap and resampling converter were built for (Plan CW P1).
    /// Recovery compares the live format against this: an unchanged format means a stopped engine
    /// only needs `start()`, a changed one means the tap is producing garbage and must be rebuilt.
    /// `nil` between captures.
    private var tapInputFormat: (sampleRate: Double, channels: UInt32)?
    /// Bumped on every (re)start and teardown; tags tap buffers so stale ones are dropped.
    private var audioGraphGeneration: UInt64 = 0
    /// Our claim on the shared session, held while the conversation owns the mic.
    private var sessionLease: AudioSessionLease?

    // Accumulate resampled PCM into ~100ms chunks before sending
    private let sendQueue: DispatchQueue
    private var accumulatedData = Data()
    private var accumulatorGeneration: UInt64 = 0

    // Client-side VAD for interruption (only active when config.vad != nil)
    private var isModelCurrentlySpeaking = false
    private var consecutiveHighFrames = 0

    private var observers: [NSObjectProtocol] = []

    init(config: RealtimeAudioEngineConfig) {
        self.config = config
        self.audioLifecycleQueue = DispatchQueue(label: config.lifecycleQueueLabel, qos: .userInitiated)
        self.sendQueue = DispatchQueue(label: config.accumulatorQueueLabel)
        audioLifecycleQueue.setSpecific(key: audioLifecycleQueueKey, value: ())
    }

    deinit {
        removeObservers()
    }

    /// Set this from the session manager to enable/disable interrupt detection (OpenAI VAD).
    var modelSpeaking: Bool {
        get { isModelCurrentlySpeaking }
        set {
            isModelCurrentlySpeaking = newValue
            if !newValue { consecutiveHighFrames = 0 }
        }
    }

    /// Configure the audio session for this realtime mode.
    /// - Parameter useIPhoneMode: `true` for `.voiceChat` (iPhone mic), `false` for `.videoChat` (glasses mic).
    func setupAudioSession(useIPhoneMode: Bool = false) async throws {
        self.useIPhoneMode = useIPhoneMode
        let session = AVAudioSession.sharedInstance()
        guard AVAudioApplication.shared.recordPermission != .denied else {
            throw AudioSessionError.microphonePermissionDenied
        }
        let mode: AVAudioSession.Mode = useIPhoneMode ? .voiceChat : .videoChat
        // BO: acquire OFF-MAIN through the coordinator (was the synchronous `acquire`, which
        // activated on the main thread — the last realtime TPC hang-risk). `acquireOffMain` awaits
        // the activation on the coordinator's `sessionIOQueue`, so the session is active on return
        // (no separate `activationSettled` wait needed before `startCapture`). Supersedes any prior
        // holder; a clean `release` deactivates it for whoever runs next (e.g. wake word).
        sessionLease = try await AudioSessionCoordinator.shared.acquireOffMain(
            config.owner,
            category: .playAndRecord,
            mode: mode,
            options: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP]
        ) { [config] session in
            // Preferred rate/buffer are hints — a rejected hint must not abort activation.
            try? session.setPreferredSampleRate(config.preferredSampleRate)
            try? session.setPreferredIOBufferDuration(0.064)
        }
        applyRoutePolicy(session, useIPhoneMode: useIPhoneMode)
        installSessionObservers()
        PrivacyLog.audio(.realtime, .modeSelected, owner: PrivacyToken(config.owner.rawValue),
                         detail: PrivacyToken(useIPhoneMode ? "voiceChat-iPhone" : "videoChat-glasses"))
    }

    /// Start capturing microphone audio and sending chunks via `onAudioCaptured`.
    func startCapture() throws {
        try syncOnAudioLifecycleQueue {
            try startCaptureOnQueue()
        }
    }

    private func startCaptureOnQueue() throws {
        guard !isCapturing else { return }

        // Plan CC: decide the duplex tier for THIS capture. Voice processing is only attempted for
        // the co-located phone speaker+mic — in glasses mode the mic is remote and there is no echo
        // path to cancel, so the risk of the IO swap buys nothing.
        prepareEngineOnQueue(wantVoiceProcessing: Config.duplexAudioEnabled && useIPhoneMode)

        // Idempotent setup: clear any stale tap, attach the player exactly once.
        if isInputTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            isInputTapInstalled = false
        }
        if !isPlayerNodeAttached {
            audioEngine.attach(playerNode)
            isPlayerNodeAttached = true
        }

        let playerFormat = try AudioFormatFactory.pcm(
            .pcmFormatFloat32,
            sampleRate: config.outputSampleRate,
            channels: config.channels,
            interleaved: false,
            context: "playback"
        )
        audioEngine.disconnectNodeOutput(playerNode)
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: playerFormat)

        let inputNode = audioEngine.inputNode
        let inputNativeFormat = inputNode.outputFormat(forBus: 0)

        let needsResample = inputNativeFormat.sampleRate != config.inputSampleRate
            || inputNativeFormat.channelCount != config.channels

        PrivacyLog.audio(.realtime, .formatNegotiated, owner: PrivacyToken(config.owner.rawValue),
                         detail: PrivacyToken(needsResample ? "resampling" : "native"),
                         hertz: Int(inputNativeFormat.sampleRate),
                         channels: Int(inputNativeFormat.channelCount))

        // CW P1: remember what the tap and converter below are built for, so recovery can tell a
        // stopped engine (restartable, playback survives) from a re-routed one (must rebuild).
        tapInputFormat = (inputNativeFormat.sampleRate, inputNativeFormat.channelCount)

        // New generation: the tap below tags its buffers with it; the accumulator only accepts the
        // current generation, so buffers from a previous (torn-down) capture are dropped.
        audioGraphGeneration &+= 1
        let captureGeneration = audioGraphGeneration
        sendQueue.sync {
            accumulatedData = Data()
            accumulatorGeneration = captureGeneration
        }

        // Build the resample target format once and reuse it for every tap buffer (it's constant),
        // rather than reconstructing — and force-unwrapping — it per buffer.
        var converter: AVAudioConverter?
        var resampleFormat: AVAudioFormat?
        if needsResample {
            let format = try AudioFormatFactory.pcm(
                .pcmFormatFloat32,
                sampleRate: config.inputSampleRate,
                channels: config.channels,
                interleaved: false,
                context: "capture resampling"
            )
            resampleFormat = format
            converter = AVAudioConverter(from: inputNativeFormat, to: format)
        }

        let minSendBytes = config.minSendBytes
        let vad = config.vad
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputNativeFormat) { [weak self] buffer, _ in
            guard let self else { return }

            let pcmData: Data
            let amplitudeBuffer: AVAudioPCMBuffer

            if let converter, let resampleFormat {
                guard let resampled = self.convertBuffer(buffer, using: converter, targetFormat: resampleFormat) else {
                    return
                }
                pcmData = self.float32ToInt16Data(resampled)
                amplitudeBuffer = resampled
            } else {
                pcmData = self.float32ToInt16Data(buffer)
                amplitudeBuffer = buffer
            }

            // Client-side VAD: check amplitude for a fast interrupt while the model is speaking.
            if let vad, self.isModelCurrentlySpeaking {
                let rms = self.calculateRMS(amplitudeBuffer)
                if rms > vad.amplitudeThreshold {
                    self.consecutiveHighFrames += 1
                    if self.consecutiveHighFrames >= vad.requiredHighFrames {
                        // The RMS itself is a measurement of how loudly the wearer was
                        // speaking; the interrupt firing is the diagnosable fact.
                        PrivacyLog.audio(.realtime, .clientVoiceInterrupt, owner: PrivacyToken(self.config.owner.rawValue),
                                         count: vad.requiredHighFrames)
                        self.consecutiveHighFrames = 0
                        self.onVoiceInterrupt?()
                    }
                } else {
                    self.consecutiveHighFrames = 0
                }
            }

            self.sendQueue.async {
                // Drop buffers from a superseded capture generation (a reset happened mid-flight).
                guard self.accumulatorGeneration == captureGeneration else { return }
                self.accumulatedData.append(pcmData)
                if self.accumulatedData.count >= minSendBytes {
                    let chunk = self.accumulatedData
                    self.accumulatedData = Data()
                    self.onAudioCaptured?(chunk)
                }
            }
        }
        isInputTapInstalled = true

        do {
            try audioEngine.start()
            playerNode.play()
            isCapturing = true
            // The first question on any field report is which tier this capture reached.
            PrivacyLog.audio(.realtime, .captureStarted, owner: PrivacyToken(config.owner.rawValue),
                             detail: PrivacyToken(duplexCapability.rawValue))
        } catch {
            tearDownEngineGraphOnQueue(flushPendingAudio: false)
            throw error
        }
    }

    // MARK: - Duplex tier (Plan CC)

    /// Establish the engine for this capture and set `duplexCapability`.
    ///
    /// The ordering here IS the fix. Enabling voice processing on the long-lived engine — one that
    /// has had taps installed and formats read — silenced capture entirely on recent iOS builds
    /// (deaf-always, strictly worse than the mute). The IO-unit swap only behaves when it happens
    /// on a fresh engine, before any wiring and before any format read. A zero sample rate on the
    /// post-enable format is the known dead-IO signature; on seeing it we rebuild WITHOUT voice
    /// processing so the half-duplex mute takes over. Failure is graded, not binary:
    /// echo-cancelled → open mic + barge-in; unavailable → today's mute; deaf-always and
    /// hearing-itself both structurally excluded.
    ///
    /// Re-tried on every capture start (the engine is rebuilt anyway); the verdict holds for the
    /// duration of that capture so the tier cannot flap mid-conversation.
    private func prepareEngineOnQueue(wantVoiceProcessing: Bool) {
        duplexCapability = .halfDuplex
        guard wantVoiceProcessing else { return }

        replaceEngineOnQueue()
        do {
            try audioEngine.inputNode.setVoiceProcessingEnabled(true)
        } catch {
            PrivacyLog.audio(.realtime, .voiceProcessingFailed, owner: PrivacyToken(config.owner.rawValue),
                             error: SafeErrorSummary(error))
            replaceEngineOnQueue()
            return
        }

        let format = audioEngine.inputNode.outputFormat(forBus: 0)
        switch VoiceProcessingProbe.verdict(sampleRate: format.sampleRate,
                                            channelCount: format.channelCount) {
        case .usable:
            duplexCapability = .echoCancelled
        case .deadIO:
            PrivacyLog.audio(.realtime, .voiceProcessingDead, owner: PrivacyToken(config.owner.rawValue))
            replaceEngineOnQueue()
        }
    }

    /// Swap in a fresh engine container. Lifecycle-queue only, capture-start only — child nodes are
    /// detached from the old engine first so the player can re-attach to the new one.
    private func replaceEngineOnQueue() {
        if isInputTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            isInputTapInstalled = false
        }
        if isPlayerNodeAttached {
            if playerNode.isPlaying { playerNode.stop() }
            audioEngine.disconnectNodeOutput(playerNode)
            audioEngine.detach(playerNode)
            isPlayerNodeAttached = false
        }
        audioEngine.stop()
        // CW P3: hand the voice-processing IO unit back before dropping the engine that owns it.
        // We enable it on a fresh engine (Plan CC) and previously discarded that engine without
        // ever disabling it, leaving an IO unit to be retired by ARC — the reported failure mode
        // for that elsewhere is no microphone on the *next* session until the app is relaunched.
        // Cheap, ordered, and not a guarantee worth leaving to deallocation timing.
        if audioEngine.inputNode.isVoiceProcessingEnabled {
            try? audioEngine.inputNode.setVoiceProcessingEnabled(false)
        }
        audioEngine.reset()
        audioEngine = AVAudioEngine()
    }

    /// Play received PCM audio (Int16 at `config.outputSampleRate`) through the speaker.
    func playAudio(data: Data) {
        guard !data.isEmpty else { return }
        audioLifecycleQueue.async { [weak self] in
            self?.playAudioOnQueue(data: data)
        }
    }

    private func playAudioOnQueue(data: Data) {
        guard isCapturing, isPlayerNodeAttached, !data.isEmpty else { return }

        // An AVAudioSession deactivation (sleep, another owner's session cycle) can leave
        // the engine non-nil but silently dead: `isRunning == false` while the graph looks
        // intact, and every scheduled buffer is swallowed without an error. Resurrect the
        // engine before scheduling instead of dropping the response into the void.
        // CW P1: this path used to `start()` unconditionally, which is right for the common case
        // and wrong when the route moved underneath us — restarting into a stale tap keeps a graph
        // that is producing garbage. Same decision function as the route-change path, so the two
        // can no longer disagree about what a dead engine means.
        if !audioEngine.isRunning {
            guard recoverGraphOnQueue(trigger: .schedulingDiscovery) else {
                PrivacyLog.audio(.realtime, .playbackDropped, owner: PrivacyToken(config.owner.rawValue),
                                 detail: PrivacyToken("graphUnusable"), bytes: data.count)
                return
            }
        }

        let frameCount = frameCount(forByteCount: data.count)
        guard frameCount > 0 else { return }

        // CJ item 6: count this buffer as played only when the hardware confirms it rendered.
        // `.dataPlayedBack` callbacks also fire for buffers a later `stop()` discards — the
        // ledger's generation check drops those (discarded ≠ heard).
        let generation = playbackLedger.scheduled(frames: frameCount)
        // CW P2: keep our own copy of what the player node now holds. The node will not tell us
        // what it still owes when a rebuild takes it away.
        pendingPlayback.scheduled(pcm: data, frames: frameCount, generation: generation)
        scheduleBufferOnQueue(pcm: data, frames: frameCount, generation: generation)
    }

    /// Frames of `config.outputSampleRate` PCM in a byte count of received audio.
    private func frameCount(forByteCount bytes: Int) -> UInt32 {
        UInt32(bytes) / (config.bitsPerSample / 8 * config.channels)
    }

    /// Convert Int16 PCM to the player's float format and hand it to the node.
    ///
    /// Separated from `playAudioOnQueue` (CW P2) because the carry-over path re-schedules buffers
    /// the ledger has **already** counted: re-entering the accounting would double-count them as
    /// scheduled and make `confirmedPlayedMilliseconds` under-report for the rest of the response.
    @discardableResult
    private func scheduleBufferOnQueue(pcm: Data, frames: UInt32, generation: UInt64) -> Bool {
        guard let playerFormat = try? AudioFormatFactory.pcm(
            .pcmFormatFloat32,
            sampleRate: config.outputSampleRate,
            channels: config.channels,
            interleaved: false,
            context: "playback"
        ) else {
            PrivacyLog.audio(.realtime, .playbackDropped, owner: PrivacyToken(config.owner.rawValue),
                             detail: PrivacyToken("invalidPlaybackFormat"), bytes: pcm.count)
            return false
        }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: playerFormat, frameCapacity: frames) else {
            return false
        }
        buffer.frameLength = frames

        guard let floatData = buffer.floatChannelData else { return false }
        pcm.withUnsafeBytes { rawBuffer in
            guard let int16Ptr = rawBuffer.bindMemory(to: Int16.self).baseAddress else { return }
            for i in 0..<Int(frames) {
                floatData[0][i] = Float(int16Ptr[i]) / Float(Int16.max)
            }
        }

        playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            self?.audioLifecycleQueue.async {
                guard let self else { return }
                self.playbackLedger.played(frames: frames, generation: generation)
                self.pendingPlayback.retire(generation: generation)
            }
        }
        if !playerNode.isPlaying {
            playerNode.play()
        }
        return true
    }

    /// Re-schedule the buffers a rebuild carried across, under their original generation so the
    /// ledger's played-count is continuous rather than restarting at zero (CW P2).
    private func rescheduleCarriedPlaybackOnQueue() {
        let carried = carriedPlayback
        carriedPlayback = []
        guard !carried.isEmpty else { return }

        guard isCapturing, isPlayerNodeAttached else {
            // The rebuild did not produce a graph to play on. That is a loss like any other and
            // has to be reported, not quietly forgotten on the way out.
            reportPlaybackLoss(frames: carried.reduce(0) { $0 &+ UInt64($1.frames) },
                               context: "rebuild produced no graph")
            return
        }

        var restored: UInt64 = 0
        var lost: UInt64 = 0
        for entry in carried {
            pendingPlayback.scheduled(pcm: entry.pcm, frames: entry.frames, generation: entry.generation)
            if scheduleBufferOnQueue(pcm: entry.pcm, frames: entry.frames, generation: entry.generation) {
                restored &+= UInt64(entry.frames)
            } else {
                lost &+= UInt64(entry.frames)
            }
        }
        PrivacyLog.audio(.realtime, .playbackCarried, owner: PrivacyToken(config.owner.rawValue),
                         milliseconds: PendingPlaybackMirror.milliseconds(
                            frames: restored, sampleRate: config.outputSampleRate))
        if lost > 0 { reportPlaybackLoss(frames: lost, context: "rescheduleFailed") }
    }

    /// Announce playback that was scheduled and never heard (CW P2).
    ///
    /// Silence is indistinguishable from "the assistant never spoke", and worse, the backend still
    /// believes it delivered the reply — so the conversation continues from a false premise. The
    /// listener is expected to run the same truncate-on-loss path barge-in already uses.
    private func reportPlaybackLoss(frames: UInt64, context: String) {
        guard frames > 0 else { return }
        let ms = PendingPlaybackMirror.milliseconds(frames: frames, sampleRate: config.outputSampleRate)
        PrivacyLog.audio(.realtime, .playbackDiscarded, owner: PrivacyToken(config.owner.rawValue),
                         detail: PrivacyToken(context), milliseconds: ms)
        onPlaybackDiscarded?(ms)
    }

    /// Confirmed-played milliseconds of the current response's audio (CJ item 6) — from buffer
    /// completion callbacks, never wall-clock. Read this *before* `stopPlayback()` on barge-in.
    var confirmedPlayedMilliseconds: Int {
        syncOnAudioLifecycleQueue {
            playbackLedger.playedMilliseconds(sampleRate: config.outputSampleRate)
        }
    }

    /// Start a fresh played-audio accounting window (call at each response boundary).
    func resetPlaybackProgress() {
        audioLifecycleQueue.async { [weak self] in
            guard let self else { return }
            self.playbackLedger.reset()
            // A response boundary retires the mirror with the ledger. Nothing is reported: the
            // tail may still be draining and is expected to be heard, it just belongs to the
            // window that closed.
            self.pendingPlayback.discardAll()
        }
    }

    /// Stop playback but keep the engine running (used on barge-in / interrupt).
    func stopPlayback() {
        audioLifecycleQueue.async { [weak self] in
            self?.stopPlaybackOnQueue()
        }
    }

    private func stopPlaybackOnQueue() {
        guard isPlayerNodeAttached else { return }
        // Reset before stop: the stop fires completion callbacks for every *discarded* buffer,
        // and the generation bump keeps them out of the played count.
        playbackLedger.reset()
        // Barge-in already reports its own truncation point from the ledger, so the discarded
        // frames here need clearing but not announcing — announcing them would double-report.
        pendingPlayback.discardAll()
        playerNode.stop()
        if isCapturing, audioEngine.isRunning {
            playerNode.play()
        }
    }

    /// Stop capture and tear down the engine graph (the engine container itself is kept).
    func stopCapture() {
        syncOnAudioLifecycleQueue {
            tearDownEngineGraphOnQueue(flushPendingAudio: true)
        }
        removeObservers()
        // Release our claim on the shared session; the coordinator deactivates it only if no newer
        // owner has acquired since (so a late stop can't stomp the next session).
        if let lease = sessionLease {
            sessionLease = nil
            AudioSessionCoordinator.shared.release(lease)
        }
    }

    // MARK: - Audio Interruption & Route Change Handling

    private func installSessionObservers() {
        removeObservers()
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        observers.append(
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: nil) { [weak self] note in
                self?.handleInterruptionNotification(note)
            }
        )
        observers.append(
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: nil) { [weak self] note in
                self?.handleRouteChangeNotification(note)
            }
        )
    }

    private func removeObservers() {
        for token in observers { NotificationCenter.default.removeObserver(token) }
        observers.removeAll()
    }

    private func handleInterruptionNotification(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }

        var shouldResume = false
        if type == .ended, let optsRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt {
            shouldResume = AVAudioSession.InterruptionOptions(rawValue: optsRaw).contains(.shouldResume)
        }

        audioLifecycleQueue.async { [weak self] in
            guard let self else { return }
            switch AudioInterruptionPolicy.action(for: type, shouldResume: shouldResume, isCapturing: self.isCapturing) {
            case .pause:
                // Keep `isCapturing` true through the pause so the matching `.ended` resumes.
                self.audioEngine.pause()
                PrivacyLog.audio(.realtime, .interruptionBegan, owner: PrivacyToken(self.config.owner.rawValue))
            case .resume:
                PrivacyLog.audio(.realtime, .interruptionEnded, owner: PrivacyToken(self.config.owner.rawValue))
                self.resumeAfterInterruptionOnQueue()
            case .resetGraph:
                self.recoverGraphOnQueue(trigger: .routeChange)
            case .none:
                break
            }
        }
    }

    private func handleRouteChangeNotification(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }

        audioLifecycleQueue.async { [weak self] in
            guard let self else { return }
            if AudioInterruptionPolicy.action(for: reason, isCapturing: self.isCapturing) == .resetGraph {
                // CW P1: the session policy says the route moved; how much of the graph that
                // actually costs is a separate question, and a glasses HFP mic arriving at session
                // start (`.newDeviceAvailable`) usually costs nothing but a `start()`.
                PrivacyLog.audio(.realtime, .routeChanged, owner: PrivacyToken(self.config.owner.rawValue),
                                 detail: PrivacyToken(String(describing: reason)))
                self.recoverGraphOnQueue(trigger: .routeChange)
            }
        }
    }

    private func resumeAfterInterruptionOnQueue() {
        // Only reactivate if this engine still owns the shared session — a resume after a phone
        // call must not stomp whoever acquired it meanwhile (wake word, the other realtime engine).
        let owner = AudioSessionCoordinator.shared.currentOwner
        guard AudioInterruptionPolicy.mayResume(engineOwner: config.owner, currentOwner: owner) else {
            PrivacyLog.audio(.realtime, .interruptionEndedNotResuming, owner: PrivacyToken(config.owner.rawValue),
                             detail: PrivacyToken(owner?.rawValue ?? "nobody"))
            return
        }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(true)
            if isCapturing, !audioEngine.isRunning {
                try audioEngine.start()
            }
            if isCapturing, isPlayerNodeAttached, !playerNode.isPlaying {
                playerNode.play()
            }
            PrivacyLog.audio(.realtime, .resumed, owner: PrivacyToken(config.owner.rawValue))
        } catch {
            PrivacyLog.audio(.realtime, .resumeFailed, owner: PrivacyToken(config.owner.rawValue),
                             error: SafeErrorSummary(error))
            recoverGraphOnQueue(trigger: .interruptionEnded)
        }
    }

    /// The graph state as the engine actually presents it right now (Plan CW P1). Lifecycle-queue
    /// only — every field is a live read off `AVAudioEngine`.
    private func observedGraphStateOnQueue() -> AudioGraphState {
        var formatChanged = false
        if let tapInputFormat {
            let live = audioEngine.inputNode.outputFormat(forBus: 0)
            formatChanged = AudioGraphRecovery.formatChanged(
                fromSampleRate: tapInputFormat.sampleRate, fromChannels: tapInputFormat.channels,
                toSampleRate: live.sampleRate, toChannels: live.channelCount
            )
        }
        return AudioGraphState(
            engineRunning: audioEngine.isRunning,
            nodesAttached: isPlayerNodeAttached && isInputTapInstalled,
            formatChanged: formatChanged,
            isCapturing: isCapturing
        )
    }

    /// Repair the graph proportionately to what is actually wrong with it (Plan CW P1).
    ///
    /// Replaces the reflex that made a route settle at session start destroy the first reply: the
    /// engine stopping is not the same event as the graph breaking, and `AudioGraphRecovery` is
    /// where that distinction is decided and tested. Returns `true` if the graph is usable when it
    /// returns — a `.rebuild` returns `false` because the rebuild completes asynchronously.
    @discardableResult
    private func recoverGraphOnQueue(trigger: AudioGraphTrigger) -> Bool {
        let state = observedGraphStateOnQueue()
        switch AudioGraphRecovery.action(for: trigger, state: state) {
        case .none:
            return state.isCapturing

        case .restart:
            do {
                try audioEngine.start()
                // CW P3: a restart can come back with dead IO — the same zero-sample-rate
                // signature `VoiceProcessingProbe` already screens for at capture start. Reporting
                // success here would leave a deaf engine running and nothing else would notice.
                let live = audioEngine.inputNode.outputFormat(forBus: 0)
                if case .deadIO = VoiceProcessingProbe.verdict(
                    sampleRate: live.sampleRate, channelCount: live.channelCount
                ) {
                    PrivacyLog.audio(.realtime, .engineRestartedDeaf, owner: PrivacyToken(config.owner.rawValue),
                                     detail: PrivacyToken(trigger.rawValue))
                    carriedPlayback = pendingPlayback.drain()
                    attemptAudioResetOnQueue()
                    return false
                }
                if isPlayerNodeAttached, !playerNode.isPlaying { playerNode.play() }
                PrivacyLog.audio(.realtime, .engineRestarted, owner: PrivacyToken(config.owner.rawValue),
                                 detail: PrivacyToken(trigger.rawValue))
                return true
            } catch {
                // A restart that will not start is a broken graph after all; fall through to the
                // heavier path rather than reporting a success nobody can hear. The queue comes
                // with us — the graph is being replaced, not the audio abandoned.
                PrivacyLog.audio(.realtime, .engineRestartFailed, owner: PrivacyToken(config.owner.rawValue),
                                 detail: PrivacyToken(trigger.rawValue),
                                 error: SafeErrorSummary(error))
                carriedPlayback = pendingPlayback.drain()
                attemptAudioResetOnQueue()
                return false
            }

        case .rebuild(let carryPlayback):
            PrivacyLog.audio(.realtime, .engineRebuilt, owner: PrivacyToken(config.owner.rawValue),
                             detail: PrivacyToken(trigger.rawValue + (carryPlayback ? "-carry" : "-drop")))
            if carryPlayback {
                // Take the queue off the doomed player node before the teardown detaches it;
                // `rescheduleCarriedPlaybackOnQueue` puts it on the new one.
                carriedPlayback = pendingPlayback.drain()
            } else {
                // The buffers no longer match the graph they were built for, so they cannot come
                // along — but the wearer not hearing them is a fact the backend has to be told.
                reportPlaybackLoss(frames: pendingPlayback.discardAll(),
                                   context: "formatChangedUnderQueue")
            }
            attemptAudioResetOnQueue()
            return false
        }
    }

    /// Rebuild the session + engine on a fresh route. Runs on the lifecycle queue; the actual
    /// re-setup hops to the main actor (the normal `setupAudioSession`/`startCapture` path), which
    /// re-enters the lifecycle queue via `syncOnAudioLifecycleQueue` without deadlocking.
    private func attemptAudioResetOnQueue() {
        let wasCapturing = isCapturing
        let mode = useIPhoneMode
        tearDownEngineGraphOnQueue(flushPendingAudio: false) { [weak self] in
            guard let self, wasCapturing else { return }
            // BO: hop OFF the lifecycle queue to the main actor and await the now-async
            // setupAudioSession. This async hop is what lets the recovery path re-enter the
            // lifecycle queue (via startCapture's syncOnAudioLifecycleQueue) without deadlocking —
            // see the queue-ordering contract in the type header.
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await self.setupAudioSession(useIPhoneMode: mode)
                    try self.startCapture()
                    PrivacyLog.audio(.realtime, .resetSucceeded, owner: PrivacyToken(self.config.owner.rawValue))
                } catch {
                    PrivacyLog.audio(.realtime, .resetFailed, owner: PrivacyToken(self.config.owner.rawValue),
                                     error: SafeErrorSummary(error))
                }
                // CW P2: runs on both paths. On success it re-schedules the carried buffers onto
                // the new player node; on failure it reports them lost. Either way the queue does
                // not just evaporate.
                self.syncOnAudioLifecycleQueue { self.rescheduleCarriedPlaybackOnQueue() }
            }
        }
    }

    /// Tear down the engine graph: stop the engine, remove the tap, detach the player. The engine
    /// container is preserved. `completion` runs after the pending-audio flush is processed.
    private func tearDownEngineGraphOnQueue(flushPendingAudio: Bool, completion: (() -> Void)? = nil) {
        audioGraphGeneration &+= 1
        isCapturing = false
        // The tap this described is about to be removed; a stale format here would make the next
        // recovery compare against a graph that no longer exists.
        tapInputFormat = nil
        // The player node is about to be detached, taking its queue with it. Rebuild paths have
        // already drained or reported the mirror, so this only clears a deliberate stop's tail —
        // silently, because a stop the wearer asked for is not a loss to announce.
        pendingPlayback.discardAll()

        audioEngine.stop()

        if isInputTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            isInputTapInstalled = false
        }
        if isPlayerNodeAttached {
            if playerNode.isPlaying { playerNode.stop() }
            audioEngine.disconnectNodeOutput(playerNode)
            audioEngine.detach(playerNode)
            isPlayerNodeAttached = false
        }

        sendQueue.async {
            defer { completion?() }
            let pending = self.accumulatedData
            self.accumulatedData = Data()
            self.accumulatorGeneration = 0
            if flushPendingAudio, !pending.isEmpty {
                self.onAudioCaptured?(pending)
            }
        }
    }

    /// Apply `AudioRoutePolicy`: prefer the glasses (Bluetooth/LE) input when present, otherwise
    /// fall back to the phone speaker with a logged message.
    private func applyRoutePolicy(_ session: AVAudioSession, useIPhoneMode: Bool) {
        let availableInputs = (session.availableInputs ?? []).map { $0.portType }
        let routePorts = session.currentRoute.inputs.map { $0.portType }
            + session.currentRoute.outputs.map { $0.portType }
        let decision = AudioRoutePolicy.decide(
            availableInputs: availableInputs,
            currentRoute: routePorts,
            useIPhoneMode: useIPhoneMode,
            forceSpeaker: false
        )

        if let portType = decision.preferredInputPortType,
           let input = session.availableInputs?.first(where: { $0.portType == portType }) {
            do {
                try session.setPreferredInput(input)
                PrivacyLog.audio(.realtime, .preferredInputSet, owner: PrivacyToken(config.owner.rawValue),
                                 device: PrivateIdentifier(input.portName),
                                 detail: PrivacyToken(portType.rawValue))
            } catch {
                PrivacyLog.audio(.realtime, .preferredInputFailed, owner: PrivacyToken(config.owner.rawValue),
                                 error: SafeErrorSummary(error))
            }
        }
        if decision.overrideToSpeaker {
            try? session.overrideOutputAudioPort(.speaker)
        }
        if decision.fallbackMessage != nil {
            PrivacyLog.audio(.realtime, .noMatchingInput, owner: PrivacyToken(config.owner.rawValue),
                             detail: PrivacyToken("glassesAudioUnavailable"))
        }
    }

    private func syncOnAudioLifecycleQueue<T>(_ work: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: audioLifecycleQueueKey) != nil {
            return try work()
        }
        return try audioLifecycleQueue.sync(execute: work)
    }

    // MARK: - Private Helpers

    private func calculateRMS(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let floatData = buffer.floatChannelData else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<count {
            let sample = floatData[0][i]
            sum += sample * sample
        }
        return sqrtf(sum / Float(count))
    }

    private func float32ToInt16Data(_ buffer: AVAudioPCMBuffer) -> Data {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0, let floatData = buffer.floatChannelData else { return Data() }
        var int16Array = [Int16](repeating: 0, count: frameCount)
        for i in 0..<frameCount {
            let sample = max(-1.0, min(1.0, floatData[0][i]))
            int16Array[i] = Int16(sample * Float(Int16.max))
        }
        return int16Array.withUnsafeBufferPointer { ptr in
            Data(buffer: ptr)
        }
    }

    private func convertBuffer(
        _ inputBuffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        targetFormat: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = targetFormat.sampleRate / inputBuffer.format.sampleRate
        let outputFrameCount = UInt32(Double(inputBuffer.frameLength) * ratio)
        guard outputFrameCount > 0 else { return nil }

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCount) else {
            return nil
        }

        var error: NSError?
        var consumed = false
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        return error == nil ? outputBuffer : nil
    }
}
