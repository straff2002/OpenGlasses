import SwiftUI
import Combine
import MWDATCore
import AVFoundation
import AppIntents
import UIKit

private func processWearablesCallbackURL(_ url: URL, source: String) {
    NSLog("[OpenGlasses] [\(source)] Received URL callback: \(url.absoluteString)")
    Task { @MainActor in
        AppStateProvider.shared?.recordCallback(url: url, source: source)
    }
    Task {
        do {
            let result = try await Wearables.shared.handleUrl(url)
            NSLog("[OpenGlasses] [\(source)] handleUrl result: \(String(describing: result))")
            Task { @MainActor in
                AppStateProvider.shared?.addDebugEvent("handleUrl success from \(source): \(String(describing: result))")
            }
        } catch {
            NSLog("[OpenGlasses] [\(source)] handleUrl failed: \(error.localizedDescription)")
            Task { @MainActor in
                AppStateProvider.shared?.addDebugEvent("handleUrl failed from \(source): \(error.localizedDescription)")
            }
        }
    }
}

final class OpenGlassesAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if !options.urlContexts.isEmpty {
            for context in options.urlContexts {
                processWearablesCallbackURL(context.url, source: "SceneConnect")
            }
        }
        if let userActivity = options.userActivities.first,
           let url = userActivity.webpageURL {
            processWearablesCallbackURL(url, source: "SceneConnectUserActivity")
        }

        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = OpenGlassesSceneDelegate.self
        return configuration
    }

    func application(_ application: UIApplication,
                     continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
        if let url = userActivity.webpageURL {
            processWearablesCallbackURL(url, source: "UserActivity")
            return true
        }
        return false
    }

    /// Handle background URLSession events (model downloads completing while app is suspended).
    /// The Hub library uses a background URLSession with identifier "{bundleId}.hub.hubclient.background".
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        print("📥 Background URLSession event for: \(identifier)")
        // The Hub library's background session delegate handles the actual download completion.
        // We just need to store the completion handler so the system knows we processed the event.
        BackgroundSessionCompletionStore.shared.completionHandler = completionHandler
    }
}

/// Stores the background session completion handler so it can be called after downloads finish.
final class BackgroundSessionCompletionStore {
    static let shared = BackgroundSessionCompletionStore()
    var completionHandler: (() -> Void)? {
        didSet {
            // Call it after a short delay — the Hub session delegate processes events first
            if let handler = completionHandler {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    handler()
                    self.completionHandler = nil
                    print("📥 Background session completion handler called")
                }
            }
        }
    }
}

final class OpenGlassesSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        for context in URLContexts {
            processWearablesCallbackURL(context.url, source: "SceneDelegate")
        }
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        if let url = userActivity.webpageURL {
            processWearablesCallbackURL(url, source: "SceneDelegateUserActivity")
        }
    }
}

/// Static accessor so AppIntents (Action Button) can reach the running AppState.
@MainActor
enum AppStateProvider {
    static weak var shared: AppState?
}

@main
struct OpenGlassesApp: App {
    @UIApplicationDelegateAdaptor(OpenGlassesAppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        configureWearables()
        NetworkMonitorService.register()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .onAppear { AppStateProvider.shared = appState }
                .onOpenURL { url in
                    // Handle widget quick action deep links
                    if url.scheme == "openglasses", url.host == "action" {
                        let action = url.lastPathComponent
                        Task { @MainActor in
                            switch action {
                            case "ask":
                                appState.wakeWordService.stopListening()
                                try? await Task.sleep(nanoseconds: 100_000_000)
                                await appState.handleWakeWordDetected()
                            case "photo":
                                await appState.captureAndAnalyzePhoto()
                            case "describe":
                                await appState.capturePhotoAndSend(prompt: "Describe what you see in detail.")
                            default:
                                break
                            }
                        }
                        return
                    }
                    processWearablesCallbackURL(url, source: "SwiftUI")
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                print("📱 App moved to background — keeping audio alive")
                appState.liveActivityManager.end()
            case .active:
                print("📱 App became active")
                appState.liveActivityManager.start(glassesName: appState.glassesService.deviceName ?? "OpenGlasses")
                appState.updateLiveActivity()
                Task {
                    // Give onOpenURL time to process any pending Meta Auth callbacks
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    
                    let state = Wearables.shared.registrationState
                    if state.rawValue < 3 {
                        print("📋 Registration dropped to \(state.rawValue) after background — waiting for natural reconnect...")
                    }
                }
                // Only restart wake word listener in Direct Mode
                if appState.currentMode == .direct {
                    Task {
                        let regState = appState.registrationStateRaw
                        guard regState >= 3 else {
                            appState.addDebugEvent("Skipping wake word restart on foreground: registration state=\(regState)")
                            return
                        }

                        if !appState.wakeWordService.isListening && !appState.isListening {
                            print("🎤 Restarting wake word listener after foreground...")
                            // Re-configure audio session in case Bluetooth route changed
                            appState.wakeWordService.reconfigureAudioSessionIfNeeded()
                            // Small delay for route to stabilize after foregrounding
                            try? await Task.sleep(nanoseconds: 500_000_000)
                            try? await appState.wakeWordService.startListening()
                        }
                    }
                }
            case .inactive:
                break
            @unknown default:
                break
            }
        }
    }

    private func configureWearables() {
        do {
            NSLog("[OpenGlasses] Logging active")
            try Wearables.configure()
            NSLog("[OpenGlasses] Meta Wearables SDK configured successfully")
            let state = Wearables.shared.registrationState
            NSLog("[OpenGlasses] Registration state: \(state.rawValue)")
            let bundleId = Bundle.main.bundleIdentifier ?? "unknown"
            let mwdat = Bundle.main.object(forInfoDictionaryKey: "MWDAT") as? [String: Any]
            if let mwdat {
                NSLog("[OpenGlasses] MWDAT keys: \(mwdat.keys.sorted().joined(separator: ", "))")
            } else {
                NSLog("[OpenGlasses] MWDAT dictionary missing from Info.plist")
            }
            let appLinkURL = mwdat?["AppLinkURLScheme"] as? String
            let metaAppID = mwdat?["MetaAppID"] as? String

            NSLog("[OpenGlasses] Bundle ID: \(bundleId)")
            NSLog("[OpenGlasses] AppLinkURLScheme (Universal Link): \(appLinkURL ?? "nil")")
            NSLog("[OpenGlasses] MetaAppID: \(metaAppID ?? "nil")")

            do {
                let parsed = try Configuration(bundle: .main)
                let app = parsed.appConfiguration
                NSLog("[OpenGlasses] Parsed config bundleIdentifier=\(app.bundleIdentifier)")
                NSLog("[OpenGlasses] Parsed config appLinkURLScheme=\(app.appLinkURLScheme ?? "nil")")
                NSLog("[OpenGlasses] Parsed config metaAppId=\(app.metaAppId ?? "nil")")
                NSLog("[OpenGlasses] Parsed config clientTokenPresent=\(app.clientToken != nil)")
                NSLog("[OpenGlasses] Parsed config teamID=\(app.teamID ?? "nil")")
                NSLog("[OpenGlasses] Parsed attestation hasCompleteData=\(parsed.attestationConfiguration.hasCompleteData)")
            } catch {
                NSLog("[OpenGlasses] Configuration(bundle:) parse failed: \(error.localizedDescription)")
            }
        } catch {
            NSLog("[OpenGlasses] Failed to configure Wearables SDK: \(error.localizedDescription)")
        }
    }
}

