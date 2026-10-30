import Foundation
import SwiftUI
import UIKit
import AVFoundation

/// Shared conversation lifecycle, audio, camera, tool dispatch and recovery coordination.
/// RealtimeProviderSession supplies the selected provider's protocol behavior.
@MainActor
class RealtimeSessionManager: ObservableObject {
    @Published var isActive: Bool = false
    /// The wearer muted the mic without ending the session (a temple tap, Plan GJ P3). Capture
    /// keeps running; nothing is sent while this is set. Cleared when a session starts or stops,
    /// so a mute never outlives the session it was made in.
    @Published var micMuted: Bool = false {
        // Plan HY P1: muting or unmuting is the wearer touching the session — a temple tap or the
        // control — and so is activity, whichever way it went.
        didSet { if micMuted != oldValue { idleClock.noteActivity() } }
    }
    /// Plan FF P1/PR4 — which session this is. Bumped on every start, so work begun for one
    /// session (a sharp capture in flight) can tell that it came back to a different one.
    private(set) var sessionIdentity: Int = 0
    @Published var connectionState: RealtimeConnectionState = .disconnected
    @Published var isModelSpeaking: Bool = false
    @Published var userTranscript: String = ""
    @Published var aiTranscript: String = ""
    @Published var toolCallStatus: ToolCallStatus = .idle
    @Published var openClawConnectionState: OpenClawConnectionState = .notConfigured
    @Published var reconnecting: Bool = false
    @Published var errorMessage: String?
    /// Plan HY P1 — why the last session ended, kept after the stop so the status card can say it
    /// ("Session ended after 10 minutes without activity"). Cleared when the next session starts.
    @Published private(set) var endReason: LiveSessionEndReason?

    /// Plan HY P1 — ends a session nobody is using. Fed by the wearer's activity only; see
    /// ``LiveIdlePolicy`` for what counts and why model speech does not.
    let idleClock = LiveIdleClock()
    /// Test seam for the idle warning. `nil` in the app, where the line goes through the session's
    /// own voice (``speakIdleWarning(_:)``).
    var idleWarningSpeaker: ((String) -> Void)?

    // Shared OpenClaw bridge (injected from AppState)
    var openClawBridge: OpenClawBridge?

    // Native tool router (injected from AppState)
    var nativeToolRouter: NativeToolRouter?

    /// The guided job flow, applied to this backend (Plan FO P3a). The same object the OpenAI
    /// Realtime manager owns: one seam, two backends, so what the model is told about a job cannot
    /// depend on which provider answered.
    let jobBridge = LiveJobBridge()

    // Internal components
    private var providerSession: RealtimeProviderSession!
    private var audioManager = RealtimeAudioEngine(config: .geminiLive)
    private let legacyMode: AppMode?
    private(set) var sessionMode: AppMode = .geminiLive
    private(set) var sessionModel: RealtimeModelConfig?
    init(legacyMode: AppMode? = nil) { self.legacyMode = legacyMode }
    var supportsVision: Bool { sessionModel?.capabilities?.vision ?? true }
    var supportsTextInjection: Bool { sessionModel?.capabilities?.textInjection ?? true }
    var supportsContextUpdates: Bool { sessionModel?.capabilities?.contextUpdate ?? true }
    var supportsSuppliedSpeech: Bool { sessionModel?.capabilities?.suppliedSpeech ?? false }
    private var logProvider: PrivacyLog.RealtimeProvider {
        switch sessionModel?.profile {
        case .geminiLiveV1: return .gemini
        case .qwenOmniV1, .qwenAudioV1: return .qwen
        case .doubaoDuplexV3: return .doubao
        default: return sessionModel?.providerID == "openai" ? .openai : .compatible
        }
    }
    private var memoryRoute: MemoryContextSnapshot.Route { sessionModel?.profile == .geminiLiveV1 ? .liveGemini : .liveOpenAI }
    private let frameThrottler = FrameThrottler()
    private var toolCallRouter: ToolCallRouter?
    private var stateObservation: Task<Void, Never>?

    /// Plan FF P1/PR5 — the phone's own bounded, in-memory record of this session's turns, and the
    /// object that decides what a reconnect actually restored. Both live and die with the session.
    private let conversationRecorder = LiveConversationRecorder()
    private var recoveryDriver: LiveRecoveryDriver?
    /// When this session started. Bounds the journal read a handover makes: the journal is durable
    /// and outlives sessions, and an operation from last week is not part of this conversation.
    private var sessionStartedAt: Date?

    /// Local, network-independent speech for terminal session cues (Plan BD) — never ElevenLabs,
    /// since the network may be exactly what failed.
    private let localCueSynth = AVSpeechSynthesizer()

    private func speakLocalCue(_ text: String) {
        let utterance = AVSpeechUtterance(string: SpeechPronunciation.spokenForm(of: text))
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        localCueSynth.speak(utterance)
    }

    /// Plan FF P0/PR2 — report lifecycle facts to the audible-lifecycle coordinator.
    ///
    /// Returns whether the coordinator took responsibility for telling the wearer. The local cues
    /// below stay exactly as they were whenever it did not: this manager still owns the spoken
    /// fallback for every wearer who has not selected the Blind Assistant preset, and two voices
    /// saying the same thing is the failure the return value exists to prevent.
    var onLifecycle: ((AudibleLifecycleCoordinator.Signal) -> Bool)?

    /// The goodbye has been said and heard. AppState stops the session the way the wearer's other
    /// controls do; with nobody listening, the session stops itself.
    var onSaidGoodbye: (() -> Void)?
    private var voiceEnd = LiveVoiceEndTracker()
    /// Whether the model has said anything in the turn under way.
    private var turnHadReply = false
    /// The idle warning is being spoken by the model, so its audio answers nobody.
    private var idleWarningInTurn = false
    /// Plan GE P3: the conversation carried on on the phone while the signal was gone; the next
    /// start opens with this handover block (``LiveContextHandover``) so the session picks up where
    /// the phone left off. Consumed by that start.
    var pendingResumeContext: String?

    /// Plan HY P0 — the turns a mode switch carries into the next session, read while this one is
    /// still up: `stopSession()` resets the record, so the switch reads it before its teardown.
    /// The same bounded window a reconnect handover uses, in-flight turns included.
    var handoverTurns: [LiveTurnRecord] {
        conversationRecorder.recentTurns(LiveContextHandover.maxTurns)
    }

    // Camera frame source — set by AppState to the existing CameraService's periodic captures
    var onRequestVideoFrame: (() async -> UIImage?)?

