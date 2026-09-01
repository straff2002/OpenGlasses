import Foundation
import SwiftUI
import UIKit
import AVFoundation

/// Coordinator for OpenAI Realtime mode — mirrors GeminiLiveSessionManager's architecture.
/// AudioManager → OpenAIRealtimeService (audio), Service → AudioManager (playback),
/// CameraService → FrameThrottler → Service (vision).
@MainActor
class OpenAIRealtimeSessionManager: ObservableObject {
    @Published var isActive: Bool = false
    @Published var connectionState: OpenAIRealtimeConnectionState = .disconnected
    @Published var isModelSpeaking: Bool = false
    @Published var userTranscript: String = ""
    @Published var aiTranscript: String = ""
    @Published var reconnecting: Bool = false
    @Published var errorMessage: String?

    // Internal components
    private let realtimeService = OpenAIRealtimeService()
    private let audioManager = RealtimeAudioEngine(config: .openAIRealtime)
    private let frameThrottler = FrameThrottler(interval: 2.0)  // Less frequent than Gemini — OpenAI charges per image
    private var stateObservation: Task<Void, Never>?

    /// Plan CE: after an unpin the next live frame must reach the model as a keyframe — reset
    /// the throttler's dedup gate so it isn't dropped as "same scene" as the pinned frame.
    func resetFrameGateAfterPin() {
        frameThrottler.reset()
    }

    /// Local, network-independent speech for terminal session cues (Plan BD).
    private let localCueSynth = AVSpeechSynthesizer()

    private func speakLocalCue(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        localCueSynth.speak(utterance)
    }

    // Camera frame source — set by AppState
    var onRequestVideoFrame: (() async -> UIImage?)?

    // Location context — set by AppState
    var locationContext: (() -> String?)?

    // Camera streaming control
    var onRequestStartCamera: (() async -> Bool)?

    /// Whether the camera is actively streaming frames.
    var isCameraStreaming: Bool = false

    /// iPhone vs glasses audio mode.
    var useIPhoneAudioMode: Bool = true

    // Diagnostic counters
    private var submittedFrameCount = 0
    private var frameTimer: Task<Void, Never>?

    /// Submit a video frame (called from CameraService's continuous streaming callback).
    func submitVideoFrame(_ image: UIImage) {
        guard isActive, connectionState == .ready else { return }
        if !isCameraStreaming {
            isCameraStreaming = true
            PrivacyLog.realtimeSession(.openai, .firstCameraFrame)
        }
        submittedFrameCount += 1
        // Stretch the frame interval under battery/thermal pressure (Plan BV P2); same-actor read.
        frameThrottler.powerIntervalMultiplier = PowerPolicyService.shared.posture.frameIntervalMultiplier
        frameThrottler.submit(image)
    }

    // MARK: - Session Lifecycle