/// Global application state
@MainActor
class AppState: ObservableObject {
    @Published var isConnected: Bool = false
    @Published var registrationStateRaw: Int = 0
    @Published var lastCallbackSource: String = "—"
    @Published var lastCallbackURL: String = "—"
    @Published var lastCallbackAt: Date?
    @Published var debugEvents: [String] = []
    @Published var isListening: Bool = false
    @Published var currentTranscription: String = ""
    @Published var lastResponse: String = ""
    @Published var errorMessage: String?
    @Published var currentMode: AppMode = Config.appMode
    @Published var activePersona: Persona?

    let glassesService = GlassesConnectionService()
    let wakeWordService = WakeWordService()
    let transcriptionService = TranscriptionService()
    let llmService = LLMService()
    let localLLMService = LocalLLMService()
    let mcpClient = MCPClient()
    let liveTranslation = LiveTranslationService()
    let speechService = TextToSpeechService()
    let cameraService = CameraService()
    let videoRecorder = VideoRecordingService()
    let broadcastService = BroadcastService()
    let locationService = LocationService()
    let proactiveAlerts = ProactiveAlertService()
    let ambientCaptions = AmbientCaptionService()
    let faceRecognition = FaceRecognitionService()
    let memoryRewind = MemoryRewindService()
    let privacyFilter = PrivacyFilterService()
    let webRTCStreaming = WebRTCStreamingService()
    let liveActivityManager = LiveActivityManager()
    let agentDocs = AgentDocumentStore()
    let agentScheduler = AgentScheduler()
    let agentNotificationQueue = AgentNotificationQueue()

    /// Pending item to show in the share sheet
    @Published var pendingShareItem: ShareItem?

    // OpenClaw + Realtime sessions
    let openClawBridge = OpenClawBridge()
    let geminiLiveSession = GeminiLiveSessionManager()
    let openAIRealtimeSession = OpenAIRealtimeSessionManager()

    // Native tool system
    let nativeToolRegistry: NativeToolRegistry
    let nativeToolRouter: NativeToolRouter

    // Tier 1 services
    let conversationStore = ConversationStore()
    let userMemory = UserMemoryStore()
    let intentClassifier = IntentClassifier()

    private var cancellables: [Any] = []
    @Published private(set) var isProcessing: Bool = false
    private var hasEverRegistered: Bool = false
    var inConversation: Bool = false

    func addDebugEvent(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let timestamp = formatter.string(from: Date())
        debugEvents.append("[\(timestamp)] \(message)")
        if debugEvents.count > 80 {
            debugEvents.removeFirst(debugEvents.count - 80)
        }
    }

    func recordCallback(url: URL, source: String) {
        lastCallbackSource = source
        lastCallbackURL = url.absoluteString
        lastCallbackAt = Date()
        addDebugEvent("Callback received via \(source)")
    }