    // Location context — set by AppState from LocationService
    var locationContext: (() -> String?)?

    // Camera streaming control — set by AppState to start/check camera streaming
    var onRequestStartCamera: (() async -> Bool)?
    var cameraFailureNotice: (() -> String?)?

    /// Awaited as a session starts, before the camera, the audio session or the socket are touched
    /// — the moment `AppState` says "Connecting to Avenkin AI." through the app's own voice, once
    /// per launch (Plan HP P2 item 10). Before the session takes the audio route, so the line is
    /// not captured by the microphone and sent to the model as speech.
    var onWillConnect: (() async -> Void)?

    /// Give back the camera this session started. Plan EW: the session takes a stream claim
    /// rather than starting the camera outright, so ending — or failing to start — releases
    /// exactly the stream it opened and leaves alone one the wearer opened themselves.
    var onRequestStopCamera: (() async -> Void)?

    /// Whether the camera is actively streaming frames (used to conditionalise the vision prompt).
    var isCameraStreaming: Bool = false

    /// The camera's own readiness snapshot (Plan FD P0), supplied by AppState. Read on reconnect to
    /// decide whether a camera start is even permissible — a paused stream is waited out, never
    /// started into (Plan FD P1 / `LiveRecoveryCameraPolicy`).
    var cameraReadiness: (() -> CameraReadiness)?

    /// Whether to use iPhone audio mode (voiceChat with echo suppression) or glasses mode (videoChat).
    /// When true: aggressive echo cancellation + mic muting during model speech (co-located speaker/mic).
    /// When false: mild AEC suitable for remote mic on glasses (speaker on phone, mic on glasses).
    var useIPhoneAudioMode: Bool = true

    // Diagnostic counters
    private var submittedFrameCount = 0
    private var droppedNotActive = 0
    private var droppedNotReady = 0

    /// Submit a video frame directly (called from CameraService's continuous streaming callback).
    /// This bypasses the polling timer for lower latency.
    func submitVideoFrame(_ image: UIImage) {
        guard supportsVision, !Config.audioOnlyMode else { return }
        guard isActive else {
            droppedNotActive += 1
            if droppedNotActive <= 3 {
                PrivacyLog.realtimeSession(logProvider, .frameDropped,
                                           detail: PrivacyToken("notActive"), count: droppedNotActive)
            }
            return
        }
        if !isCameraStreaming {
            isCameraStreaming = true
            PrivacyLog.realtimeSession(logProvider, .firstCameraFrame)
        }
        guard connectionState == .ready else {
            droppedNotReady += 1
            if droppedNotReady <= 5 || droppedNotReady % 30 == 0 {
                PrivacyLog.realtimeSession(logProvider, .frameDropped,
                                           detail: PrivacyToken("notReady"),
                                           state: PrivacyToken(String(describing: connectionState)),
                                           count: droppedNotReady)
            }
            return
        }
        submittedFrameCount += 1
        if submittedFrameCount <= 3 || submittedFrameCount % 30 == 0 {
            PrivacyLog.realtimeSession(logProvider, .frameForwarded, count: submittedFrameCount)
        }
        // Stretch the frame interval under battery/thermal pressure (Plan BV P2). Same-actor read,
        // refreshed per submitted frame so a posture change takes effect immediately.
        frameThrottler.powerIntervalMultiplier = PowerPolicyService.shared.posture.frameIntervalMultiplier
        frameThrottler.submit(image)
    }

    // Timer for periodic frame capture
    private var frameTimer: Task<Void, Never>?

    /// Plan CE: after an unpin the next live frame must reach the model as a keyframe — reset
    /// the throttler's dedup gate so it isn't dropped as "same scene" as the pinned frame.
    func resetFrameGateAfterPin() {
        frameThrottler.reset()
    }

    // MARK: - Session Lifecycle

