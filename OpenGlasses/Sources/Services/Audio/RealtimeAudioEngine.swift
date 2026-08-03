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
    private var useIPhoneMode = false
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
        NSLog("%@ Session mode: %@", config.logPrefix, useIPhoneMode ? "voiceChat (iPhone)" : "videoChat (glasses)")
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

        NSLog("%@ Native input: %.0fHz %dch, needs resample: %@", config.logPrefix,
              inputNativeFormat.sampleRate, inputNativeFormat.channelCount,
              needsResample ? "YES" : "NO")

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
                        NSLog("%@ Client VAD interrupt (RMS: %.4f)", self.config.logPrefix, rms)
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
            NSLog("%@ Capture started — duplex tier: %@", config.logPrefix, duplexCapability.rawValue)
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
            NSLog("%@ Voice processing enable failed (%@) — falling back to half-duplex",
                  config.logPrefix, error.localizedDescription)
            replaceEngineOnQueue()
            return
        }

        let format = audioEngine.inputNode.outputFormat(forBus: 0)
        switch VoiceProcessingProbe.verdict(sampleRate: format.sampleRate,
                                            channelCount: format.channelCount) {
        case .usable:
            duplexCapability = .echoCancelled
        case .deadIO(let reason):
            NSLog("%@ Voice processing came up dead (%@) — rebuilding without it",
                  config.logPrefix, reason)
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
        if !audioEngine.isRunning {
            do {
                try audioEngine.start()
                NSLog("%@ Playback engine was dead — restarted before scheduling", config.logPrefix)
            } catch {
                NSLog("%@ Playback engine restart failed (%@) — dropping %d bytes",
                      config.logPrefix, error.localizedDescription, data.count)
                return
            }
        }

        guard let playerFormat = try? AudioFormatFactory.pcm(
            .pcmFormatFloat32,
            sampleRate: config.outputSampleRate,
            channels: config.channels,
            interleaved: false,
            context: "playback"
        ) else {
            NSLog("%@ Invalid playback format — dropping %d bytes", config.logPrefix, data.count)
            return
        }

        let frameCount = UInt32(data.count) / (config.bitsPerSample / 8 * config.channels)
        guard frameCount > 0 else { return }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: playerFormat, frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount

        guard let floatData = buffer.floatChannelData else { return }
        data.withUnsafeBytes { rawBuffer in
            guard let int16Ptr = rawBuffer.bindMemory(to: Int16.self).baseAddress else { return }
            for i in 0..<Int(frameCount) {
                floatData[0][i] = Float(int16Ptr[i]) / Float(Int16.max)
            }
        }

        // CJ item 6: count this buffer as played only when the hardware confirms it rendered.
        // `.dataPlayedBack` callbacks also fire for buffers a later `stop()` discards — the
        // ledger's generation check drops those (discarded ≠ heard).
        let generation = playbackLedger.scheduled(frames: frameCount)
        playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            self?.audioLifecycleQueue.async {
                self?.playbackLedger.played(frames: frameCount, generation: generation)
            }
        }
        if !playerNode.isPlaying {
            playerNode.play()
        }
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
            self?.playbackLedger.reset()
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
                NSLog("%@ Interruption began — engine paused", self.config.logPrefix)
            case .resume:
                NSLog("%@ Interruption ended — resuming", self.config.logPrefix)
                self.resumeAfterInterruptionOnQueue()
            case .resetGraph:
                self.attemptAudioResetOnQueue()
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
                NSLog("%@ Route changed (reason %lu) — resetting engine", self.config.logPrefix, raw)
                self.attemptAudioResetOnQueue()
            }
        }
    }

    private func resumeAfterInterruptionOnQueue() {
        // Only reactivate if this engine still owns the shared session — a resume after a phone
        // call must not stomp whoever acquired it meanwhile (wake word, the other realtime engine).
        let owner = AudioSessionCoordinator.shared.currentOwner
        guard AudioInterruptionPolicy.mayResume(engineOwner: config.owner, currentOwner: owner) else {
            NSLog("%@ Interruption ended — NOT resuming; session owned by %@",
                  config.logPrefix, owner?.rawValue ?? "nobody")
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
            NSLog("%@ Resumed after interruption", config.logPrefix)
        } catch {
            NSLog("%@ Resume failed: %@ — resetting", config.logPrefix, error.localizedDescription)
            attemptAudioResetOnQueue()
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
                    NSLog("%@ Audio reset successful", self.config.logPrefix)
                } catch {
                    NSLog("%@ Audio reset failed: %@", self.config.logPrefix, error.localizedDescription)
                }
            }
        }
    }

    /// Tear down the engine graph: stop the engine, remove the tap, detach the player. The engine
    /// container is preserved. `completion` runs after the pending-audio flush is processed.
    private func tearDownEngineGraphOnQueue(flushPendingAudio: Bool, completion: (() -> Void)? = nil) {
        audioGraphGeneration &+= 1
        isCapturing = false

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
                NSLog("%@ Preferred input: %@ (%@)", config.logPrefix, input.portName, portType.rawValue)
            } catch {
                NSLog("%@ Could not set preferred input: %@", config.logPrefix, error.localizedDescription)
            }
        }
        if decision.overrideToSpeaker {
            try? session.overrideOutputAudioPort(.speaker)
        }
        if let message = decision.fallbackMessage {
            NSLog("%@ %@", config.logPrefix, message)
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