    private func waitForRegistration(minState: Int, timeoutSeconds: Double) async -> Int {
        let waitStart = ContinuousClock.now
        while true {
            let state = Wearables.shared.registrationState.rawValue
            if state >= minState { return state }
            if ContinuousClock.now - waitStart > .seconds(timeoutSeconds) { return state }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    init() {
        // Initialize native tool system
        nativeToolRegistry = NativeToolRegistry(
            locationService: locationService,
            conversationStore: conversationStore,
            faceRecognitionService: faceRecognition,
            cameraService: cameraService,
            memoryRewindService: memoryRewind,
            ambientCaptionService: ambientCaptions,
            openClawBridge: openClawBridge
        )
        nativeToolRouter = NativeToolRouter(registry: nativeToolRegistry, openClawBridge: openClawBridge)

        addDebugEvent("AppState initialized")
        // Share the audio engine so transcription works in background
        transcriptionService.sharedAudioEngineProvider = wakeWordService

        // Wire Tier 1 services
        ambientCaptions.wakeWordService = wakeWordService
        memoryRewind.wakeWordService = wakeWordService
        faceRecognition.onRecognition = { [weak self] name in
            Task { @MainActor in
                // Whisper the name quietly via TTS
                await self?.speechService.speak("That's \(name).")
            }
        }

        // Wire OpenClaw bridge to both Direct Mode and Gemini Live
        llmService.openClawBridge = openClawBridge
        geminiLiveSession.openClawBridge = openClawBridge

        // Wire native tool router to LLM service and Gemini Live
        llmService.nativeToolRouter = nativeToolRouter
        nativeToolRouter.mcpClient = mcpClient

        // Register live translation tool with its service reference
        var translationTool = LiveTranslationTool()
        translationTool.translationService = liveTranslation
        nativeToolRegistry.register(translationTool)

        // Wire translation output to TTS
        liveTranslation.onTranslation = { [weak self] translation in
            Task { @MainActor in
                await self?.speechService.speak(translation)
            }
        }
        llmService.localLLMService = localLLMService
        geminiLiveSession.nativeToolRouter = nativeToolRouter

        // Wire camera frames for realtime sessions:
        // Direct push: CameraService streams frames to whichever session is active
        cameraService.onVideoFrame = { [weak self] image in
            guard let self else { return }
            if self.currentMode == .geminiLive {
                self.geminiLiveSession.submitVideoFrame(image)
            } else if self.currentMode == .openaiRealtime {
                self.openAIRealtimeSession.submitVideoFrame(image)
            }
        }

        // Polling fallback for both session managers
        geminiLiveSession.onRequestVideoFrame = { [weak self] in
            return self?.cameraService.latestFrame
        }
        openAIRealtimeSession.onRequestVideoFrame = { [weak self] in
            return self?.cameraService.latestFrame
        }

        // Location context for both
        geminiLiveSession.locationContext = { [weak self] in
            return self?.locationService.locationContext
        }
        openAIRealtimeSession.locationContext = { [weak self] in
            return self?.locationService.locationContext
        }

        // Camera start request — shared between both session managers
        let cameraStartHandler: () async -> Bool = { [weak self] in
            guard let self else { return false }
            if self.cameraService.isStreaming {
                NSLog("[App] Camera already streaming")
                return true
            }
            do {
                try await self.cameraService.startStreaming()
                NSLog("[App] Camera streaming started on session request")
                return true
            } catch {
                NSLog("[App] Camera streaming failed: %@", error.localizedDescription)
                return false
            }
        }
        geminiLiveSession.onRequestStartCamera = cameraStartHandler
        openAIRealtimeSession.onRequestStartCamera = cameraStartHandler

        // Wire Watch app connectivity
        WatchConnectivityManager.shared.appState = self
        WatchConnectivityManager.shared.activate()

        // Agent personality: start scheduler if enabled
        agentScheduler.appState = self
        agentNotificationQueue.appState = self
        if Config.agentPersonalityEnabled {
            agentScheduler.start()
        }

        setupServiceCallbacks()
        observeGlassesConnection()
        autoConnectGlasses()

        // Mode-specific auto-start
        if currentMode == .direct {
            autoStartListening()
        } else if currentMode.isRealtime {
            // Pre-start camera streaming so frames are ready when user taps "Start Session"
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                do {
                    try await cameraService.startStreaming()
                } catch {
                    NSLog("[App] Camera streaming auto-start failed: %@", error.localizedDescription)
                }
            }
        }
        locationService.startTracking()

        // Start proactive calendar alerts — speaks through TTS when events are imminent
        proactiveAlerts.onAlert = { [weak self] message in
            guard let self else { return }
            Task {
                await self.speechService.speak(message)
            }
        }
        proactiveAlerts.start()

        // Wire geofence alerts — speak via TTS when entering/leaving a region
        if let geofenceTool = nativeToolRegistry.tool(named: "geofence") as? GeofenceTool {
            geofenceTool.onAlert = { [weak self] message in
                guard let self else { return }
                Task {
                    await self.speechService.speak(message)
                }
            }
            geofenceTool.restoreGeofences()
        }

        // Privacy filter — apply saved preference
        privacyFilter.isEnabled = Config.privacyFilterEnabled
    }

    /// Switch between app modes: Direct, Gemini Live, or OpenAI Realtime.
    /// Tears down the current mode's audio and starts the new one.
    func switchMode(to mode: AppMode) {
        guard mode != currentMode else { return }
        let oldMode = currentMode
        currentMode = mode
        Config.setAppMode(mode)

        Task {
            // Tear down old mode
            switch oldMode {
            case .direct:
                wakeWordService.stopListening()
                speechService.stopSpeaking()
                inConversation = false
                isListening = false
            case .geminiLive:
                geminiLiveSession.stopSession()
                await cameraService.tearDown()
            case .openaiRealtime:
                openAIRealtimeSession.stopSession()
                await cameraService.tearDown()
            }

            // Brief delay for audio session to release
            try? await Task.sleep(nanoseconds: 500_000_000)

            // Start new mode
            switch mode {
            case .direct:
                try? await wakeWordService.startListening()
            case .geminiLive, .openaiRealtime:
                // Start camera streaming so frames are available when session starts
                do {
                    try await cameraService.startStreaming()
                } catch {
                    NSLog("[App] Camera streaming failed to start: %@", error.localizedDescription)
                }
            }
        }
    }

    private func setupServiceCallbacks() {
        // Wire camera debug events to the on-screen debug log
        cameraService.onDebugEvent = { [weak self] message in
            Task { @MainActor in
                self?.addDebugEvent(message)
            }
        }

        wakeWordService.onWakeWordDetected = { [weak self] matchedPhrase in
            Task { @MainActor in
                guard let self = self else { return }
                guard !self.inConversation && !self.isProcessing else {
                    print("⚠️ Wake word ignored - already in conversation")
                    return
                }
                // Route to the persona that owns this wake phrase
                if let persona = Config.persona(forPhrase: matchedPhrase) {
                    self.activePersona = persona
                    Config.setActiveModelId(persona.modelId)
                    Config.setActivePresetId(persona.presetId)
                    self.llmService.refreshActiveModel()
                    print("🎭 Persona activated: \(persona.name) (model: \(persona.modelId))")
                }
                await self.handleWakeWordDetected()
            }
        }

        wakeWordService.onStopCommand = { [weak self] in
            Task { @MainActor in
                self?.stopSpeakingAndResume()
            }
        }

        transcriptionService.onTranscriptionComplete = { [weak self] text in
            Task { @MainActor in
                guard let self = self else { return }
                // Prevent processing if already handling a response
                guard !self.isProcessing else {
                    print("⚠️ Transcription ignored - already processing")
                    return
                }
                await self.handleTranscription(text)
            }
        }

        // When user doesn't say anything after Claude responds, end conversation
        transcriptionService.onSilenceTimeout = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                print("💤 User silent — ending conversation, back to wake word")
                await self.returnToWakeWord()
            }
        }
    }

    private func observeGlassesConnection() {
        // Monitor devices list
        let deviceToken = Wearables.shared.addDevicesListener { [weak self] deviceIds in
            Task { @MainActor in
                guard let self else { return }
                print("📋 Devices changed: \(deviceIds)")
                self.addDebugEvent("Devices changed: \(deviceIds.count)")
                if !deviceIds.isEmpty {
                    let wasDisconnected = !self.isConnected
                    self.hasEverRegistered = true
                    self.isConnected = true

                    // Deliver queued agent notifications on reconnect
                    if wasDisconnected && Config.agentPersonalityEnabled {
                        // Delay to let audio session stabilize after Bluetooth reconnect
                        Task {
                            try? await Task.sleep(nanoseconds: 3_000_000_000)
                            self.agentNotificationQueue.onGlassesReconnected()
                        }
                    }
                }
            }
        }
        cancellables.append(deviceToken)

        // Monitor registration state
        // Registration bounces between states 0-3, so once we see state 3,
        // consider connected for the session (don't disconnect on state changes)
        let regToken = Wearables.shared.addRegistrationStateListener { [weak self] newState in
            Task { @MainActor in
                guard let self else { return }
                print("📋 Registration state changed: \(newState.rawValue)")
                self.addDebugEvent("Registration state -> \(newState.rawValue)")
                self.registrationStateRaw = newState.rawValue
                if newState.rawValue >= 3 {
                    // State 3 = fully registered
                    self.hasEverRegistered = true
                    self.isConnected = true
                    UserDefaults.standard.set(true, forKey: "hasRegisteredWithMeta")
                }
            }
        }
        cancellables.append(regToken)

        // Check initial state
        let initialState = Wearables.shared.registrationState
        print("📋 Initial registration state: \(initialState.rawValue)")
        addDebugEvent("Initial registration state: \(initialState.rawValue)")
        registrationStateRaw = initialState.rawValue
        if initialState.rawValue >= 3 {
            hasEverRegistered = true
            isConnected = true
            print("📋 Already registered on launch")
        }
    }

    /// Observe SDK registration state on launch.
    /// NEVER auto-calls startRegistration() — that must be user-initiated only.
    /// The SDK may auto-reconnect via Bluetooth if previously registered.
    ///
    /// IMPORTANT: Devices won't appear in `addDevicesListener` until camera permission
    /// is granted. We request permission early after reaching state 3 so devices become visible.
    private func autoConnectGlasses() {
        Task {
            // Small delay to let SDK initialize
            try? await Task.sleep(nanoseconds: 500_000_000)  // 0.5s
            let state = Wearables.shared.registrationState
            self.registrationStateRaw = state.rawValue
            print("📋 Launch state check: state=\(state.rawValue)")
            self.addDebugEvent("Launch state check: state=\(state.rawValue)")

            if state.rawValue >= 3 {
                // Already registered this session
                self.hasEverRegistered = true
                self.addDebugEvent("Already registered on launch")
                await requestEarlyPermission()
            } else {
                // Wait briefly for SDK to auto-reconnect via Bluetooth
                try? await Task.sleep(nanoseconds: 3_000_000_000)  // 3s
                let settledState = Wearables.shared.registrationState
                self.registrationStateRaw = settledState.rawValue
                if settledState.rawValue >= 3 {
                    self.hasEverRegistered = true
                    self.addDebugEvent("SDK auto-reconnected to state \(settledState.rawValue)")
                    await requestEarlyPermission()
                } else {
                    self.isConnected = false
                    self.addDebugEvent("State \(settledState.rawValue) — tap Connect to register")
                }
            }
        }
    }

    /// Request camera permission early so devices appear in addDevicesListener.
    /// Per Meta docs: "A device will not appear in devicesStream until the user has
    /// granted at least one permission (e.g., camera) through the Meta AI app."
    private func requestEarlyPermission() async {
        addDebugEvent("Requesting early camera permission for device discovery...")

        // Ensure iOS camera permission first
        let iosVideoStatus = AVCaptureDevice.authorizationStatus(for: .video)
        if iosVideoStatus == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            if !granted {
                addDebugEvent("iOS camera permission denied")
                return
            }
        } else if iosVideoStatus == .denied || iosVideoStatus == .restricted {
            addDebugEvent("iOS camera permission denied/restricted")
            return
        }

        // Brief stabilization delay
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        // Check/request Meta SDK camera permission
        do {
            let status = try? await Wearables.shared.checkPermissionStatus(.camera)
            addDebugEvent("Early check: \(String(describing: status))")
            if status == .granted {
                addDebugEvent("Camera permission already granted — devices should appear")
                // Mark as connected — devices should now appear via listener
                self.isConnected = true
                // Also ensure CameraService knows permission is cached
                cameraService.permissionGranted = true
                return
            }

            // Request permission — this deep-links to Meta AI app
            addDebugEvent("Requesting Meta camera permission...")
            let result = try await Wearables.shared.requestPermission(.camera)
            addDebugEvent("Early permission result: \(String(describing: result))")
            if result == .granted {
                self.isConnected = true
                cameraService.permissionGranted = true
            }
        } catch {
            addDebugEvent("Early permission failed: \(error.localizedDescription)")
            // Still mark as connected based on registration state —
            // user can retry permission via UI
            self.isConnected = true
        }

        // Poll devices list after permission to track when device appears
        await pollForDevices()
    }

    /// Poll the devices list after permission grant to track device discovery
    private func pollForDevices() async {
        let immediateDevices = Wearables.shared.devices
        addDebugEvent("Devices immediately after permission: \(immediateDevices.count)")

        // Poll every 2s for up to 30s to see when/if device appears
        for i in 1...15 {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            let devices = Wearables.shared.devices
            if !devices.isEmpty {
                addDebugEvent("Device appeared after \(i*2)s! Count: \(devices.count)")
                if let firstId = devices.first {
                    let device = Wearables.shared.deviceForIdentifier(firstId)
                    addDebugEvent("Device: \(device?.name ?? "unknown") type=\(String(describing: device?.deviceType()))")
                }
                self.isConnected = true
                return
            }
            if i % 5 == 0 {
                addDebugEvent("Still polling for devices... \(i*2)s, count=\(devices.count)")
            }
        }
        addDebugEvent("No device appeared after 30s of polling")
    }

    func completeAuthorizationInMetaAI() async {
        addDebugEvent("Manual Meta authorization requested")
        do {
            try await Wearables.shared.startRegistration()
        } catch {
            print("📋 Manual registration start failed: \(error)")
            addDebugEvent("Manual registration start failed: \(error.localizedDescription)")
        }

        let currentState = Wearables.shared.registrationState.rawValue
        registrationStateRaw = currentState
        if currentState >= 3 {
            await requestEarlyPermission()
            return
        }

        await MainActor.run {
            guard let viewAppUrl = URL(string: "fb-viewapp://") else { return }
            if UIApplication.shared.canOpenURL(viewAppUrl) {
                UIApplication.shared.open(viewAppUrl, options: [:])
            }
        }
    }

    func resetMetaRegistration() async {
        addDebugEvent("Manual reset requested: startUnregistration")
        do {
            try await Wearables.shared.startUnregistration()
            addDebugEvent("startUnregistration succeeded")
        } catch {
            addDebugEvent("startUnregistration failed: \(error.localizedDescription)")
        }

        UserDefaults.standard.set(false, forKey: "hasRegisteredWithMeta")
        registrationStateRaw = Wearables.shared.registrationState.rawValue
        addDebugEvent("State after unregistration: \(registrationStateRaw)")

        try? await Task.sleep(nanoseconds: 1_000_000_000)

        addDebugEvent("Manual reset: startRegistration")
        do {
            try await Wearables.shared.startRegistration()
            let settled = await waitForRegistration(minState: 3, timeoutSeconds: 20)
            registrationStateRaw = settled
            addDebugEvent("Manual reset registration result: state=\(settled)")
        } catch {
            addDebugEvent("Manual reset startRegistration failed: \(error.localizedDescription)")
        }
    }

    /// Auto-start wake word listener on app launch (don't wait for "Connect" or "Test Mic")
    private func autoStartListening() {
        Task {
            // Small delay to let the app finish initializing
            try? await Task.sleep(nanoseconds: 1_000_000_000)  // 1s

            // Avoid starting audio capture while registration is still negotiating,
            // as Bluetooth route churn can destabilize registration state transitions.
            if registrationStateRaw < 3 {
                addDebugEvent("Wake word auto-start deferred: registration state=\(registrationStateRaw)")
                let settled = await waitForRegistration(minState: 3, timeoutSeconds: 20)
                registrationStateRaw = settled
                addDebugEvent("Wake word auto-start registration wait result: state=\(settled)")
                guard settled >= 3 else {
                    addDebugEvent("Skipping wake word auto-start: registration did not reach state 3")
                    return
                }
            }

            if !wakeWordService.isListening {
                print("🎤 Auto-starting wake word listener...")
                do {
                    try await wakeWordService.startListening()
                    print("✅ Wake word listener auto-started")
                } catch {
                    print("⚠️ Auto-start failed: \(error.localizedDescription)")
                    // Not fatal — user can still use Test Microphone button
                }
            }
        }
    }

    func stopSpeakingAndResume() {
        print("🛑 User tapped stop")
        speechService.stopSpeaking()
        isProcessing = false
            speechService.stopThinkingSound()
        // Stay in conversation — listen for follow-up right away
        if inConversation {
            print("💬 Listening for follow-up after stop...")
            isListening = true
            transcriptionService.startRecording()
        } else {
            Task { await returnToWakeWord() }
        }
    }

    /// The agent context (soul.md + skills.md + memory.md) if personality mode is enabled.
    var currentAgentContext: String? {
        Config.agentPersonalityEnabled ? agentDocs.agentContext() : nil
    }

    /// Push current state to the Live Activity on Lock Screen / Dynamic Island.
    func updateLiveActivity() {
        liveActivityManager.update(
            isConnected: isConnected,
            isListening: isListening,
            isSpeaking: speechService.isSpeaking,
            isProcessing: isProcessing,
            lastResponse: lastResponse,
            deviceName: glassesService.deviceName
        )
    }

    /// Cancel current LLM processing or TTS playback and return to wake word listening.
    func cancelCurrentResponse() {
        print("🛑 User cancelled response")
        speechService.stopSpeaking()
        isProcessing = false
            speechService.stopThinkingSound()
        isListening = false
        inConversation = false
        lastResponse = "Cancelled"
        activePersona = nil
        updateLiveActivity()
        Task { await returnToWakeWord() }
    }

    /// Capture a photo and send it to the LLM with a custom prompt.
    func capturePhotoAndSend(prompt: String) async {
        guard isConnected else {
            errorMessage = "Connect glasses first"
            return
        }
        isProcessing = true
        speechService.startThinkingSound()
        do {
            let photoData = try await cameraService.capturePhoto()
            if currentMode == .direct {
                cameraService.restoreAudioForWakeWord()
            }
            cameraService.saveToPhotoLibrary(photoData)
            print("📸 Photo + prompt: \(prompt)")

            let rawResponse = try await llmService.sendMessage(
                prompt,
                locationContext: locationService.locationContext,
                imageData: photoData,
                memoryContext: Config.userMemoryEnabled ? userMemory.systemPromptContext() : nil
            )
            let response = Config.userMemoryEnabled ? userMemory.parseAndExecuteCommands(in: rawResponse) : rawResponse
            lastResponse = response
            if Config.conversationPersistenceEnabled {
                conversationStore.appendMessage(role: "user", content: "[Photo] \(prompt)")
                conversationStore.appendMessage(role: "assistant", content: response)
            }

            isProcessing = false
            speechService.stopThinkingSound()
            startStopListener()
            await speechService.speak(response)
            stopStopListener()

            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.success)
        } catch {
            if currentMode == .direct {
                cameraService.restoreAudioForWakeWord()
            }
            isProcessing = false
            speechService.stopThinkingSound()
            errorMessage = "Photo failed: \(error.localizedDescription)"
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.error)
        }
    }

    /// Capture a photo from the glasses camera and present the share sheet.
    /// Capture a photo and send it to the LLM for analysis (manual camera button).
    func captureAndAnalyzePhoto() async {
        guard isConnected else {
            errorMessage = "Connect glasses first"
            return
        }
        isProcessing = true
        speechService.startThinkingSound()
        do {
            let photoData = try await cameraService.capturePhoto()
            if currentMode == .direct {
                cameraService.restoreAudioForWakeWord()
            }
            cameraService.saveToPhotoLibrary(photoData)
            print("📸 Manual photo captured, sending to LLM for analysis")

            let prompt = "Describe what you see in this image."
            let rawResponse = try await llmService.sendMessage(
                prompt,
                locationContext: locationService.locationContext,
                imageData: photoData,
                memoryContext: Config.userMemoryEnabled ? userMemory.systemPromptContext() : nil
            )
            let response = Config.userMemoryEnabled ? userMemory.parseAndExecuteCommands(in: rawResponse) : rawResponse
            lastResponse = response
            if Config.conversationPersistenceEnabled {
                conversationStore.appendMessage(role: "user", content: "[Photo taken manually]")
                conversationStore.appendMessage(role: "assistant", content: response)
            }
            print("🤖 \(llmService.activeModelName) (vision): \(response)")

            isProcessing = false
            speechService.stopThinkingSound()
            startStopListener()
            await speechService.speak(response)
            stopStopListener()

            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.success)
        } catch {
            if currentMode == .direct {
                cameraService.restoreAudioForWakeWord()
            }
            isProcessing = false
            speechService.stopThinkingSound()
            errorMessage = "Photo failed: \(error.localizedDescription)"
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.error)
        }
    }

    func captureAndSharePhoto() async {
        guard isConnected else {
            errorMessage = "Connect glasses first"
            return
        }
        do {
            let photoData = try await cameraService.capturePhoto()
            // Restore audio for wake word if in direct mode (camera reconfigured audio for Bluetooth)
            if currentMode == .direct {
                cameraService.restoreAudioForWakeWord()
            }
            if let image = UIImage(data: photoData) {
                pendingShareItem = ShareItem(items: [image])
                let generator = UINotificationFeedbackGenerator()
                generator.notificationOccurred(.success)
            }
        } catch {
            // Restore audio even on failure
            if currentMode == .direct {
                cameraService.restoreAudioForWakeWord()
            }
            errorMessage = "Photo failed: \(error.localizedDescription)"
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.error)
        }
    }

    /// Legacy capture that saves directly to camera roll (used by voice command).
    func capturePhotoFromGlasses() async {
        guard isConnected else {
            errorMessage = "Connect glasses first"
            return
        }
        do {
            let photoData = try await cameraService.capturePhoto()
            // Restore audio for wake word if in direct mode
            if currentMode == .direct {
                cameraService.restoreAudioForWakeWord()
            }
            cameraService.saveToPhotoLibrary(photoData)
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.success)
            lastResponse = "Photo saved to camera roll"
        } catch {
            if currentMode == .direct {
                cameraService.restoreAudioForWakeWord()
            }
            errorMessage = "Photo failed: \(error.localizedDescription)"
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.error)
        }
    }

    /// Toggle video recording on/off.
    func toggleRecording() async {
        if videoRecorder.isRecording {
            if let url = await videoRecorder.stopRecording() {
                pendingShareItem = ShareItem(items: [url])
            }
        } else {
            do {
                try videoRecorder.startRecording(
                    from: cameraService.framePublisher,
                    bitrate: Config.recordingBitrate
                )
            } catch {
                errorMessage = "Recording failed: \(error.localizedDescription)"
            }
        }
    }

    /// Toggle live broadcast on/off.
    func toggleBroadcast() async {
        if broadcastService.isBroadcasting {
            broadcastService.stopBroadcast()
        } else {
            do {
                try await broadcastService.startBroadcast(
                    rtmpURL: Config.broadcastRTMPURL,
                    streamKey: Config.broadcastStreamKey,
                    from: cameraService.framePublisher
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Start listening directly — no wake word needed.
    /// Called from Action Button intent or manual mic button.
    /// Transcription will check for persona names in the spoken text.
    func startDirectTranscription() {
        print("🎤 Action Button: starting direct transcription (no wake word)")
        Task {
            // Configure audio (uses glasses mic if connected, phone mic otherwise)
            wakeWordService.configureAudioSession()
            await handleWakeWordDetected()
        }
    }

    func handleWakeWordDetected() async {
        print("🎤 Wake word detected! Starting conversation...")
        inConversation = true
        isListening = true
        speechService.playAcknowledgmentTone()
        transcriptionService.startRecording()
        updateLiveActivity()
    }

    // MARK: - Voice Commands

    private static let stopPhrases = ["stop", "nevermind", "never mind", "cancel", "shut up", "be quiet", "quiet"]
    private static let goodbyePhrases = ["goodbye", "good bye", "bye", "that's all", "thats all",
                                          "thanks claude", "thank you claude", "i'm done", "im done",
                                          "end conversation", "go to sleep"]
    private static let photoPhrases = ["take a picture", "take a photo", "take photo", "take picture",
                                        "capture photo", "snap a photo", "snap a picture", "take a snap"]

    private func isStopCommand(_ text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.stopPhrases.contains(where: { lower == $0 || lower.hasPrefix($0 + " ") || lower.hasSuffix(" " + $0) })
    }

    private func isGoodbyeCommand(_ text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.goodbyePhrases.contains(where: { lower.contains($0) })
    }

    private func isPhotoCommand(_ text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.photoPhrases.contains(where: { lower.contains($0) })
    }

    /// Reuse an already-available live frame for vision-capable models without trying to
    /// start the camera. This avoids re-triggering fragile Meta camera permission flows.
    private func currentVisionFrameDataIfAvailable() -> Data? {
        guard Config.activeModel?.visionEnabled == true else { return nil }
        guard cameraService.isStreaming, let frame = cameraService.latestFrame else { return nil }
        return frame.jpegData(compressionQuality: Config.geminiLiveVideoJPEGQuality)
    }

    func handleTranscription(_ text: String) async {
        guard !isProcessing else {
            print("⚠️ Already processing, ignoring: \(text)")
            return
        }

        currentTranscription = text
        isListening = false
        errorMessage = nil
        speechService.playEndListeningTone()
        print("📝 Transcription: \(text)")

        // Will be updated below if persona detected in text
        var query = text

        // Intent classification — filter bystander/filler speech
        if intentClassifier.isEnabled && !isPhotoCommand(text) && !isStopCommand(text) && !isGoodbyeCommand(text) {
            let intent = await intentClassifier.classify(transcript: text)
            if intent == .ignore {
                print("🚫 Intent classifier: IGNORE — not responding")
                if inConversation {
                    isListening = true
                    transcriptionService.startRecording()
                } else {
                    await returnToWakeWord()
                }
                return
            }
        }

        // Check for persona names in the transcription (for Action Button / push-to-talk mode)
        // e.g. "Hey Claude, what's the weather" → activate Claude persona, strip prefix
        if activePersona == nil {
            let lower = text.lowercased()
            for persona in Config.enabledPersonas {
                for phrase in persona.allPhrases {
                    if lower.hasPrefix(phrase) || lower.contains(phrase) {
                        activePersona = persona
                        Config.setActiveModelId(persona.modelId)
                        Config.setActivePresetId(persona.presetId)
                        llmService.refreshActiveModel()
                        print("🎭 Persona detected in transcription: \(persona.name)")
                        // Strip the wake phrase from the query
                        if let range = lower.range(of: phrase) {
                            query = String(text[range.upperBound...])
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                                .trimmingCharacters(in: CharacterSet(charactersIn: ","))
                                .trimmingCharacters(in: .whitespaces)
                        }
                        if query.isEmpty { query = text }
                        break
                    }
                }
                if activePersona != nil { break }
            }
        }

        // Track in conversation store
        if Config.conversationPersistenceEnabled {
            if conversationStore.activeThreadId == nil {
                conversationStore.startThread(mode: currentMode.rawValue)
            }
            conversationStore.appendMessage(role: "user", content: text)
        }

        // Voice command: "stop" — interrupt TTS, stay in conversation
        if isStopCommand(text) {
            print("🛑 Voice command: stop")
            speechService.stopSpeaking()
            if inConversation {
                print("💬 Stopped — listening for next question...")
                isListening = true
                transcriptionService.startRecording()
            } else {
                await returnToWakeWord()
            }
            return
        }

        // Voice command: "goodbye" — end conversation, back to wake word
        if isGoodbyeCommand(text) {
            print("👋 Voice command: goodbye")
            speechService.stopSpeaking()
            inConversation = false
            lastResponse = "Goodbye!"
            await speechService.speak("Goodbye!")
            await returnToWakeWord()
            return
        }

        // Voice command: "take a picture" — capture photo from glasses camera
        if isPhotoCommand(text) {
            print("📸 Voice command: take a picture")
            isProcessing = true
            speechService.startThinkingSound()
            await speechService.speak("Taking a picture.")
            do {
                let photoData = try await cameraService.capturePhoto()
                // Restore audio for wake word after camera capture (camera reconfigures for Bluetooth)
                cameraService.restoreAudioForWakeWord()
                cameraService.saveToPhotoLibrary(photoData)
                print("📸 Photo saved, sending to LLM with prompt: \(query)")

                let rawResponse = try await llmService.sendMessage(
                    query,
                    locationContext: locationService.locationContext,
                    imageData: photoData,
                    memoryContext: Config.userMemoryEnabled ? userMemory.systemPromptContext() : nil
                )
                let response = Config.userMemoryEnabled ? userMemory.parseAndExecuteCommands(in: rawResponse) : rawResponse
                lastResponse = response
                if Config.conversationPersistenceEnabled {
                    conversationStore.appendMessage(role: "assistant", content: response)
                }
                print("🤖 \(llmService.activeModelName) (vision): \(response)")

                // Start wake word listener during TTS so user can say "stop"
                startStopListener()
                await speechService.speak(response)
                stopStopListener()

            } catch {
                cameraService.restoreAudioForWakeWord()
                print("📸 Photo capture failed: \(error)")
                lastResponse = "Photo failed: \(error.localizedDescription)"
                await speechService.speak("Sorry, I couldn't take a photo or process the image. \(error.localizedDescription)")
            }
            isProcessing = false
            speechService.stopThinkingSound()
            if inConversation {
                isListening = true
                transcriptionService.startRecording()
            } else {
                await returnToWakeWord()
            }
            return
        }

        // Normal message — send to LLM
        isProcessing = true
        speechService.startThinkingSound()

        do {
            let imageData = currentVisionFrameDataIfAvailable()
            if imageData != nil {
                print("🖼️ Reusing live camera frame for \(llmService.activeModelName)")
            }
            let rawResponse = try await llmService.sendMessage(
                query,
                locationContext: locationService.locationContext,
                imageData: imageData,
                memoryContext: Config.userMemoryEnabled ? userMemory.systemPromptContext() : nil
            )

            // Parse and execute memory commands from the response
            let response: String
            if Config.userMemoryEnabled {
                response = userMemory.parseAndExecuteCommands(in: rawResponse)
            } else {
                response = rawResponse
            }

            lastResponse = response
            print("🤖 \(llmService.activeModelName): \(response)")

            // Save to conversation store
            if Config.conversationPersistenceEnabled {
                conversationStore.appendMessage(role: "assistant", content: response)
            }

            // Start wake word listener during TTS so user can say "stop"
            startStopListener()
            await speechService.speak(response)
            stopStopListener()
        } catch {
            errorMessage = "Failed to get response: \(error.localizedDescription)"
            await speechService.speak("Sorry, I encountered an error.")
        }

        // After responding, stay in conversation — listen for follow-up
        isProcessing = false
            speechService.stopThinkingSound()
        if inConversation {
            print("💬 Continuing conversation — listening for follow-up...")
            isListening = true
            transcriptionService.startRecording()
        } else {
            await returnToWakeWord()
        }
    }

    /// Start wake word listener in "stop detection" mode during TTS playback
    /// Only starts if the audio engine is already running (don't create a new one during TTS)
    private func startStopListener() {
        wakeWordService.listenForStop = true
        // Only try if the engine is already alive — don't create a new one during playback
        if wakeWordService.getAudioEngine()?.isRunning == true {
            Task {
                do {
                    try await wakeWordService.startListening()
                    print("🎤 Stop listener active during TTS")
                } catch {
                    print("⚠️ Could not start stop listener: \(error)")
                }
            }
        } else {
            print("🎤 No running engine for stop listener — skipping")
        }
    }

    /// Stop the stop-detection listener before resuming normal flow
    /// Uses pauseRecognition to keep the engine alive
    private func stopStopListener() {
        wakeWordService.listenForStop = false
        wakeWordService.pauseRecognitionPublic()
    }

    func returnToWakeWord() async {
        isListening = false
        inConversation = false
        activePersona = nil
        wakeWordService.listenForStop = false
        speechService.playDisconnectTone()
        updateLiveActivity()
        // End active conversation thread
        if Config.conversationPersistenceEnabled && conversationStore.activeThreadId != nil {
            conversationStore.endThread()
        }
        // In silent mode, don't restart the wake word listener — agent is still
        // actionable via watch, widget, Action Button, and manual mic tap
        if Config.silentMode {
            print("🔇 Silent mode — wake word listener stays off")
            return
        }
        do {
            try await wakeWordService.startListening()
            print("✅ Wake word restarted")
        } catch {
            print("❌ Failed to restart listener: \(error)")
            errorMessage = "Tap Test Microphone to restart"
        }
    }
}