    func startSession() async {
        guard !isActive else { return }

        let mode = legacyMode ?? Config.appMode
        guard let model = Config.realtimeModel(for: mode) else {
            errorMessage = String(localized: "Add a realtime model in Settings first.")
            return
        }
        do { _ = try model.request(); try MedicalEgressGuard.check(model.route) }
        catch { errorMessage = error.localizedDescription; return }
        sessionMode = mode
        sessionModel = model
        providerSession = RealtimeProviderSession(model: model)
        audioManager = RealtimeAudioEngine(config: model.profile!.audioConfiguration)

        isActive = true
        micMuted = false
        sessionIdentity += 1
        let identity = sessionIdentity
        errorMessage = nil
        // FF P1/PR5: a session's record belongs to that session and to nothing else.
        conversationRecorder.reset()
        sessionStartedAt = Date()
        // Plan HY P1: the quiet spell starts with the session. Started this early so a start that
        // hangs (a cue that never finishes, a connect that never answers) is still bounded.
        endReason = nil
        startIdleClock(identity: identity)

        await onWillConnect?()
        // Stopped while the cue played.
        guard isActive, sessionIdentity == identity else { return }

        // Ensure camera streaming is active (may have failed on mode switch if glasses weren't connected).
        // If startCamera succeeds, trust that frames will arrive — the user has approved camera permission
        // through the Meta companion app dialog, so we should build the vision prompt immediately rather
        // than waiting for the first frame (which may take seconds after permission approval).
        if supportsVision, let startCamera = onRequestStartCamera {
            let cameraOk = await startCamera()
            guard isActive, sessionIdentity == identity else { return }
            PrivacyLog.realtimeSession(self.logProvider, .cameraStarted, success: cameraOk)
            if cameraOk {
                isCameraStreaming = true
            }
        }

        // Configure the selected provider with instructions, vision context, location and tools.
        // Only declare OpenClaw tools if the gateway is actually connected (prevents the live model
        // from attempting tool calls that will fail when gateway is unreachable).
        let resumeContext = pendingResumeContext
        pendingResumeContext = nil
        let systemInstruction = buildSystemInstruction(recoveredContext: resumeContext)
        // The instruction embeds location, the mode prefix and the live contexts (vault, visual
        // state, project, reading) — its length is what a context-overflow report needs, and all
        // of it that may be persisted. Wearer memory is *not* among them; see the record at the
        // end of `buildSystemInstruction`.
        PrivacyLog.realtimeSession(self.logProvider, .systemInstructionBuilt,
                                   detail: PrivacyToken(isCameraStreaming ? "vision" : "audioOnly"),
                                   characters: systemInstruction.count)
        let openClawConnected = openClawBridge?.connectionState == .connected
        // BK P0: expose the gateway `execute` tool only when it's an active agentic capability
        // (configured AND Agent Mode on) — Gemini Live had the same isOpenClawConfigured-only gap
        // as Direct mode, handing the model an execute schema + full-machine-access prompt.
        let includeOpenClaw = Config.isOpenClawAgentActive && openClawConnected
        if Config.isOpenClawAgentActive && !openClawConnected {
            PrivacyLog.realtimeSession(self.logProvider, .gatewayToolOmitted)
        }
        let toolDefs = sessionToolDeclarations(includeOpenClaw: includeOpenClaw)
        providerSession.configure(systemInstruction: systemInstruction, toolDeclarations: toolDefs)

        // Wire microphone capture to the selected provider
        // Echo suppression is a policy of the reached duplex tier (Plan CC), not a blanket mute:
        // with voice processing alive the mic stays open while the model speaks (real barge-in via
        // server VAD); on the half-duplex fallback this is the old mute — drop iPhone-mode buffers
        // during model speech so the co-located loudspeaker can't feed the model its own voice.
        audioManager.onAudioCaptured = { [weak self] data in
            guard let self, self.isActive, self.sessionIdentity == identity else { return }
            Task { @MainActor in
                guard self.isActive, self.sessionIdentity == identity else { return }
                let forward = EchoSuppressionPolicy.shouldForwardCapturedBuffer(
                    wearerMuted: self.micMuted,
                    capability: self.audioManager.duplexCapability,
                    iPhoneMode: self.useIPhoneAudioMode,
                    modelSpeaking: self.providerSession.isModelSpeaking)
                self.providerSession.setMuted(!forward)
                guard forward else { return }
                self.providerSession.sendAudio(data: data)
            }
        }

        providerSession.playedAudioMilliseconds = { [weak self] in self?.audioManager.confirmedPlayedMilliseconds ?? 0 }
        providerSession.onOperationRejected = { [weak self] message in self?.errorMessage = message }
        audioManager.onVoiceInterrupt = { [weak self] in
            Task { @MainActor in
                guard let self, self.isActive, self.sessionIdentity == identity else { return }
                // Plan HY P1: the local VAD heard the wearer start speaking over the model.
                self.idleClock.noteSpeechHeard()
                self.providerSession.cancelResponse()
            }
        }
        audioManager.onPlaybackDiscarded = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isActive, self.sessionIdentity == identity else { return }
                self.providerSession.cancelResponse()
            }
        }
        // Plan HY P1: the server's voice-activity speech-start — the wearer began talking, before
        // any transcript of it exists.
        providerSession.onUserSpeechStarted = { [weak self] in
            guard let self, self.isActive, self.sessionIdentity == identity else { return }
            self.idleClock.noteSpeechHeard()
        }
        // Wire provider audio → playback
        providerSession.onAudioReceived = { [weak self] data in
            guard let self, self.isActive, self.sessionIdentity == identity else { return }
            self.noteModelReply()
            self.audioManager.playAudio(data: data)
        }

        // Wire interruption → stop playback
        providerSession.onInterrupted = { [weak self] in
            guard let self, self.isActive, self.sessionIdentity == identity else { return }
            self.audioManager.stopPlayback()
            // FF P1/PR5: an answer the wearer spoke over is committed marked. What they heard of it
            // is unknown, and a handover must never present it as delivered.
            self.conversationRecorder.noteInterruption()
        }

        // Wire turn complete
        providerSession.onTurnComplete = { [weak self] in
            guard let self, self.isActive, self.sessionIdentity == identity else { return }
            Task { @MainActor in
                guard self.isActive, self.sessionIdentity == identity else { return }
                self.audioManager.resetPlaybackProgress()
                self.conversationRecorder.completeTurn()
                // Delta-based transcripts finish at the turn boundary. JSON adapters already
                // recorded their complete input transcript when that event arrived.
                let wearer = self.userTranscript
                self.userTranscript = ""
                self.finishTurnForVoiceEnd(wearer: wearer)
                if self.providerSession.inputTranscriptionIsDelta {
                    await self.jobBridge.handleTranscript(wearer, sourceID: "realtime-\(identity)-\(UUID().uuidString)")
                }
                await self.jobBridge.turnCompleted()
            }
        }

        // Wire transcriptions
        // Script-aware joining (Plan BY): live transcription arrives in word-segmented chunks
        // with separator spaces — naive += rendered Chinese as "你手里 拿的 是". The joiner
        // collapses the seam only when both neighbours are CJK, so Latin spacing is untouched.
        providerSession.onInputTranscription = { [weak self] text in
            guard let self, self.isActive, self.sessionIdentity == identity else { return }
            Task { @MainActor in
                guard self.isActive, self.sessionIdentity == identity else { return }
                // Plan HY P1: not activity yet. It counts once the model answers it.
                self.idleClock.noteSpeechHeard()
                self.userTranscript = self.providerSession.inputTranscriptionIsDelta
                    ? ScriptAwareJoiner.join(self.userTranscript, text) : text
                if !self.providerSession.inputTranscriptionIsDelta {
                    await self.jobBridge.handleTranscript(text, sourceID: "realtime-\(identity)-\(UUID().uuidString)")
                }
                self.aiTranscript = ""
                // FF P1/PR5: the phone's own record. Passed the whole accumulated string so it
                // shares this joiner rather than re-implementing it.
                self.conversationRecorder.setWearerTurn(self.userTranscript)
                // BR P1: a user turn resets the runaway-tool-call window.
                self.toolCallRouter?.noteUserTurn()
                // The wearer is asking about what is in front of them *now*. With the content gate
                // on, a still scene forwards nothing between heartbeats, so the answer could be
                // built on a frame up to twelve seconds old. Force one through.
                self.frameThrottler.requestFreshFrame()
            }
        }

        providerSession.onOutputTranscription = { [weak self] text in
            guard let self, self.isActive, self.sessionIdentity == identity else { return }
            Task { @MainActor in
                guard self.isActive, self.sessionIdentity == identity else { return }
                self.noteModelReply()
                self.aiTranscript = ScriptAwareJoiner.join(self.aiTranscript, text)
                self.conversationRecorder.setAssistantTurn(self.aiTranscript)
            }
        }

        // Wire disconnection
        providerSession.onDisconnected = { [weak self] reason in
            guard let self, self.isActive, self.sessionIdentity == identity else { return }
            Task { @MainActor in
                guard self.isActive, self.sessionIdentity == identity else { return }
                guard self.isActive else { return }
                // FF P1/PR5: whatever was being said when the socket went is now unfinished, and a
                // handover has to say so rather than hand the answer back as though it landed.
                self.conversationRecorder.noteInterruption()
                if !self.providerSession.reconnecting {
                    // Report the loss before the teardown: after `stopSession()` there is no
                    // session left for the cue to be about.
                    let claimed = self.onLifecycle?(.connectionLost) ?? false
                    self.stopSession()
                    self.errorMessage = String(localized: "Connection lost: \(reason ?? String(localized: "Unknown error"))")
                    // Voice-first: the phone may be pocketed, so a visual banner isn't enough (Plan BD).
                    if !claimed { self.speakLocalCue("Voice session disconnected.") }
                }
            }
        }

        // Reconnection exhausted → terminal. Speak an audible cue and surface the error.
        providerSession.onReconnectExhausted = { [weak self] in
            guard let self, self.isActive, self.sessionIdentity == identity else { return }
            Task { @MainActor in
                guard self.isActive, self.sessionIdentity == identity else { return }
                guard self.isActive else { return }
                let claimed = self.onLifecycle?(.reconnectExhausted) ?? false
                self.stopSession()
                self.errorMessage = String(localized: "Voice session lost — couldn't reconnect.")
                if !claimed { self.speakLocalCue("Voice session lost. I couldn't reconnect.") }
            }
        }

        // Wire reconnection. Plan FF P1/PR5: the decisions live in `LiveRecoveryDriver`, which is
        // constructible headlessly; this is the wiring that gives it the real session to act on.
        recoveryDriver = LiveRecoveryDriver(seams: makeRecoverySeams())
        providerSession.onReconnected = { [weak self] in
            guard let self, self.isActive, self.sessionIdentity == identity else { return }
            Task { @MainActor in
                guard self.isActive, self.sessionIdentity == identity else { return }
                PrivacyLog.realtimeSession(self.logProvider, .reconnected)
                await self.recoveryDriver?.handleReconnected()
            }
        }

        // Wire tool calls — native tools always available, OpenClaw only as an active agentic
        // capability (BK P0: configured AND Agent Mode on).
        let hasNativeTools = nativeToolRouter != nil
        let hasOpenClaw = Config.isOpenClawAgentActive && openClawBridge != nil

        if hasNativeTools || hasOpenClaw {
            if let bridge = openClawBridge, hasOpenClaw {
                await bridge.checkConnection()
                guard isActive, sessionIdentity == identity else { return }
                // BR P4: no resetSession() here — the gateway session key is stable now, so
                // the OpenClaw-side agent keeps context across Live sessions. Reset is a
                // deliberate user action, not a side effect of starting a session.
            }

            let bridge = openClawBridge ?? OpenClawBridge()
            toolCallRouter = ToolCallRouter(bridge: bridge)
            toolCallRouter?.supportsNonBlockingResponses = model.profile == .geminiLiveV1
            toolCallRouter?.nativeToolRouter = nativeToolRouter
            toolCallRouter?.onEndLiveSession = { [weak self] in
                guard let self, self.isActive, self.sessionIdentity == identity else { return }
                self.voiceEnd.request(now: Date())
            }

            // Pause/resume camera streaming during tool execution to prevent instability
            // (VisionClaw issue #11: tool-call stability during Gemini Live)
            toolCallRouter?.onToolExecutionStarted = { [weak self] in
                guard let self, self.isActive, self.sessionIdentity == identity else { return }
                PrivacyLog.realtimeSession(self.logProvider, .toolExecutionPaused)
                self.frameThrottler.pause()
            }
            toolCallRouter?.onToolExecutionFinished = { [weak self] in
                guard let self, self.isActive, self.sessionIdentity == identity else { return }
                PrivacyLog.realtimeSession(self.logProvider, .toolExecutionResumed)
                self.frameThrottler.resume()
            }

            providerSession.onToolCall = { [weak self] toolCall in
                guard let self, self.isActive, self.sessionIdentity == identity else { return }
                Task { @MainActor in
                guard self.isActive, self.sessionIdentity == identity else { return }
                    // Plan HY P1: a tool call is the session doing the wearer's work, and so is its
                    // result coming back below.
                    self.idleClock.noteActivity()
                    for call in toolCall.functionCalls {
                        // `self` is already strongly held by the enclosing handler (guard let self
                        // above) for the duration of this response, so a redundant inner [weak self]
                        // only tripped the ownership-mismatch warning.
                        self.toolCallRouter?.handleToolCall(call) { response in
                            guard self.isActive, self.sessionIdentity == identity else { return }
                            self.idleClock.noteActivity()
                            self.providerSession.sendToolResponse(response)
                        }
                    }
                }
            }

            providerSession.onToolCallCancellation = { [weak self] cancellation in
                guard let self, self.isActive, self.sessionIdentity == identity else { return }
                Task { @MainActor in
                guard self.isActive, self.sessionIdentity == identity else { return }
                    self.toolCallRouter?.cancelToolCalls(ids: cancellation.ids)
                }
            }
        }

        // Observe the selected provider and OpenClaw state every 100ms
        stateObservation = Task { [weak self] in
            guard let self, self.isActive, self.sessionIdentity == identity else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard !Task.isCancelled, self.isActive, self.sessionIdentity == identity else { break }
                if self.voiceEnd.isPending,
                   self.voiceEnd.shouldStop(
                    now: Date(), toolRunning: self.toolCallRouter?.hasInFlightCalls ?? false,
                    playbackPending: self.providerSession.isModelSpeaking || self.audioManager.hasPendingPlayback) {
                    self.finishVoiceEnd()
                    break
                }
                // Assign only on change — an unconditional write fires objectWillChange at 10 Hz for
                // the whole session, re-evaluating every observing SwiftUI view (Plan: perf bucket A).
                if self.connectionState != self.providerSession.connectionState {
                    self.connectionState = self.providerSession.connectionState
                }
                if self.isModelSpeaking != self.providerSession.isModelSpeaking {
                    self.isModelSpeaking = self.providerSession.isModelSpeaking
                    self.audioManager.modelSpeaking = self.isModelSpeaking
                }
                if self.reconnecting != self.providerSession.reconnecting {
                    self.reconnecting = self.providerSession.reconnecting
                    // The retry ladder starting is the moment the wearer lost the assistant; the
                    // terminal `onDisconnected` path above cannot fire for this drop, because it
                    // guards on exactly this flag.
                    if self.reconnecting { _ = self.onLifecycle?(.connectionLost) }
                }
                if let bridge = self.openClawBridge {
                    if self.toolCallStatus != bridge.lastToolCallStatus {
                        self.toolCallStatus = bridge.lastToolCallStatus
                    }
                    if self.openClawConnectionState != bridge.connectionState {
                        self.openClawConnectionState = bridge.connectionState
                    }
                }
            }
        }

        // Wire the shared frame throttler to the selected provider
        frameThrottler.reset()
        VisualStateService.shared.reset()
        frameThrottler.onThrottledFrame = { [weak self] image in
            guard let self, self.isActive, self.sessionIdentity == identity else { return }
            self.providerSession.sendVideoFrame(image: image)
        }
        // Feed genuine scene-change keyframes to Visual State Memory (Plan AV).
        // No-op unless visualStateMemoryEnabled; fires only when the content gate is active.
        frameThrottler.onKeyframe = { image in
            VisualStateService.shared.considerKeyframe(image)
        }

        // Audio setup — use iPhone mode when camera NOT streaming (no glasses connected),
        // use glasses/videoChat mode when camera IS streaming (mic is on remote device)
        useIPhoneAudioMode = !isCameraStreaming
        PrivacyLog.realtimeSession(self.logProvider, .audioModeSelected,
                                   detail: PrivacyToken(useIPhoneAudioMode ? "iPhone" : "glasses"))
        do {
            try await audioManager.setupAudioSession(useIPhoneMode: useIPhoneAudioMode)
        } catch {
            guard isActive, sessionIdentity == identity else { return }
            // Plan EW: a failed start has to give back everything a finished one does. It used
            // to hand-roll a partial teardown and set `isActive = false`, which made every
            // `if isActive { stopSession() }` call site in the app skip the real teardown — so
            // the tool router, the frame timer, the microphone lease and the camera stayed held.
            let message = "Audio setup failed: \(error.localizedDescription)"
            stopSession()
            errorMessage = message
            return
        }

        guard isActive, sessionIdentity == identity else { return }

        // Connect to the selected provider
        let setupOk = await providerSession.connect()
        guard isActive, sessionIdentity == identity else { return }

        // Immediately sync connection state so submitVideoFrame doesn't block
        // waiting for the next 100ms poll cycle
        connectionState = providerSession.connectionState
        PrivacyLog.realtimeSession(self.logProvider, .postConnectState,
                                   state: PrivacyToken(String(describing: connectionState)),
                                   count: providerSession.videoFramesSent)

        if !setupOk {
            var errorStateMessage: String?
            if case .error(let err) = providerSession.connectionState { errorStateMessage = err }
            let msg = model.profile == .geminiLiveV1
                ? GeminiLiveFailureCopy.message(errorStateMessage: errorStateMessage, lastCloseReason: providerSession.lastCloseReason)
                : (errorStateMessage ?? "Failed to connect to the realtime service.")
            stopSession()   // Plan EW — the same teardown a finished session gets
            errorMessage = msg
            NoticeCenter.shared.post(msg, severity: .error, source: .liveSession)
            return
        }

        // Start mic capture
        do {
            try audioManager.startCapture()
        } catch {
            let message = "Mic capture failed: \(error.localizedDescription)"
            stopSession()   // Plan EW — the same teardown a finished session gets
            errorMessage = message
            return
        }

        // Late camera retry: if camera failed initially (SDK wasn't ready),
        // Try again after connection setup has given the SDK time to register.
        if supportsVision, !isCameraStreaming, let startCamera = onRequestStartCamera {
            let cameraOk = await startCamera()
            guard isActive, sessionIdentity == identity else { return }
            PrivacyLog.realtimeSession(self.logProvider, .lateCameraRetried, success: cameraOk)
            if cameraOk {
                isCameraStreaming = true
                // Refresh instructions now that camera frames are available
                let updatedInstruction = buildSystemInstruction()
                providerSession.configure(systemInstruction: updatedInstruction,
                                          toolDeclarations: sessionToolDeclarations(includeOpenClaw: hasOpenClaw))
                let visionNow = updatedInstruction.contains("You CAN see")
                PrivacyLog.realtimeSession(self.logProvider, .visionReconfigured, success: visionNow)
                // Switch to glasses audio mode since camera implies glasses are connected
                if !useIPhoneAudioMode {
                    PrivacyLog.realtimeSession(self.logProvider, .audioModeUnchanged,
                                               detail: PrivacyToken("glasses"))
                } else {
                    useIPhoneAudioMode = false
                    PrivacyLog.realtimeSession(self.logProvider, .audioModeSwitched,
                                               detail: PrivacyToken("glasses"))
                    do {
                        try await audioManager.setupAudioSession(useIPhoneMode: false)
                    } catch {
                        PrivacyLog.realtimeSession(self.logProvider, .audioModeSwitchFailed,
                                                   error: SafeErrorSummary(error))
                    }
                }
            }
        }

        guard isActive, sessionIdentity == identity else { return }

        // Start periodic camera frame capture
        startFrameCapture()

        // Plan FF P0/PR2: "usable" is all three facts, not the socket alone — everything above had
        // to succeed to reach here, and the connection state is re-read rather than assumed.
        _ = onLifecycle?(.sessionStarted(.init(audioSessionActive: true,
                                           sessionConnected: providerSession.connectionState == .ready,
                                           microphoneListening: true)))
    }

    /// End the session and give back everything it holds.
    ///
    /// - Parameter reason: why. Kept as ``endReason`` after the stop, for the status card; every
    ///   ordinary stop is `.stopped`, and the idle end (Plan HY P1) is the one that says more.
    func stopSession(reason: LiveSessionEndReason = .stopped) {
        idleClock.stop()
        PrivacyLog.realtimeSession(logProvider, .sessionStopped, count: submittedFrameCount)
        PrivacyLog.realtimeSession(logProvider, .frameDropped, detail: PrivacyToken("notActive"),
                                   count: droppedNotActive)
        PrivacyLog.realtimeSession(logProvider, .frameDropped, detail: PrivacyToken("notReady"),
                                   count: droppedNotReady)
        // Plan FC P3: the connect-time snapshot describes a session that no longer exists. Drop it
        // rather than let a diagnostics export age it forever.
        MemoryContextRecorder.forgetLive(memoryRoute)
        let hadCameraClaim = isCameraStreaming
        toolCallRouter?.cancelAll()
        toolCallRouter = nil
        // FF P1/PR5: a stop cancels a recovery still working, and forgets the record it would have
        // rebuilt from. Ending a session is the same act as forgetting it.
        recoveryDriver?.noteStop()
        recoveryDriver = nil
        conversationRecorder.reset()
        // Plan FO P3a — nothing the session was told about the job survives the session.
        jobBridge.sessionEnded()
        sessionStartedAt = nil
        frameTimer?.cancel()
        frameTimer = nil
        audioManager.stopCapture()
        providerSession?.disconnect()
        stateObservation?.cancel()
        stateObservation = nil
        isActive = false
        micMuted = false
        isCameraStreaming = false
        connectionState = .disconnected
        isModelSpeaking = false
        userTranscript = ""
        aiTranscript = ""
        toolCallStatus = .idle
        errorMessage = nil
        submittedFrameCount = 0
        droppedNotActive = 0
        droppedNotReady = 0
        endReason = voiceEnd.isPending ? .saidGoodbye : reason
        voiceEnd = LiveVoiceEndTracker()
        turnHadReply = false
        idleWarningInTurn = false

        // Plan EW: give the camera claim back last, after `isActive` is false. The release asks
        // whether anything else is still consuming the stream, and an active live session is one
        // of the things that counts — asking any earlier would have this session veto its own
        // release. A claim it never started, or one the wearer started first, is left running.
        if hadCameraClaim, let stopCamera = onRequestStopCamera {
            Task { await stopCamera() }
        }
    }

    // MARK: - Idle end (Plan HY P1)

    /// The wearer did something the session's own events cannot see — typed a message, touched a
    /// live control. Resets the quiet spell; a no-op outside a session.
    func noteWearerActivity() {
        guard isActive else { return }
        idleClock.noteActivity()
    }

    /// The model produced speech or a transcript of it.
    private func noteModelReply() {
        turnHadReply = true
        if !idleWarningInTurn { idleClock.noteModelReplied() }
    }

    private func startIdleClock(identity: Int) {
        idleClock.onWarn = { [weak self] in
            guard let self, self.isActive, self.sessionIdentity == identity else { return }
            PrivacyLog.realtimeSession(self.logProvider, .idleWarned)
            self.speakIdleWarning(LiveIdlePolicy.warningLine)
        }
        idleClock.onEnd = { [weak self] in
            guard let self, self.isActive, self.sessionIdentity == identity else { return }
            let minutes = self.idleClock.policy?.idleMinutes ?? Config.liveIdleMinutes
            self.endForIdle(minutes: minutes)
        }
        idleClock.start(policy: LiveIdlePolicy.configured())
    }

    private func endForIdle(minutes: Int) {
        PrivacyLog.realtimeSession(logProvider, .idleEnded, count: minutes)
        stopSession(reason: .idleEnded(minutes: minutes))
    }

    /// Say the warning through the session's own voice: the provider's exact-speech lane when it
    /// has one, a model turn asked to say the line when it can take text, and the local cue voice
    /// only when the session can do neither (not ready, or a protocol with no text lane). Never
    /// ElevenLabs — this is the session talking, not the app.
    private func speakIdleWarning(_ line: String) {
        if let idleWarningSpeaker { idleWarningSpeaker(line); return }
        if canInject, supportsSuppliedSpeech {
            idleWarningInTurn = true
            providerSession.speakText(line)
        } else if canInject, supportsTextInjection {
            idleWarningInTurn = true
            // Plan HY P3: an announcement — the warning must not start a tool call.
            providerSession.sendText(LiveIdlePolicy.warningInstruction, completeTurn: true,
                                     toolsAllowed: false)
        } else {
            speakLocalCue(line)
        }
    }

    // MARK: - Ending by voice

    /// Turn boundary: either the turn a goodbye was waiting on, or a goodbye the model did not act
    /// on. The backstop reads a turn that has already ended, so nothing is left to wait for.
    private func finishTurnForVoiceEnd(wearer: String) {
        let replied = turnHadReply
        turnHadReply = false
        idleWarningInTurn = false
        voiceEnd.noteTurnComplete()
        guard !voiceEnd.isPending else { return }
        let parser = VoiceCommandParser.default.named(Config.assistantName)
        if LiveVoiceEndPolicy.backstopApplies(
            transcript: wearer, modelReplied: replied,
            jobActive: FieldSessionService.shared.activeSession != nil, parser: parser) {
            voiceEnd.request(now: Date(), turnAlreadyEnded: true)
        }
    }

    private func finishVoiceEnd() {
        PrivacyLog.realtimeSession(logProvider, .saidGoodbye)
        if let onSaidGoodbye {
            onSaidGoodbye()
        } else {
            stopSession(reason: .saidGoodbye)
        }
    }

    // MARK: - Recovery (Plan FF P1/PR5)

    /// Hand the recovery driver this session's real world.
    ///
    /// The tool re-declaration and the instruction rebuild stay here because they are this
    /// backend's wire shapes; what the driver owns is the *order* they happen in, the stop checks
    /// between them and what is claimed afterwards.
    private func makeRecoverySeams() -> LiveRecoveryDriver.Seams {
        let identity = sessionIdentity
        return LiveRecoveryDriver.Seams(
            isSessionActive: { [weak self] in self?.isActive == true && self?.sessionIdentity == identity },
            resumedOnServer: { [weak self] in self?.providerSession.lastConnectResumedContext ?? false },
            recentTurns: { [weak self] limit in
                self?.conversationRecorder.recentTurns(limit) ?? []
            },
            interruptedOperations: { [weak self] in
                guard let self, let journal = self.nativeToolRouter?.operationJournal else { return [] }
                return LiveContextHandover.interruptedSideEffectingOperations(
                    in: journal, since: self.sessionStartedAt)
            },
            cameraReadiness: { [weak self] in self?.cameraReadiness?() },
            sessionNeedsVision: { [weak self] in self?.isCameraStreaming ?? false },
            reconfigure: { [weak self] handover in
                guard let self else { return }
                // Re-configure with current settings (including fresh location).
                let includeOpenClaw = Config.isOpenClawAgentActive   // BK P0: gate on Agent Mode too
                var toolDefs = self.sessionToolDeclarations(includeOpenClaw: includeOpenClaw)
                // BR P1: breaker-suspended tools stay out of the re-declared list — the new setup
                // message must not re-offer what this session already tripped on.
                if let suspended = self.toolCallRouter?.suspendedToolNames, !suspended.isEmpty {
                    toolDefs = toolDefs.filter { decl in
                        guard let name = decl["name"] as? String else { return true }
                        return !suspended.contains(name)
                    }
                }
                self.providerSession.configure(
                    systemInstruction: self.buildSystemInstruction(recoveredContext: handover),
                    toolDeclarations: toolDefs, recoveredContext: handover)
            },
            restartMicrophone: { [weak self] in
                guard let self else { return }
                try self.audioManager.startCapture()
            },
            restartFrameCapture: { [weak self] in self?.startFrameCapture() },
            startCamera: { [weak self] in
                guard let self, let startCamera = self.onRequestStartCamera else { return false }
                let ok = await startCamera()
                guard self.isActive, self.sessionIdentity == identity else { return false }
                if ok { self.isCameraStreaming = true }
                PrivacyLog.realtimeSession(self.logProvider, .cameraStarted, success: ok)
                return ok
            },
            report: { [weak self] signal in _ = self?.onLifecycle?(signal) })
    }

    private func sessionToolDeclarations(includeOpenClaw: Bool) -> [[String: Any]] {
        var declarations: [[String: Any]]
        if sessionModel?.profile?.isOpenAIShape == true {
            declarations = ToolDeclarations.declarations(registry: nativeToolRouter?.registry, names: LiveJobContract.jobToolNames)
        } else {
            declarations = ToolDeclarations.allDeclarations(registry: nativeToolRouter?.registry, includeOpenClaw: includeOpenClaw)
        }
        if canHandleToolCalls { declarations.append(LiveVoiceEndPolicy.declaration) }
        return declarations
    }

    /// Whether a tool call from the model has anywhere to go: the condition `onToolCall` is wired
    /// on, read before that wiring has run.
    private var canHandleToolCalls: Bool {
        nativeToolRouter != nil || (Config.isOpenClawAgentActive && openClawBridge != nil)
    }

    // MARK: - System Instruction

    /// Build the selected live model's system instruction, including vision capabilities,
    /// tool usage instructions, and the user's current location.
    ///
    /// - Parameter recoveredContext: Plan FF P1/PR5's locally rebuilt handover, when a reconnect
    ///   could not resume the conversation server-side. Composed with the other injected contexts,
    ///   after the preset prefix and the precedence note, so PR1's composition order is unchanged.
    private func buildSystemInstruction(recoveredContext: String? = nil) -> String {
        // Apply the LiveAI mode prefix (e.g. museum guide, Blind Assistant, translator) through
        // the shared seam, so this backend and the OpenAI Realtime one compose the preset in the
        // same order — prefix, then the configured prompt, then the blind-assistance precedence
        // note when that preset is the selected one (Plan FF P0).
        let mode = Config.activeLiveAIMode
        var prompt = BlindAssistanceContract.composeLiveInstruction(
            modePrefix: mode.promptPrefix,
            basePrompt: Config.systemPrompt(device: LLMService.deviceInUse()),   // Plan FY F3: read once per session
            modeID: mode.id)

        prompt += "\n\n" + SpeechPronunciation.liveVoiceInstruction

        let addressing = LiveAddressingInstruction.block(modeID: mode.id, canEndSession: canHandleToolCalls)
        if !addressing.isEmpty { prompt += "\n\n" + addressing }

        // Vision prompt depends on whether camera frames are actually flowing.
        // When streaming: full vision instructions.
        // When not streaming, explain camera availability and avoid inventing a view —
        // do NOT describe things you cannot see. This prevents hallucinated vision.
        if isCameraStreaming {
            prompt += """


            VISION:
            You are connected to the camera on the user's smart glasses. You can see through their \
            camera and have a voice conversation. You receive live video frames from the glasses camera approximately \
            once per second. When the user asks you to look at something or asks "what do you see?", analyze the \
            most recent video frames and describe what you observe. You have full visual awareness of the user's \
            environment through these camera frames.
            """
        } else {
            prompt += LiveCameraFailureInstruction.unavailable(reason: cameraFailureNotice?())
        }

        // Where the assistant's own settings live — the same block Direct Mode carries.
        prompt += "\n\n" + SystemPromptBuilder.appGuide(appName: RegistrationFlow.appName)

        // Add tool instructions
        let hasNativeTools = nativeToolRouter != nil
        let hasOpenClaw = Config.isOpenClawAgentActive   // BK P0: don't advertise the gateway with Agent Mode off
        if hasNativeTools || hasOpenClaw {
            var toolSection = """


            TOOLS:
            You have access to tools. Use the appropriate tool when the user's request matches its capability.
            """

            if let router = nativeToolRouter {
                // Plan GD3: the list the declarations beside it carry (the field-mode profile).
                let names = FieldToolProfile.current(router.registry.toolNames)
                toolSection += "\nBuilt-in tools: \(names.joined(separator: ", "))."
                // Plan BG P1: generated from each NativeTool's own `description` — the single source
                // shared with Direct Mode and the tool schemas, so the three can no longer drift.
                let descriptions = router.registry.toolDescriptions(for: names)
                if !descriptions.isEmpty {
                    toolSection += "\n\n" + SystemPromptBuilder.toolLines(descriptions)
                }
                // Plan BM P4: domains the model must route through a tool, never self-answer.
                let routingRules = SystemPromptBuilder.routingRules(
                    toolNames: names, hiddenTrades: FieldTradeGate.promptHiddenTrades)
                if !routingRules.isEmpty {
                    toolSection += "\n\nMANDATORY ROUTING:\n" + routingRules
                }

                // Inject user-defined custom tool descriptions
                let customTools = Config.customTools.filter { Config.isToolEnabled($0.name) }
                for ct in customTools {
                    toolSection += "\n            - \(ct.name): \(ct.description)"
                }

                // Inject the user's Siri Shortcuts so run_shortcut targets real names (Plan Z)
                if let shortcuts = ShortcutsCatalog.shared.promptBlock() {
                    toolSection += "\n\n            \(shortcuts.replacingOccurrences(of: "\n", with: "\n            "))"
                }
            }

            if hasOpenClaw {
                toolSection += """

            You also have an "execute" tool for the OpenClaw assistant gateway for actions \
            the built-in tools cannot handle.
            """
            }

            toolSection += """

            TOOL USAGE RULES:
            1. ALWAYS speak a brief verbal acknowledgment BEFORE calling any tool (e.g. "Let me check that", \
            "One moment", "Looking that up"). This prevents awkward silence while the tool runs.
            2. MULTI-STEP CHAINS: You can call multiple tools in sequence. After getting a result, \
            call another tool if needed. Example: lookup_contact → phone_call, or find_nearby → get_directions.
            3. Calendar proactive alerts automatically notify the user before events.
            4. If a tool takes a long time, you may hear "still working" updates — do not repeat them, just wait for the result.
            """

            prompt += toolSection
        }

        // Add location context if available
        if let location = locationContext?() {
            prompt += "\n\nUSER LOCATION: \(location)"
        }

        // Inject Field Assist vault content when a session is active.
        // Ground the live model in domain knowledge with source attribution.
        if let vaultContext = FieldSessionService.shared.promptContext() {
            prompt += "\n\n\(vaultContext)"
        }

        // Plan FO P3a — the bounded job block. The vault context above is assembled once, at
        // connect, and never again: a job started, numbered or re-scoped mid-session was invisible
        // to the model for the rest of that session. This block is small enough to re-inject, and
        // `LiveJobBridge` is what re-injects it.
        if let jobBlock = jobBridge.setupBlock() {
            prompt += "\n\n\(jobBlock)"
        }
        // Plan FO P3b — a debrief in progress, usually on a finished job, so not behind the job
        // block: which job it is about and what the model may not do during one.
        if let debriefBlock = jobBridge.setupDebriefBlock() {
            prompt += "\n\n\(debriefBlock)"
        }

        // Inject rolling visual scene memory (Plan AV) when enabled — temporal
        // awareness of what the user was just looking at. No-op when disabled.
        if let visualContext = VisualStateService.shared.promptContext() {
            prompt += "\n\n\(visualContext)"
        }

        // Inject the active project's knowledge-base grounding when it has documents (Plan AN).
        if let projectContext = ProjectContextService.shared.promptContext() {
            prompt += "\n\n\(projectContext)"
        }

        // Inject the pages read so far when a reading session is live (Plan BT). Without this,
        // Live mode had the reading_session tool but no corpus or spoiler rule — book questions
        // were answered from the model's world knowledge, the exact spoiler the feature exists to
        // prevent. The instruction is rebuilt on connect/reconnect (not per turn), so pages
        // captured mid-Live-session appear on the next reconnect; the spoiler rule itself is
        // present from the start, and stale-but-spoiler-safe beats absent.
        if let readingContext = ReadingCompanionService.shared.promptContext() {
            prompt += "\n\n\(readingContext)"
        }

        // Plan FF P1/PR5: the bounded handover that stands in for a conversation the server would
        // not resume. Last of the contexts, nearest the turn it is about.
        if let recoveredContext, !recoveredContext.isEmpty {
            prompt += "\n\n\(recoveredContext)"
        }

        // Security baseline: untrusted-content / prompt-injection policy (mirrors Direct Mode).
        prompt += PromptInjectionPolicy.systemPromptPolicy

        // Plan FC P3. Two facts about this instruction, recorded rather than assumed:
        // it carries **no** wearer-memory block — no call to the memory store exists on this path,
        // unlike Direct mode — and it is assembled here, once per connect/reconfigure, then reused
        // for every turn of the session. A live turn is therefore never fresh per-turn retrieval,
        // and a "Live mode doesn't remember me" report is answered by the first fact instead of
        // sending someone after a retrieval bug.
        MemoryContextRecorder.recordLive(
            .notInjected(at: Date(), freshness: .connectSnapshot(age: 0)), route: memoryRoute)

        return prompt
    }

    // MARK: - Frame Capture

    /// Periodically request frames from the camera and submit to the throttler.
    /// This is a fallback polling mechanism — the primary path is direct push via submitVideoFrame().
    private func startFrameCapture() {
        guard supportsVision else { return }
        frameTimer?.cancel()
        PrivacyLog.realtimeSession(logProvider, .framePollingStarted)
        let identity = sessionIdentity
        frameTimer = Task { [weak self] in
            guard let self else { return }
            var pollCount = 0
            while !Task.isCancelled && self.isActive && self.sessionIdentity == identity {
                if let image = await self.onRequestVideoFrame?() {
                    guard !Task.isCancelled, self.isActive, self.sessionIdentity == identity else { return }
                    pollCount += 1
                    if pollCount <= 3 || pollCount % 10 == 0 {
                        PrivacyLog.realtimeSession(logProvider, .framePolled, count: pollCount)
                    }
                    self.frameThrottler.submit(image)
                }
                // Sleep for half the frame interval so throttler can do its job
                let sleepMs = UInt64(Config.geminiLiveVideoFrameInterval * 500_000_000)
                try? await Task.sleep(nanoseconds: sleepMs)
            }
        }
    }
}

