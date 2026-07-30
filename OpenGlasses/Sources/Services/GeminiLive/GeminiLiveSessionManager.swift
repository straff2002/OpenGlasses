import Foundation
import SwiftUI
import UIKit
import AVFoundation

/// Coordinator that ties all Gemini Live components together:
/// AudioManager → GeminiLiveService (audio), GeminiLiveService → AudioManager (playback),
/// GeminiLiveService → ToolCallRouter → OpenClawBridge (tool calls),
/// CameraService → FrameThrottler → GeminiLiveService (video).
@MainActor
class GeminiLiveSessionManager: ObservableObject {
    @Published var isActive: Bool = false
    @Published var connectionState: GeminiConnectionState = .disconnected
    @Published var isModelSpeaking: Bool = false
    @Published var userTranscript: String = ""
    @Published var aiTranscript: String = ""
    @Published var toolCallStatus: ToolCallStatus = .idle
    @Published var openClawConnectionState: OpenClawConnectionState = .notConfigured
    @Published var reconnecting: Bool = false
    @Published var errorMessage: String?

    // Shared OpenClaw bridge (injected from AppState)
    var openClawBridge: OpenClawBridge?

    // Native tool router (injected from AppState)
    var nativeToolRouter: NativeToolRouter?

    // Internal components
    private let geminiService = GeminiLiveService()
    private let audioManager = RealtimeAudioEngine(config: .geminiLive)
    private let frameThrottler = FrameThrottler()
    private var toolCallRouter: ToolCallRouter?
    private var stateObservation: Task<Void, Never>?

    /// Local, network-independent speech for terminal session cues (Plan BD) — never ElevenLabs,
    /// since the network may be exactly what failed.
    private let localCueSynth = AVSpeechSynthesizer()

    private func speakLocalCue(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        localCueSynth.speak(utterance)
    }

    // Camera frame source — set by AppState to the existing CameraService's periodic captures
    var onRequestVideoFrame: (() async -> UIImage?)?

    // Location context — set by AppState from LocationService
    var locationContext: (() -> String?)?

    // Camera streaming control — set by AppState to start/check camera streaming
    var onRequestStartCamera: (() async -> Bool)?