    func startSession() async {
        guard !isActive else { return }

        guard let config = Config.openAIRealtimeModelConfig else {
            errorMessage = "No OpenAI model configured. Add one in Settings."
            return
        }

        isActive = true
        errorMessage = nil

        // Try to start camera
        if let startCamera = onRequestStartCamera {
            let cameraOk = await startCamera()
            if cameraOk { isCameraStreaming = true }
            PrivacyLog.realtimeSession(.openai, .cameraStarted, success: cameraOk)
        }

        // Build system instruction
        let systemInstruction = buildSystemInstruction()

        // Configure service
        realtimeService.configure(
            apiKey: config.apiKey,
            model: config.model,
            systemInstruction: systemInstruction
        )

        // Wire audio capture → service. Echo suppression follows the reached duplex tier
        // (Plan CC): open mic when voice processing is alive, the old iPhone-mode mute otherwise.
        audioManager.onAudioCaptured = { [weak self] data in
            guard let self else { return }
            Task { @MainActor in
                if EchoSuppressionPolicy.shouldDropCapturedBuffer(
                    capability: self.audioManager.duplexCapability,
                    iPhoneMode: self.useIPhoneAudioMode,
                    modelSpeaking: self.realtimeService.isModelSpeaking) { return }
                self.realtimeService.sendAudio(data: data)
            }
        }

        // Wire client-side VAD interrupt
        audioManager.onVoiceInterrupt = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                PrivacyLog.realtimeSession(.openai, .userInterrupted)
                self.realtimeService.cancelResponse()
            }
        }

        // Wire service audio → playback
        realtimeService.onAudioReceived = { [weak self] data in
            self?.audioManager.playAudio(data: data)
        }

        // CJ item 6: barge-in truncation reports confirmed-played audio, never wall-clock.
        realtimeService.playedAudioMilliseconds = { [weak self] in
            self?.audioManager.confirmedPlayedMilliseconds ?? 0
        }

        // Wire interruption
        realtimeService.onInterrupted = { [weak self] in
            self?.audioManager.stopPlayback()
        }

        // CW P2: an audio-graph rebuild destroyed reply audio that was queued and never rendered.
        // Run the same truncate-on-loss barge-in uses: without it the server-side item keeps the
        // unheard tail, and later turns reference speech the wearer never got. Reaching for
        // `cancelResponse` rather than a bespoke path is deliberate — the loss is the same event
        // as an interrupt from the conversation's point of view, and it already reports the
        // confirmed-played point rather than wall-clock.
        audioManager.onPlaybackDiscarded = { [weak self] lostMilliseconds in
            guard lostMilliseconds > 0 else { return }
            Task { @MainActor in
                guard let self else { return }
                PrivacyLog.audio(.realtime, .playbackDiscarded,
                                 owner: PrivacyToken("openAIRealtime"),
                                 detail: PrivacyToken("graphRebuild"),
                                 milliseconds: lostMilliseconds)
                self.realtimeService.cancelResponse()
            }
        }

        // Wire turn complete
        realtimeService.onTurnComplete = { [weak self] in
            guard let self else { return }
            // Fresh played-audio window per response (CJ item 6) — the completed response's
            // tail may still be draining, but its frames must not count against the next one.
            self.audioManager.resetPlaybackProgress()
            Task { @MainActor in
                self.userTranscript = ""
            }
        }

        // Wire transcriptions
        realtimeService.onInputTranscription = { [weak self] text in
            guard let self else { return }
            Task { @MainActor in
                self.userTranscript = text  // OpenAI sends complete transcripts, not deltas
                self.aiTranscript = ""
            }
        }

        realtimeService.onOutputTranscription = { [weak self] text in
            guard let self else { return }
            Task { @MainActor in
                // Deltas here (unlike input) — join script-aware so CJK output doesn't render
                // with ASR word-gap spaces (Plan BY).
                self.aiTranscript = ScriptAwareJoiner.join(self.aiTranscript, text)
            }
        }

        // Wire disconnection
        realtimeService.onDisconnected = { [weak self] reason in
            guard let self else { return }
            Task { @MainActor in
                guard self.isActive else { return }
                if !self.realtimeService.reconnecting {
                    self.stopSession()
                    self.errorMessage = "Connection lost: \(reason ?? "Unknown error")"
                    self.speakLocalCue("Voice session disconnected.")   // Plan BD
                }
            }
        }

        // Reconnection exhausted → terminal. Audible cue + surfaced error (Plan BD).
        realtimeService.onReconnectExhausted = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                guard self.isActive else { return }
                self.stopSession()
                self.errorMessage = "Voice session lost — couldn't reconnect."
                self.speakLocalCue("Voice session lost. I couldn't reconnect.")
            }
        }

        // Wire reconnection
        realtimeService.onReconnected = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                PrivacyLog.realtimeSession(.openai, .reconnected)
                do {
                    try self.audioManager.startCapture()
                } catch {
                    PrivacyLog.realtimeSession(.openai, .audioRestartFailed,
                                               error: SafeErrorSummary(error))
                }
                self.startFrameCapture()
            }
        }

        // State observation — poll state every 100ms
        stateObservation = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard !Task.isCancelled else { break }
                // Assign only on change — an unconditional write fires objectWillChange at 10 Hz for
                // the whole session (Plan: perf bucket A).
                if self.connectionState != self.realtimeService.connectionState {
                    self.connectionState = self.realtimeService.connectionState
                }
                let speaking = self.realtimeService.isModelSpeaking
                if self.isModelSpeaking != speaking {
                    self.isModelSpeaking = speaking
                    self.audioManager.modelSpeaking = speaking
                }
                if self.reconnecting != self.realtimeService.reconnecting {
                    self.reconnecting = self.realtimeService.reconnecting
                }
            }
        }

        // Wire frame throttler — send images to OpenAI
        frameThrottler.reset()
        frameThrottler.onThrottledFrame = { [weak self] image in
            guard let self else { return }
            self.realtimeService.sendImage(image: image)
        }

        // Audio setup
        useIPhoneAudioMode = !isCameraStreaming
        PrivacyLog.realtimeSession(.openai, .audioModeSelected,
                                   detail: PrivacyToken(useIPhoneAudioMode ? "iPhone" : "glasses"))
        do {
            try await audioManager.setupAudioSession(useIPhoneMode: useIPhoneAudioMode)
        } catch {
            errorMessage = "Audio setup failed: \(error.localizedDescription)"
            isActive = false
            return
        }

        // Connect
        let setupOk = await realtimeService.connect()
        connectionState = realtimeService.connectionState

        if !setupOk {
            let msg: String
            if case .error(let err) = realtimeService.connectionState {
                msg = err
            } else {
                msg = "Failed to connect to OpenAI Realtime"
            }
            errorMessage = msg
            realtimeService.disconnect()
            stateObservation?.cancel()
            stateObservation = nil
            isActive = false
            connectionState = .disconnected
            return
        }

        // Start mic
        do {
            try audioManager.startCapture()
        } catch {
            errorMessage = "Mic capture failed: \(error.localizedDescription)"
            realtimeService.disconnect()
            stateObservation?.cancel()
            stateObservation = nil
            isActive = false
            connectionState = .disconnected
            return
        }

        // Late camera retry
        if !isCameraStreaming, let startCamera = onRequestStartCamera {
            let cameraOk = await startCamera()
            if cameraOk {
                isCameraStreaming = true
                if !useIPhoneAudioMode {
                    PrivacyLog.realtimeSession(.openai, .audioModeUnchanged,
                                               detail: PrivacyToken("glasses"))
                } else {
                    useIPhoneAudioMode = false
                    do { try await audioManager.setupAudioSession(useIPhoneMode: false) }
                    catch {
                        PrivacyLog.realtimeSession(.openai, .audioModeSwitchFailed,
                                                   error: SafeErrorSummary(error))
                    }
                }
            }
        }

        startFrameCapture()
    }

    func stopSession() {
        PrivacyLog.realtimeSession(.openai, .sessionStopped, count: submittedFrameCount)
        frameTimer?.cancel()
        frameTimer = nil
        audioManager.stopCapture()
        realtimeService.disconnect()
        stateObservation?.cancel()
        stateObservation = nil
        isActive = false
        isCameraStreaming = false
        connectionState = .disconnected
        isModelSpeaking = false
        userTranscript = ""
        aiTranscript = ""
        errorMessage = nil
        submittedFrameCount = 0
    }

    // MARK: - System Instruction

    private func buildSystemInstruction() -> String {
        var prompt = Config.systemPrompt

        if isCameraStreaming {
            prompt += """


            VISION:
            You are connected to the camera on the user's Ray-Ban Meta smart glasses. You receive periodic \
            camera frames as images in the conversation. When the user asks you to look at something or asks \
            "what do you see?", analyze the most recent image and describe what you observe. You have visual \
            awareness of the user's environment through these camera frames.
            """
        } else {
            prompt += """


            VISION:
            You are running on the user's Ray-Ban Meta smart glasses. The camera is still connecting and you \
            have NOT received any images yet. If the user asks you to look at something, tell them the camera \
            is still connecting. Do NOT guess what the user might be looking at.
            """
        }

        if let location = locationContext?() {
            prompt += "\n\nUSER LOCATION: \(location)"
        }

        return prompt
    }

    // MARK: - Frame Capture

    private func startFrameCapture() {
        frameTimer?.cancel()
        frameTimer = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled && self.isActive {
                if let image = await self.onRequestVideoFrame?() {
                    self.frameThrottler.submit(image)
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s polling
            }
        }
    }
}

// MARK: - Live injection (Plan CB)

extension OpenAIRealtimeSessionManager: LiveSessionInjecting {
    var canInject: Bool { isActive && connectionState == .ready }

    func injectSharpImage(jpegData: Data) {
        realtimeService.sendHighResImage(jpegData: jpegData)
    }

    func injectText(_ text: String, completeTurn: Bool) {
        realtimeService.sendText(text, completeTurn: completeTurn)
    }
}