// MARK: - Live injection (Plan CB)

extension RealtimeSessionManager: LiveSessionInjecting {
    var canInject: Bool { isActive && connectionState == .ready }

    var liveSessionIdentity: Int { sessionIdentity }

    /// Gemini reports assistant activity; JSON adapters also expose input speech activity.
    var isBusyForInjection: Bool { (providerSession?.isModelSpeaking ?? false) || (providerSession?.isUserSpeaking ?? false) }

    func injectSharpImage(jpegData: Data) {
        guard supportsVision else { errorMessage = String(localized: "This realtime model does not support images."); return }
        providerSession?.sendHighResImage(jpegData: jpegData)
    }
    func validateSharpImage(_ jpegData: Data) throws {
        guard supportsVision else { throw RealtimeAdapterError.unsupportedOperation(String(localized: "images")) }
        let media = sessionModel?.profile?.mediaPolicy ?? .init()
        if media.imageRequiresAudio, providerSession?.hasSentAudio != true {
            throw RealtimeAdapterError.imageBeforeAudio
        }
        if let maximum = media.imageMaxBase64Bytes, (jpegData.count + 2) / 3 * 4 > maximum {
            throw RealtimeAdapterError.imageTooLarge
        }
    }

    func injectText(_ text: String, completeTurn: Bool) {
        if !completeTurn { updateAppContext(text, key: "background"); return }
        guard supportsTextInjection else { errorMessage = String(localized: "This realtime model does not support text injection."); return }
        providerSession?.sendText(text, completeTurn: completeTurn)
    }
    /// Plan HY P3 — an announcement: answered now, with tools off for that response.
    func injectAnnouncement(_ text: String) {
        guard supportsTextInjection else { errorMessage = String(localized: "This realtime model does not support text injection."); return }
        providerSession?.sendText(text, completeTurn: true, toolsAllowed: false)
    }
    func updateAppContext(_ text: String, key: String) {
        guard canInject, supportsContextUpdates else { return }
        providerSession?.updateContext(text, key: key)
    }
    func speakSuppliedText(_ text: String) {
        guard canInject, supportsSuppliedSpeech else { return }
        providerSession?.speakText(text)
    }
}

// MARK: - Conversation reset

/// Reset cycles the connection and clears local context plus any provider resumption handle.
extension RealtimeSessionManager: RealtimeSessionResetting {
    var isSessionActive: Bool { isActive }
    var holdsResumableContext: Bool { providerSession?.hasResumptionHandle ?? false }
    func stopLiveSession() { stopSession() }
    func startLiveSession() async { await startSession() }
}