    /// Whether the camera is actively streaming frames (used to conditionalise the vision prompt).
    var isCameraStreaming: Bool = false

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
        guard !Config.audioOnlyMode else { return }
        guard isActive else {
            droppedNotActive += 1
            if droppedNotActive <= 3 {
                NSLog("[Session] submitVideoFrame dropped — not active (count: %d)", droppedNotActive)
            }
            return
        }
        if !isCameraStreaming {
            isCameraStreaming = true
            NSLog("[Session] First camera frame received — camera streaming confirmed active")
        }
        guard connectionState == .ready else {
            droppedNotReady += 1
            if droppedNotReady <= 5 || droppedNotReady % 30 == 0 {
                NSLog("[Session] submitVideoFrame dropped — state: %@ (count: %d)",
                      String(describing: connectionState), droppedNotReady)
            }
            return
        }
        submittedFrameCount += 1
        if submittedFrameCount <= 3 || submittedFrameCount % 30 == 0 {
            NSLog("[Session] submitVideoFrame #%d forwarded to throttler (%dx%d)",
                  submittedFrameCount, Int(image.size.width), Int(image.size.height))
        }
        // Stretch the frame interval under battery/thermal pressure (Plan BV P2). Same-actor read,
        // refreshed per submitted frame so a posture change takes effect immediately.
        frameThrottler.powerIntervalMultiplier = PowerPolicyService.shared.posture.frameIntervalMultiplier
        frameThrottler.submit(image)
    }

    // Timer for periodic frame capture
    private var frameTimer: Task<Void, Never>?

    // MARK: - Session Lifecycle

    func startSession() async {
        guard !isActive else { return }

        guard Config.isGeminiLiveConfigured else {
            errorMessage = "Gemini API key not configured. Add it in Settings."
            return
        }

        isActive = true
        errorMessage = nil

        // Ensure camera streaming is active (may have failed on mode switch if glasses weren't connected).
        // If startCamera succeeds, trust that frames will arrive — the user has approved camera permission
        // through the Meta companion app dialog, so we should build the vision prompt immediately rather
        // than waiting for the first frame (which may take seconds after permission approval).
        if let startCamera = onRequestStartCamera {
            let cameraOk = await startCamera()
            NSLog("[Session] Camera streaming start result: %@", cameraOk ? "success" : "failed (will work audio-only)")
            if cameraOk {
                isCameraStreaming = true
            }
        }
        NSLog("[Session] Building system instruction — isCameraStreaming: %@", isCameraStreaming ? "YES" : "NO")

        // Configure Gemini with system instruction, vision context, location, and tools.
        // Only declare OpenClaw tools if the gateway is actually connected (prevents Gemini
        // from attempting tool calls that will fail when gateway is unreachable).
        let systemInstruction = buildSystemInstruction()
        NSLog("[Session] System instruction built — length: %d chars, camera streaming: %@",
              systemInstruction.count, isCameraStreaming ? "YES" : "NO")
        let openClawConnected = openClawBridge?.connectionState == .connected
        // BK P0: expose the gateway `execute` tool only when it's an active agentic capability
        // (configured AND Agent Mode on) — Gemini Live had the same isOpenClawConfigured-only gap
        // as Direct mode, handing the model an execute schema + full-machine-access prompt.
        let includeOpenClaw = Config.isOpenClawAgentActive && openClawConnected
        if Config.isOpenClawAgentActive && !openClawConnected {
            NSLog("[Session] OpenClaw configured but not connected — omitting execute tool declaration")
        }
        let toolDefs = ToolDeclarations.allDeclarations(registry: nativeToolRouter?.registry, includeOpenClaw: includeOpenClaw)
        geminiService.configure(systemInstruction: systemInstruction, toolDeclarations: toolDefs)

        // Wire audio capture → Gemini
        // Echo suppression is a policy of the reached duplex tier (Plan CC), not a blanket mute:
        // with voice processing alive the mic stays open while the model speaks (real barge-in via
        // server VAD); on the half-duplex fallback this is the old mute — drop iPhone-mode buffers
        // during model speech so the co-located loudspeaker can't feed the model its own voice.
        audioManager.onAudioCaptured = { [weak self] data in
            guard let self else { return }
            Task { @MainActor in
                if EchoSuppressionPolicy.shouldDropCapturedBuffer(
                    capability: self.audioManager.duplexCapability,
                    iPhoneMode: self.useIPhoneAudioMode,
                    modelSpeaking: self.geminiService.isModelSpeaking) { return }
                self.geminiService.sendAudio(data: data)
            }
        }

        // Wire Gemini audio → playback
        geminiService.onAudioReceived = { [weak self] data in
            self?.audioManager.playAudio(data: data)
        }

        // Wire interruption → stop playback
        geminiService.onInterrupted = { [weak self] in
            self?.audioManager.stopPlayback()
        }

        // Wire turn complete
        geminiService.onTurnComplete = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.userTranscript = ""
            }
        }

        // Wire transcriptions
        geminiService.onInputTranscription = { [weak self] text in
            guard let self else { return }
            Task { @MainActor in
                self.userTranscript += text
                self.aiTranscript = ""
                // BR P1: a user turn resets the runaway-tool-call window.
                self.toolCallRouter?.noteUserTurn()
            }
        }

        geminiService.onOutputTranscription = { [weak self] text in
            guard let self else { return }
            Task { @MainActor in
                self.aiTranscript += text
            }
        }

        // Wire disconnection
        geminiService.onDisconnected = { [weak self] reason in
            guard let self else { return }
            Task { @MainActor in
                guard self.isActive else { return }
                if !self.geminiService.reconnecting {
                    self.stopSession()
                    self.errorMessage = "Connection lost: \(reason ?? "Unknown error")"
                    // Voice-first: the phone may be pocketed, so a visual banner isn't enough (Plan BD).
                    self.speakLocalCue("Voice session disconnected.")
                }
            }
        }

        // Reconnection exhausted → terminal. Speak an audible cue and surface the error.
        geminiService.onReconnectExhausted = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                guard self.isActive else { return }
                self.stopSession()
                self.errorMessage = "Voice session lost — couldn't reconnect."
                self.speakLocalCue("Voice session lost. I couldn't reconnect.")
            }
        }

        // Wire reconnection
        geminiService.onReconnected = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                NSLog("[Session] Reconnected — re-configuring session")
                // Re-configure with current settings (including fresh location)
                let includeOpenClaw = Config.isOpenClawAgentActive   // BK P0: gate on Agent Mode too
                var toolDefs = ToolDeclarations.allDeclarations(registry: self.nativeToolRouter?.registry, includeOpenClaw: includeOpenClaw)
                // BR P1: breaker-suspended tools stay out of the re-declared list — the new
                // setup message must not re-offer what this session already tripped on.
                if let suspended = self.toolCallRouter?.suspendedToolNames, !suspended.isEmpty {
                    toolDefs = toolDefs.filter { decl in
                        guard let name = decl["name"] as? String else { return true }
                        return !suspended.contains(name)
                    }
                }
                self.geminiService.configure(
                    systemInstruction: self.buildSystemInstruction(),
                    toolDeclarations: toolDefs
                )
                // Re-start audio capture
                do {
                    try self.audioManager.startCapture()
                } catch {
                    NSLog("[Session] Failed to restart audio after reconnect: %@", error.localizedDescription)
                }
                // Re-start frame capture
                self.startFrameCapture()
            }
        }

        // Wire tool calls — native tools always available, OpenClaw only as an active agentic
        // capability (BK P0: configured AND Agent Mode on).
        let hasNativeTools = nativeToolRouter != nil
        let hasOpenClaw = Config.isOpenClawAgentActive && openClawBridge != nil

        if hasNativeTools || hasOpenClaw {
            if let bridge = openClawBridge, hasOpenClaw {
                await bridge.checkConnection()
                // BR P4: no resetSession() here — the gateway session key is stable now, so
                // the OpenClaw-side agent keeps context across Live sessions. Reset is a
                // deliberate user action, not a side effect of starting a session.
            }

            let bridge = openClawBridge ?? OpenClawBridge()
            toolCallRouter = ToolCallRouter(bridge: bridge)
            toolCallRouter?.nativeToolRouter = nativeToolRouter

            // Pause/resume camera streaming during tool execution to prevent instability
            // (VisionClaw issue #11: tool-call stability during Gemini Live)
            toolCallRouter?.onToolExecutionStarted = { [weak self] in
                guard let self else { return }
                NSLog("[Session] Tool execution started — pausing frame submission")
                self.frameThrottler.pause()
            }
            toolCallRouter?.onToolExecutionFinished = { [weak self] in
                guard let self else { return }
                NSLog("[Session] Tool execution finished — resuming frame submission")
                self.frameThrottler.resume()
            }

            geminiService.onToolCall = { [weak self] toolCall in
                guard let self else { return }
                Task { @MainActor in
                    for call in toolCall.functionCalls {
                        // `self` is already strongly held by the enclosing handler (guard let self
                        // above) for the duration of this response, so a redundant inner [weak self]
                        // only tripped the ownership-mismatch warning.
                        self.toolCallRouter?.handleToolCall(call) { response in
                            self.geminiService.sendToolResponse(response)
                        }
                    }
                }
            }

            geminiService.onToolCallCancellation = { [weak self] cancellation in
                guard let self else { return }
                Task { @MainActor in
                    self.toolCallRouter?.cancelToolCalls(ids: cancellation.ids)
                }
            }
        }

        // State observation — poll Gemini + OpenClaw state every 100ms
        stateObservation = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard !Task.isCancelled else { break }
                // Assign only on change — an unconditional write fires objectWillChange at 10 Hz for
                // the whole session, re-evaluating every observing SwiftUI view (Plan: perf bucket A).
                if self.connectionState != self.geminiService.connectionState {
                    self.connectionState = self.geminiService.connectionState
                }
                if self.isModelSpeaking != self.geminiService.isModelSpeaking {
                    self.isModelSpeaking = self.geminiService.isModelSpeaking
                }
                if self.reconnecting != self.geminiService.reconnecting {
                    self.reconnecting = self.geminiService.reconnecting
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

        // Wire frame throttler to Gemini
        frameThrottler.reset()
        VisualStateService.shared.reset()
        frameThrottler.onThrottledFrame = { [weak self] image in
            guard let self else { return }
            self.geminiService.sendVideoFrame(image: image)
        }
        // Feed genuine scene-change keyframes to Visual State Memory (Plan AV).
        // No-op unless visualStateMemoryEnabled; fires only when the content gate is active.
        frameThrottler.onKeyframe = { image in
            VisualStateService.shared.considerKeyframe(image)
        }

        // Audio setup — use iPhone mode when camera NOT streaming (no glasses connected),
        // use glasses/videoChat mode when camera IS streaming (mic is on remote device)
        useIPhoneAudioMode = !isCameraStreaming
        NSLog("[Session] Audio mode: %@", useIPhoneAudioMode ? "iPhone (voiceChat)" : "Glasses (videoChat)")
        do {
            try await audioManager.setupAudioSession(useIPhoneMode: useIPhoneAudioMode)
        } catch {
            errorMessage = "Audio setup failed: \(error.localizedDescription)"
            isActive = false
            return
        }

        // Connect to Gemini
        let setupOk = await geminiService.connect()

        // Immediately sync connection state so submitVideoFrame doesn't block
        // waiting for the next 100ms poll cycle
        connectionState = geminiService.connectionState
        NSLog("[Session] Post-connect state: %@, videoFramesSent: %d",
              String(describing: connectionState), geminiService.videoFramesSent)

        if !setupOk {
            let msg: String
            if case .error(let err) = geminiService.connectionState {
                msg = err
            } else {
                msg = "Failed to connect to Gemini"
            }
            errorMessage = msg
            geminiService.disconnect()
            stateObservation?.cancel()
            stateObservation = nil
            isActive = false
            connectionState = .disconnected
            return
        }

        // Start mic capture
        do {
            try audioManager.startCapture()
        } catch {
            errorMessage = "Mic capture failed: \(error.localizedDescription)"
            geminiService.disconnect()
            stateObservation?.cancel()
            stateObservation = nil
            isActive = false
            connectionState = .disconnected
            return
        }

        // Late camera retry: if camera failed initially (SDK wasn't ready),
        // try again now that Gemini is connected (SDK has had more time to register).
        // VisionClaw avoids this by starting camera separately before Gemini.
        if !isCameraStreaming, let startCamera = onRequestStartCamera {
            NSLog("[Session] Camera was not streaming — retrying after Gemini connect...")
            let cameraOk = await startCamera()
            if cameraOk {
                isCameraStreaming = true
                NSLog("[Session] Late camera start succeeded! Reconfiguring for vision...")
                // Reconfigure Gemini with the vision prompt now that camera works
                let updatedInstruction = buildSystemInstruction()
                let visionNow = updatedInstruction.contains("You CAN see")
                NSLog("[Session] Reconfigured — vision enabled: %@", visionNow ? "YES" : "NO")
                // Switch to glasses audio mode since camera implies glasses are connected
                if !useIPhoneAudioMode {
                    NSLog("[Session] Already in glasses audio mode")
                } else {
                    useIPhoneAudioMode = false
                    NSLog("[Session] Switching to glasses audio mode (videoChat)")
                    do {
                        try await audioManager.setupAudioSession(useIPhoneMode: false)
                    } catch {
                        NSLog("[Session] Audio mode switch failed: %@", error.localizedDescription)
                    }
                }
            } else {
                NSLog("[Session] Late camera retry also failed — continuing audio-only")
            }
        }

        // Start periodic camera frame capture
        startFrameCapture()
    }

    func stopSession() {
        NSLog("[Session] stopSession — submitted: %d, droppedNotActive: %d, droppedNotReady: %d",
              submittedFrameCount, droppedNotActive, droppedNotReady)
        toolCallRouter?.cancelAll()
        toolCallRouter = nil
        frameTimer?.cancel()
        frameTimer = nil
        audioManager.stopCapture()
        geminiService.disconnect()
        stateObservation?.cancel()
        stateObservation = nil
        isActive = false
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
    }

    // MARK: - System Instruction

    /// Build the full system instruction for Gemini Live, including vision capabilities,
    /// tool usage instructions, and the user's current location.
    private func buildSystemInstruction() -> String {
        // Apply LiveAI mode prefix (e.g., museum guide, accessibility, translator)
        let modePrefix = Config.activeLiveAIMode.promptPrefix
        var prompt = modePrefix + Config.systemPrompt

        // Vision prompt depends on whether camera frames are actually flowing.
        // When streaming: full vision instructions.
        // When not streaming: tell Gemini camera is connecting, and critically —
        // do NOT describe things you cannot see. This prevents hallucinated vision.
        if isCameraStreaming {
            prompt += """


            VISION:
            You are connected to the camera on the user's Ray-Ban Meta smart glasses. You can see through their \
            camera and have a voice conversation. You receive live video frames from the glasses camera approximately \
            once per second. When the user asks you to look at something or asks "what do you see?", analyze the \
            most recent video frames and describe what you observe. You have full visual awareness of the user's \
            environment through these camera frames.
            """
        } else {
            prompt += """


            VISION:
            You are running on the user's Ray-Ban Meta smart glasses. The camera is still connecting and you have \
            NOT received any video frames yet. If the user asks you to look at something or describe what you see, \
            tell them the camera is still connecting and to try again in a moment. Do NOT describe or guess what \
            the user might be looking at — only describe things from actual video frames you have received.
            """
        }

        // Add tool instructions
        let hasNativeTools = nativeToolRouter != nil
        let hasOpenClaw = Config.isOpenClawAgentActive   // BK P0: don't advertise the gateway with Agent Mode off
        if hasNativeTools || hasOpenClaw {
            var toolSection = """


            TOOLS:
            You have access to tools. Use the appropriate tool when the user's request matches its capability.
            """

            if let router = nativeToolRouter {
                let names = router.registry.toolNames
                toolSection += "\nBuilt-in tools: \(names.joined(separator: ", "))."
                // Plan BG P1: generated from each NativeTool's own `description` — the single source
                // shared with Direct Mode and the tool schemas, so the three can no longer drift.
                let descriptions = router.registry.toolDescriptions(for: names)
                if !descriptions.isEmpty {
                    toolSection += "\n\n" + SystemPromptBuilder.toolLines(descriptions)
                }
                // Plan BM P4: domains the model must route through a tool, never self-answer.
                let routingRules = SystemPromptBuilder.routingRules(toolNames: names)
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
        // Grounds Gemini in domain knowledge (refrigeration, IT, health) with source attribution.
        if let vaultContext = FieldSessionService.shared.promptContext() {
            prompt += "\n\n\(vaultContext)"
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

        // Security baseline: untrusted-content / prompt-injection policy (mirrors Direct Mode).
        prompt += PromptInjectionPolicy.systemPromptPolicy

        return prompt
    }

    // MARK: - Frame Capture

    /// Periodically request frames from the camera and submit to the throttler.
    /// This is a fallback polling mechanism — the primary path is direct push via submitVideoFrame().
    private func startFrameCapture() {
        frameTimer?.cancel()
        NSLog("[Session] Starting frame capture polling (fallback for direct push)")
        frameTimer = Task { [weak self] in
            guard let self else { return }
            var pollCount = 0
            while !Task.isCancelled && self.isActive {
                if let image = await self.onRequestVideoFrame?() {
                    pollCount += 1
                    if pollCount <= 3 || pollCount % 10 == 0 {
                        NSLog("[Session] Polled frame #%d from camera", pollCount)
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

extension GeminiLiveSessionManager: LiveSessionInjecting {
    var canInject: Bool { isActive && connectionState == .ready }

    func injectSharpImage(jpegData: Data) {
        geminiService.sendHighResImage(jpegData: jpegData)
    }

    func injectText(_ text: String, completeTurn: Bool) {
        geminiService.sendText(text, completeTurn: completeTurn)
    }
}
