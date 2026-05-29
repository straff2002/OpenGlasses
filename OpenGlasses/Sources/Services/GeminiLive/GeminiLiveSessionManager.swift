import Foundation
import SwiftUI
import UIKit

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
    private let audioManager = GeminiLiveAudioManager()
    private let frameThrottler = FrameThrottler()
    private var toolCallRouter: ToolCallRouter?
    private var stateObservation: Task<Void, Never>?

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
        let includeOpenClaw = Config.isOpenClawConfigured && openClawConnected
        if Config.isOpenClawConfigured && !openClawConnected {
            NSLog("[Session] OpenClaw configured but not connected — omitting execute tool declaration")
        }
        let toolDefs = ToolDeclarations.allDeclarations(registry: nativeToolRouter?.registry, includeOpenClaw: includeOpenClaw)
        geminiService.configure(systemInstruction: systemInstruction, toolDeclarations: toolDefs)

        // Wire audio capture → Gemini
        // In iPhone mode, mute mic while the model is speaking to prevent echo feedback.
        // The co-located loudspeaker + mic overwhelms iOS echo cancellation, causing
        // the model to hear itself and interrupt or produce garbled output.
        audioManager.onAudioCaptured = { [weak self] data in
            guard let self else { return }
            Task { @MainActor in
                // Echo suppression: skip sending mic audio while model speaks on iPhone speaker
                if self.useIPhoneAudioMode && self.geminiService.isModelSpeaking { return }
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
                }
            }
        }

        // Wire reconnection
        geminiService.onReconnected = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                NSLog("[Session] Reconnected — re-configuring session")
                // Re-configure with current settings (including fresh location)
                let includeOpenClaw = Config.isOpenClawConfigured
                let toolDefs = ToolDeclarations.allDeclarations(registry: self.nativeToolRouter?.registry, includeOpenClaw: includeOpenClaw)
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

        // Wire tool calls — native tools always available, OpenClaw if configured
        let hasNativeTools = nativeToolRouter != nil
        let hasOpenClaw = Config.isOpenClawConfigured && openClawBridge != nil

        if hasNativeTools || hasOpenClaw {
            if let bridge = openClawBridge, hasOpenClaw {
                await bridge.checkConnection()
                bridge.resetSession()
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
                        self.toolCallRouter?.handleToolCall(call) { [weak self] response in
                            self?.geminiService.sendToolResponse(response)
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
                self.connectionState = self.geminiService.connectionState
                self.isModelSpeaking = self.geminiService.isModelSpeaking
                self.reconnecting = self.geminiService.reconnecting
                if let bridge = self.openClawBridge {
                    self.toolCallStatus = bridge.lastToolCallStatus
                    self.openClawConnectionState = bridge.connectionState
                }
            }
        }

        // Wire frame throttler to Gemini
        frameThrottler.reset()
        frameThrottler.onThrottledFrame = { [weak self] image in
            guard let self else { return }
            self.geminiService.sendVideoFrame(image: image)
        }

        // Audio setup — use iPhone mode when camera NOT streaming (no glasses connected),
        // use glasses/videoChat mode when camera IS streaming (mic is on remote device)
        useIPhoneAudioMode = !isCameraStreaming
        NSLog("[Session] Audio mode: %@", useIPhoneAudioMode ? "iPhone (voiceChat)" : "Glasses (videoChat)")
        do {
            try audioManager.setupAudioSession(useIPhoneMode: useIPhoneAudioMode)
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
                        try audioManager.setupAudioSession(useIPhoneMode: false)
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
        let hasOpenClaw = Config.isOpenClawConfigured
        if hasNativeTools || hasOpenClaw {
            var toolSection = """


            TOOLS:
            You have access to tools. Use the appropriate tool when the user's request matches its capability.
            """

            if let router = nativeToolRouter {
                let names = router.registry.toolNames
                toolSection += "\nBuilt-in tools: \(names.joined(separator: ", "))."
                toolSection += """

            - get_weather: Get current weather and forecast.
            - get_datetime: Get current date, time, day of week.
            - daily_briefing: Combined daily briefing (date, weather, news).
            - calculate: Evaluate math expressions.
            - convert_units: Convert between units.
            - set_timer: Set a countdown timer.
            - pomodoro: Start/stop/check Pomodoro focus sessions.
            - save_note / list_notes: Save and retrieve notes.
            - web_search: Search the web.
            - get_news: Get latest news headlines.
            - translate: Translate text between languages.
            - translate_sign_menu: Translate visible signs/menus from camera view.
            - ask_local_phrase: Generate traveler phrases in local language with pronunciation.
            - define_word: Look up word definitions.
            - find_nearby: Search for nearby places.
            - where_am_i: Describe current location with reverse-geocoded place context and GPS coordinates.
            - open_app: Open iOS apps (Music, Podcasts, Maps, Google Maps, etc).
            - get_directions: Directions via Apple Maps or Google Maps.
            - identify_song: Identify a song using Shazam.
            - music_control: Play, pause, skip, previous, now-playing info.
            - convert_currency: Convert currencies with live rates.
            - phone_call: Make a phone call.
            - send_message: Open Messages with pre-filled text.
            - copy_to_clipboard: Copy text to clipboard.
            - flashlight: Toggle flashlight on/off.
            - device_info: Check battery, storage, low power mode.
            - save_location / list_saved_locations: Bookmark current spot, find saved spots with distance.
            - step_count: Today's steps, distance, floors climbed.
            - emergency_info: Local emergency numbers, GPS coordinates, nearest hospital guidance.
            - calendar: View schedule, next meeting, create events with reminders.
            - lookup_contact: Find contact phone/email by name.
            - reminder: Create/list/complete Apple Reminders with notifications.
            - set_alarm: Set alarm for specific clock time, list/cancel alarms.
            - brightness: Adjust screen brightness.
            - smart_home: Control HomeKit devices — lights, switches, thermostats, locks, scenes.
            - run_shortcut: Run Apple Shortcuts by name.
            - summarize_conversation: Summarize current conversation or extract action items.
            - face_recognition: Remember/forget/list known faces. Auto-recognizes people when camera is active.
            - memory_rewind: Recall what was said recently — transcribes last few minutes of audio.
            - geofence: Create location-based reminders that trigger when entering/leaving a place.
            - send_via: Send messages via WhatsApp, Telegram, or Email (not iMessage).
            - meeting_summary: Summarize a recent meeting from ambient captions with action items.
            - fitness_coach: Fitness coaching — start/stop workouts, log exercises, check form via camera, workout history from HealthKit.
            - openclaw_skills: Discover and manage OpenClaw skills. List available skills, check gateway status.
            - field_session: Start/pause/resume/end/query a Field Assist session for grounded domain-specific technical support (refrigeration, etc.). Loads a knowledge vault and emits an audit log. Actions: start, pause, resume, end, status, list, escalate, export (work-order PDF + audit JSON).
            - procedure_runner: Run a guided step-by-step procedure inside an active Field Assist session. Actions: list, start, next, previous, repeat, status, complete. Pass 'choice' to 'next' when the active step (shown under ACTIVE PROCEDURE in this prompt) offers branch choices.
            - domain_calc: Refrigeration math grounded in vault PT charts — pt_lookup, superheat, subcool. Temps °F, pressures PSIG. Params: operation, refrigerant, and the relevant pressures/temps.
            - equipment_lookup: Look up an error code/fault/model in the active session's vault — read aloud (query) or via on-device camera OCR (omit query or set use_camera). Returns the matching reference section with its source.
            - reading_assist: Read text in front of the user via the glasses camera (on-device OCR). Modes: read, simplify (level 1-5), translate (target_language), define. Use for 'read this', 'simplify this', 'translate this sign', 'what does this word mean'.
            - health_vault: Query/update the user's Personal Health Vault (biometrics, conditions, diet, labs, medications, wearables). 'query' grounds a health question in their own notes (cite the file); 'log' records a new entry. Never fabricate health data.
            - notes_vault: The user's personal notes / second brain. 'log' to remember ("note that…"), 'query' to recall. Files: general, people, ideas, todos. Answers only from recorded notes.
            - identify_medication: Read a medication label via camera OCR and cross-check the user's recorded medications. Reports label text + match status; no clinical claims. Needs Medical Compliance.
            - aircraft_overhead: Report aircraft flying near the user using live ADS-B data + their location. Use for "what's flying overhead?". Param: radius_miles (default 25).
            - live_coach: Real-time one-sentence coaching from the glasses camera. Actions: start (domain: sports_tactics/cooking_form/posture/guitar/climbing/custom), stop, status. Use for "coach my form", "watch my technique".
            - network_calc: IP subnet/CIDR math (IPv4/IPv6) — operation 'subnet' with a 'cidr' returns network, broadcast, netmask, usable range/count.
            - navigation_assist: Spoken walking guidance for low-vision users (hazards/landmarks, clock positions). Actions: start, stop, status. An aid, not a cane/guide-dog replacement.
            - identify_color: Name the dominant color of what the user sees (on-device). Use for "what color is this?".
            - identify_money: Identify a banknote's currency and denomination from the camera, for low-vision support. Use for "how much is this note?".
            - photo_log: Capture a glasses-camera photo, attach it to the session audit log with a caption, and return it for analysis. Use to document gauge readings and evidence.
            - escalate_to_expert: Escalate the active session to a human expert when you can't safely resolve it or the technician asks for a person. Actions: request (reason), status, resolve, cancel. Live video is Phase 5 — for now it's logged and the expert pool is notified.
            """

                // Inject user-defined custom tool descriptions
                let customTools = Config.customTools.filter { Config.isToolEnabled($0.name) }
                for ct in customTools {
                    toolSection += "\n            - \(ct.name): \(ct.description)"
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
