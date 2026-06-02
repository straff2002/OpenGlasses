import SwiftUI
import Combine
import MWDATCore
import AVFoundation
import AppIntents
import UIKit
import CarPlay
import MLXLLM
import MediaPlayer

extension Notification.Name {
    static let onboardingCompleted = Notification.Name("onboardingCompleted")
}

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

        // Route CarPlay scenes to the CarPlay delegate
        if connectingSceneSession.role == UISceneSession.Role(rawValue: "CPTemplateApplicationSceneSessionRoleApplication") {
            let config = UISceneConfiguration(name: "OpenGlassesCarPlayScene", sessionRole: connectingSceneSession.role)
            config.delegateClass = CarPlaySceneDelegate.self
            return config
        }

        let configuration = UISceneConfiguration(name: "OpenGlassesDeviceScene", sessionRole: connectingSceneSession.role)
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

    /// Lock the app to portrait — Info.plist declares all orientations (required on iOS 26
    /// without UIRequiresFullScreen), but we enforce portrait-only here.
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        return [.portrait, .portraitUpsideDown]
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
    @State private var isHipaaLocked = Config.hipaaMode

    init() {
        // Defer Wearables SDK (Bluetooth permission) until after onboarding
        if Config.hasCompletedOnboarding {
            configureWearables()
        }
        NetworkMonitorService.register()
        // Re-validate any stored Field Assist license (catches expiry between launches).
        LicenseService.shared.loadStored()
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootView()
                    .environmentObject(appState)

                // HIPAA biometric lock overlay
                if isHipaaLocked {
                    BiometricLockView(isLocked: $isHipaaLocked)
                        .transition(.opacity)
                        .zIndex(999)
                }
            }
            .onAppear {
                AppStateProvider.shared = appState
                ListeningChangedObserver.shared.start { newValue in
                    Task { @MainActor in
                        if appState.listeningEnabled != newValue {
                            appState.setListeningEnabled(newValue)
                        }
                    }
                }
            }
                .onOpenURL { url in
                    // Handle shortcut x-callback-url results
                    if url.scheme == "openglasses",
                       ["shortcut-result", "shortcut-cancel", "shortcut-error"].contains(url.host) {
                        ShortcutCallbackManager.shared.handleCallback(url: url)
                        return
                    }

                    // Handle persona quick-launch from widget/watch
                    if url.scheme == "openglasses", url.host == "persona" {
                        let personaId = url.lastPathComponent
                        Task { @MainActor in
                            if let persona = Config.enabledPersonas.first(where: { $0.id == personaId }) {
                                // Activate this persona's model + prompt
                                appState.activePersona = persona
                                Config.setActiveModelId(persona.modelId)
                                Config.setActivePresetId(persona.presetId)
                                appState.llmService.refreshActiveModel()
                                // Start listening immediately — skip wake word
                                appState.wakeWordService.stopListening()
                                try? await Task.sleep(nanoseconds: 100_000_000)
                                await appState.handleWakeWordDetected()
                            }
                        }
                        return
                    }

                    // Handle connect/disconnect deep links (from widget, DI, watch)
                    if url.scheme == "openglasses", url.host == "connect" {
                        Task { @MainActor in
                            await appState.connectAndListen()
                        }
                        return
                    }

                    if url.scheme == "openglasses", url.host == "disconnect" {
                        Task { @MainActor in
                            appState.disconnectGlasses()
                        }
                        return
                    }

                    // Handle widget quick action deep links
                    if url.scheme == "openglasses", url.host == "action" {
                        let action = url.lastPathComponent
                        Task { @MainActor in
                            switch action {
                            case "ask":
                                // Reconnect if needed, then listen
                                await appState.connectAndListen()
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

                    // Handle listen toggle from widget / Control Center / Action Button
                    if url.scheme == "openglasses", url.host == "listen" {
                        let action = url.lastPathComponent
                        Task { @MainActor in
                            switch action {
                            case "on":
                                appState.setListeningEnabled(true)
                            case "off":
                                appState.setListeningEnabled(false)
                            case "toggle":
                                appState.setListeningEnabled(!appState.listeningEnabled)
                            default:
                                break
                            }
                        }
                        return
                    }

                    // Handle quick action buttons from widget
                    if url.scheme == "openglasses", url.host == "quickaction" {
                        let actionId = url.lastPathComponent
                        Task { @MainActor in
                            guard let action = Config.quickActions.first(where: { $0.id == actionId }) else { return }
                            await appState.executeQuickAction(action)
                        }
                        return
                    }
                    processWearablesCallbackURL(url, source: "SwiftUI")
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                // Don't end Live Activity here — it should persist on the Lock Screen.
                // Ending it on background causes crashes (ActivityKit lifecycle conflict).
                if appState.isConnected {
                    print("📱 App moved to background — keeping audio alive (glasses connected)")
                    appState.optimizeForBackground()
                } else {
                    print("📱 App moved to background — stopping mic/camera (no glasses)")
                    appState.wakeWordService.stopListening()
                    Task { await appState.cameraService.stopStreaming() }
                }
                appState.conversationStore.lock()
                // Re-lock for HIPAA — requires biometric to re-enter
                if Config.hipaaMode { isHipaaLocked = true }
            case .active:
                print("📱 App became active")
                appState.restoreFromBackground()
                if appState.conversationStore.isLocked {
                    Task { await appState.conversationStore.unlock() }
                }
                // Sync listening state from UserDefaults (may have been toggled via widget intent)
                let storedEnabled = Config.listeningEnabled
                if appState.listeningEnabled != storedEnabled {
                    appState.setListeningEnabled(storedEnabled)
                }
                if appState.listeningEnabled {
                    appState.liveActivityManager.start(glassesName: appState.glassesService.deviceName ?? "OpenGlasses")
                    appState.updateLiveActivity()
                }
                if Config.hasCompletedOnboarding {
                    Task {
                        // Give onOpenURL time to process any pending Meta Auth callbacks
                        try? await Task.sleep(nanoseconds: 1_500_000_000)

                        let state = Wearables.shared.registrationState
                        if state.rawValue < 3 {
                            print("📋 Registration dropped to \(state.rawValue) after background — waiting for natural reconnect...")
                        }
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

                        if !appState.wakeWordService.isListening && !appState.isListening && appState.isConnected && !appState.micMuted && !Config.silentMode {
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
class AppState: ObservableObject, AppStateProtocol {
    @Published var isConnected: Bool = false {
        didSet {
            speechService.glassesConnected = isConnected
            // Clean up hardware-facing interfaces when glasses disconnect.
            // The agent and in-flight LLM requests keep running — results
            // can appear in notifications or be read when the app is opened.
            if !isConnected && oldValue {
                wakeWordService.stopListening()
                isListening = false
                inConversation = false
                glassesIdle = false

                // Stop realtime streaming sessions (they need the BT audio link)
                if geminiLiveSession.isActive { geminiLiveSession.stopSession() }
                if openAIRealtimeSession.isActive { openAIRealtimeSession.stopSession() }

                // Stop camera streaming and TTS (no speakers to output to)
                Task { await cameraService.stopStreaming() }
                speechService.stopSpeaking()

                NSLog("[Privacy] Glasses disconnected — stopped mic, sessions, camera. Agent continues.")
            } else if isConnected && !oldValue {
                // Smart connect: glasses just came on (e.g. mid text-only session). Hand
                // audio + wake word off to them — the mirror of the teardown above. iOS
                // routes audio output to the Bluetooth device automatically, but the
                // wake-word listener has to be (re)started on the glasses mic explicitly.
                speechService.playConnectTone()
                NSLog("[SmartConnect] Glasses connected — switching audio + wake word to glasses")
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // Let the Bluetooth audio link settle before grabbing the mic.
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    guard self.isConnected else { return }  // bail if it dropped again
                    self.wakeWordService.reconfigureAudioSessionIfNeeded()
                    if self.listeningEnabled && !self.isListening {
                        try? await self.wakeWordService.startListening()
                    }
                }
            }
        }
    }
    /// Glasses are connected but idle (likely in case — sustained audio silence detected).
    @Published var glassesIdle: Bool = false
    @Published var registrationStateRaw: Int = 0
    @Published var lastCallbackSource: String = "—"
    @Published var lastCallbackURL: String = "—"
    @Published var lastCallbackAt: Date?
    @Published var debugEvents: [String] = []
    @Published var isListening: Bool = false
    /// Now-playing info captured the moment a conversation starts (nil when nothing was playing).
    var nowPlayingAtStart: NowPlayingSnapshot? = nil
    @Published var micMuted: Bool = false {
        didSet {
            if micMuted {
                wakeWordService.stopListening()
                isListening = false
                NSLog("[Privacy] Mic muted by user")
            } else if isConnected {
                Task {
                    try? await wakeWordService.startListening()
                    NSLog("[Privacy] Mic unmuted — restarted listener")
                }
            }
        }
    }
    @Published var currentTranscription: String = ""
    @Published var lastResponse: String = ""
    @Published var errorMessage: String?
    @Published var currentMode: AppMode = Config.appMode
    @Published var activePersona: Persona? {
        didSet { userMemory.activePersonaId = activePersona?.id }
    }
    @Published var carPlayConnected: Bool = false
    @Published var listeningEnabled: Bool = Config.listeningEnabled

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
    let audioRecorder = AudioRecordingService()
    let meetingAssistant = MeetingAssistantService()
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
    let playbookStore = PlaybookStore()
    let hipaaService = HIPAAComplianceService()
    let medicalExportService = MedicalExportService()

    /// Pending item to show in the share sheet
    @Published var pendingShareItem: ShareItem?

    // OpenClaw + Realtime sessions
    let openClawBridge = OpenClawBridge()
    let openClawEventClient = OpenClawEventClient()
    let geminiLiveSession = GeminiLiveSessionManager()
    let openAIRealtimeSession = OpenAIRealtimeSessionManager()
    let backgroundVoice = BackgroundVoiceService()

    // Native tool system
    let nativeToolRegistry: NativeToolRegistry
    let nativeToolRouter: NativeToolRouter

    // Tier 1 services
    let conversationStore = ConversationStore()
    let userMemory = SemanticMemoryStore()
    let documentStore = DocumentStore()
    let intentClassifier = IntentClassifier()
    let conversationClassifier = ConversationClassifier()

    private var cancellables: [Any] = []
    private var autoSleepTask: Task<Void, Never>?
    private var currentLLMTask: Task<Void, Never>?
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
            openClawBridge: openClawBridge,
            videoRecorder: videoRecorder,
            audioRecorder: audioRecorder,
            medicalExportService: medicalExportService,
            semanticMemory: userMemory,
            documentStore: documentStore
        )
        nativeToolRouter = NativeToolRouter(registry: nativeToolRegistry, openClawBridge: openClawBridge)

        // Wire "still working" TTS callback for long-running tool executions
        nativeToolRouter.onLongRunningUpdate = { [weak self] message in
            guard let self else { return }
            Task { @MainActor in
                await self.speechService.speak(message)
            }
        }

        // Wire agent document store into the doc editing tool
        if var docTool = nativeToolRegistry.tool(named: "edit_agent_docs") as? AgentDocumentTool {
            docTool.agentDocs = agentDocs
            nativeToolRegistry.register(docTool)
        }
        if var pbTool = nativeToolRegistry.tool(named: "playbook") as? PlaybookTool {
            pbTool.playbookStore = playbookStore
            nativeToolRegistry.register(pbTool)
        }
        if var qaTool = nativeToolRegistry.tool(named: "quick_action") as? QuickActionTool {
            qaTool.appState = self
            nativeToolRegistry.register(qaTool)
        }

        addDebugEvent("AppState initialized")

        // Register Gemma 4 model type — not yet in the official mlx-swift-lm registry
        Task {
            await LLMTypeRegistry.shared.registerModelType("gemma4") { data in
                let config = try JSONDecoder().decode(Gemma4TextConfiguration.self, from: data)
                return Gemma4TextModel(config)
            }
            await LLMTypeRegistry.shared.registerModelType("gemma4_text") { data in
                let config = try JSONDecoder().decode(Gemma4TextConfiguration.self, from: data)
                return Gemma4TextModel(config)
            }
        }

        // Share the audio engine so transcription works in background
        transcriptionService.sharedAudioEngineProvider = wakeWordService

        // TTS borrows the wake-word service so it can pause/resume other audio via the
        // same reference-counted hold that the active-listening flow uses.
        speechService.wakeWordService = wakeWordService

        // Wire Tier 1 services
        ambientCaptions.wakeWordService = wakeWordService
        memoryRewind.wakeWordService = wakeWordService
        videoRecorder.wakeWordService = wakeWordService
        videoRecorder.ambientCaptionService = ambientCaptions
        videoRecorder.hipaaService = hipaaService
        videoRecorder.meetingAssistant = meetingAssistant
        videoRecorder.llmClosure = { [weak self] prompt in
            guard let self else { throw LLMError.missingAPIKey("AppState deallocated") }
            return try await self.llmService.sendMessage(prompt)
        }
        audioRecorder.wakeWordService = wakeWordService
        audioRecorder.ambientCaptionService = ambientCaptions
        audioRecorder.meetingAssistant = meetingAssistant
        audioRecorder.llmClosure = { [weak self] prompt in
            guard let self else { throw LLMError.missingAPIKey("AppState deallocated") }
            return try await self.llmService.sendMessage(prompt)
        }
        medicalExportService.hipaaService = hipaaService
        faceRecognition.onRecognition = { [weak self] name in
            Task { @MainActor in
                // Whisper the name quietly via TTS
                await self?.speechService.speak("That's \(name).")
            }
        }

        // HIPAA: enforce retention policy on launch
        if Config.hipaaMode {
            hipaaService.enforceRetentionPolicy()
            hipaaService.log(action: "APP_LAUNCHED", detail: "HIPAA mode active, retention: \(Config.hipaaRetentionDays) days")
        }

        // Wire OpenClaw bridge to both Direct Mode, Gemini Live, and memory store
        llmService.openClawBridge = openClawBridge
        geminiLiveSession.openClawBridge = openClawBridge
        userMemory.openClawBridge = openClawBridge

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
        llmService.conversationStore = conversationStore
        geminiLiveSession.nativeToolRouter = nativeToolRouter

        // Medical export share sheet — triggered by agent tool
        NotificationCenter.default.addObserver(forName: .medicalExportShareRequest, object: nil, queue: .main) { [weak self] note in
            guard let url = note.userInfo?["url"] as? URL else { return }
            Task { @MainActor in
                self?.pendingShareItem = ShareItem(items: [url])
            }
        }

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
        if Config.agentModeEnabled {
            agentScheduler.start()
        }

        setupServiceCallbacks()

        // Defer Wearables.shared calls until after onboarding (requires configure() first)
        if Config.hasCompletedOnboarding {
            observeGlassesConnection()
            autoConnectGlasses()
            startPermissionRequiringServices()
        }

        // Start proactive calendar alerts — speaks through TTS when events are imminent
        proactiveAlerts.onAlert = { [weak self] message, urgency in
            guard let self else { return }
            Task {
                await self.speechService.speak(message, urgency: urgency)
            }
        }
        proactiveAlerts.onMeetingPlaybook = { [weak self] title, notes, steps in
            guard let self else { return }
            let pbSteps = steps.map { PlaybookStep(title: $0) }
            let playbook = Playbook(name: title, icon: "person.3", steps: pbSteps, referenceText: notes)
            self.playbookStore.add(playbook)
            // Auto-start the meeting playbook
            _ = self.playbookStore.startPlaybook(playbook.id)
            Task {
                await self.speechService.speak("I've loaded the agenda for \(title) with \(steps.count) items. Say 'next' to advance through the agenda.")
            }
        }
        proactiveAlerts.start()

        // Configure Live Coach (Plan C) with this AppState's services so the live_coach tool can run.
        LiveCoachService.shared.configure(camera: cameraService, llm: llmService, tts: speechService)

        // Configure Navigation Assist (Plan J) similarly.
        NavigationAssistService.shared.configure(camera: cameraService, llm: llmService, tts: speechService)

        // Field Assist Phase 5 (Plan K2): expert stream bridge for escalations. Transport
        // (MJPEG / WebRTC) is selected in Settings; MJPEG is the working default.
        EscalationCoordinator.shared.bridge = ExpertStreamBridge(
            streamer: webRTCStreaming, framePublisher: cameraService.framePublisher)

        // Plan M3: hand the audio session to a live expert call (pause TTS + wake word).
        ExpertCallAudioCoordinator.shared.control = AppExpertCallAudioControl(
            wakeWord: wakeWordService, tts: speechService)

        // MCP Glasses server (Plan E, dev-only) — configure and start if both gates are on.
        MCPGlassesServer.shared.configure(camera: cameraService, tts: speechService)
        MCPGlassesServer.shared.startIfEnabled()

        // Pre-fetch Home Assistant entity cache for fuzzy matching
        Task { await HomeAssistantEntityCache.shared.refreshIfNeeded() }

        // Wire geofence alerts — speak via TTS when entering/leaving a region
        if let geofenceTool = nativeToolRegistry.tool(named: "geofence") as? GeofenceTool {
            geofenceTool.onAlert = { [weak self] message, urgency in
                guard let self else { return }
                Task {
                    await self.speechService.speak(message, urgency: urgency)
                }
            }
            geofenceTool.restoreGeofences()
        }

        // OpenClaw WebSocket — triage notifications through the agent before speaking
        openClawEventClient.onNotification = { [weak self] message in
            guard let self else { return }
            Task { @MainActor in
                await self.triageOpenClawNotification(message)
            }
        }
        // Sync gateway memories when OpenClaw connects
        openClawBridge.onGatewayConnected = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                await self.userMemory.syncFromGateway()
            }
        }

        // Streaming TTS — speak partial gateway results as they arrive
        openClawBridge.onStreamChunk = { [weak self] chunk in
            guard let self else { return }
            Task { @MainActor in
                // Append to visible response and queue for speech
                self.lastResponse += chunk
                await self.speechService.speakStreaming(chunk)
            }
        }

        if Config.isOpenClawConfigured {
            openClawEventClient.connect()
            Task { await openClawBridge.checkConnection() }
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
                backgroundVoice.endBackgroundSession()
                await cameraService.tearDown()
            case .openaiRealtime:
                openAIRealtimeSession.stopSession()
                backgroundVoice.endBackgroundSession()
                await cameraService.tearDown()
            }

            // Brief delay for audio session to release
            try? await Task.sleep(nanoseconds: 500_000_000)

            // Start new mode
            switch mode {
            case .direct:
                try? await wakeWordService.startListening()
            case .geminiLive, .openaiRealtime:
                // Start background voice session to keep audio alive when backgrounded
                backgroundVoice.startBackgroundSession()
                // Start camera streaming so frames are available when session starts
                do {
                    try await cameraService.startStreaming()
                } catch {
                    NSLog("[App] Camera streaming failed to start: %@", error.localizedDescription)
                }
            }
        }
    }

    /// Start services that require system permissions (Bluetooth, Location, Mic, HomeKit).
    /// Called after onboarding completes, or at init if onboarding is already done.
    func startPermissionRequiringServices() {
        // Start glasses observers (requires Wearables.configure() first)
        glassesService.startObserving()
        observeGlassesConnection()
        autoConnectGlasses()

        // Mode-specific auto-start (mic permission)
        if currentMode == .direct {
            autoStartListening()
        } else if currentMode.isRealtime {
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
        HomeKitTool.prepareShared()
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
                // Assistive Mode (A3) owns the camera + LLM loop while active — suppress the
                // normal wake-word turn so the two pipelines don't contend.
                guard !AssistiveModeService.shared.isActive else {
                    print("🧭 Wake word ignored - Assistive Mode active")
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

        // Voice-activity barge-in: user starts speaking during TTS → stop and process new query
        wakeWordService.onBargeIn = { [weak self] bargeInText in
            Task { @MainActor in
                self?.handleBargeIn(bargeInText)
            }
        }

        wakeWordService.onBluetoothDisconnected = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.isConnected {
                    self.isConnected = false
                    NSLog("[Privacy] Bluetooth audio lost — marking glasses disconnected")
                }
            }
        }

        // Glasses in case: sustained silence → stop mic, start auto-sleep timer
        wakeWordService.onSilenceDetected = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.glassesIdle = true
                self.wakeWordService.stopListening()
                self.isListening = false
                NSLog("[Privacy] Glasses idle (in case?) — mic off. Will restart on BT route change.")

                // Start auto-sleep countdown
                self.startAutoSleepTimer()
            }
        }

        // Glasses back out of case: audio resumes → clear idle, cancel auto-sleep
        wakeWordService.onAudioResumed = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.cancelAutoSleepTimer()
                self.glassesIdle = false
                NSLog("[Privacy] Glasses active again — resuming")
            }
        }

        // Bluetooth reconnect (glasses powered back on) → clear idle, cancel auto-sleep
        wakeWordService.onBluetoothReconnected = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.cancelAutoSleepTimer()
                self.glassesIdle = false
                NSLog("[Privacy] Bluetooth reconnected — clearing idle state")
            }
        }

        transcriptionService.onTranscriptionComplete = { [weak self] text in
            Task { @MainActor in
                guard let self = self else { return }
                // While Assistive Mode (A3) is active it owns the loop — feed the transcript to bias
                // Scene vs Social routing instead of starting a normal turn.
                if AssistiveModeService.shared.isActive {
                    AssistiveModeService.shared.noteTranscription(text)
                    return
                }
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
        // Monitor Bluetooth audio route changes independently of WakeWordService.
        // This catches disconnects when in realtime mode or silent mode.
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
            let route = AVAudioSession.sharedInstance().currentRoute
            let hasBluetooth = route.outputs.contains { $0.portType == .bluetoothA2DP || $0.portType == .bluetoothHFP || $0.portType == .bluetoothLE }
            if !hasBluetooth {
                // Stop audio immediately on the main thread before it can reroute to phone speaker.
                // The isConnected didSet also calls stopSpeaking() but goes via async Task — too late.
                MainActor.assumeIsolated {
                    self?.speechService.stopSpeaking()
                }
                Task { @MainActor in
                    guard let self, self.isConnected else { return }
                    self.isConnected = false
                    NSLog("[Privacy] Bluetooth audio route lost — marking glasses disconnected")
                }
            }
        }

        // Monitor devices list
        let deviceToken = Wearables.shared.addDevicesListener { [weak self] deviceIds in
            Task { @MainActor in
                guard let self else { return }
                let now = Date()
                let fmt = DateFormatter()
                fmt.dateFormat = "HH:mm:ss.SSS"
                print("📋 Devices changed: \(deviceIds) at \(fmt.string(from: now))")
                self.addDebugEvent("Devices changed: \(deviceIds.count) at \(fmt.string(from: now))")
                if !deviceIds.isEmpty {
                    let wasDisconnected = !self.isConnected
                    self.hasEverRegistered = true
                    self.isConnected = true

                    // Deliver queued agent notifications on reconnect
                    if wasDisconnected && Config.agentModeEnabled {
                        // Delay to let audio session stabilize after Bluetooth reconnect
                        Task {
                            try? await Task.sleep(nanoseconds: 3_000_000_000)
                            self.agentNotificationQueue.onGlassesReconnected()
                        }
                    }
                } else if self.isConnected {
                    // Glasses powered off or Bluetooth disconnected
                    self.isConnected = false
                    NSLog("[Glasses] Device list empty — glasses disconnected")
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

                    // Pre-request Meta camera permission so it's ready for first photo
                    if !self.cameraService.permissionGranted {
                        Task {
                            try? await self.cameraService.ensurePermission()
                        }
                    }
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

            // Don't auto-start in silent mode — saves battery, user uses tap-to-talk
            if Config.silentMode {
                print("🔇 Silent mode — skipping wake word auto-start (battery saver)")
                return
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

    /// Handle voice-activity barge-in: user started speaking during TTS.
    /// Stop the current response and process the barge-in text as a new query.
    func handleBargeIn(_ bargeInText: String) {
        print("⚡ Barge-in: '\(bargeInText)' — stopping TTS and processing")
        speechService.stopSpeaking()
        currentLLMTask?.cancel()
        currentLLMTask = nil
        isProcessing = false
        speechService.stopThinkingSound()

        guard inConversation else {
            Task { await returnToWakeWord() }
            return
        }

        // Feed the barge-in text directly into the conversation pipeline
        // handleTranscription handles conversation store, LLM call, etc.
        Task {
            await handleTranscription(bargeInText)
        }
    }

    /// The agent context (soul.md + skills.md + memory.md) if personality mode is enabled.
    var currentAgentContext: String? {
        Config.agentModeEnabled ? agentDocs.agentContext() : nil
    }

    /// Master listening toggle — stops/starts wake word detection and Live Activity.
    func setListeningEnabled(_ enabled: Bool) {
        listeningEnabled = enabled
        Config.setListeningEnabled(enabled)

        if enabled {
            // Restart wake word detection and Live Activity
            liveActivityManager.start(glassesName: glassesService.deviceName ?? "OpenGlasses")
            if isConnected {
                Task { try? await wakeWordService.startListening() }
            }
            NSLog("[Listening] Enabled")
        } else {
            // Stop everything: wake word, transcription, TTS, Live Activity
            wakeWordService.stopListening()
            transcriptionService.stopRecording()
            speechService.stopSpeaking()
            liveActivityManager.end()
            // Release any audio pause held by an in-flight conversation so Music/Podcasts resume.
            wakeWordService.forceResumeOtherAudio()
            isListening = false
            NSLog("[Listening] Disabled")
        }
    }

    /// Push current state to the Live Activity on Lock Screen / Dynamic Island.
    func updateLiveActivity() {
        liveActivityManager.update(
            isConnected: isConnected,
            isListening: isListening,
            isSpeaking: speechService.isSpeaking,
            isProcessing: isProcessing,
            lastResponse: lastResponse,
            deviceName: glassesService.deviceName,
            batteryLevel: glassesService.batteryLevel
        )
    }

    /// Cancel current LLM processing or TTS playback and return to wake word listening.
    func cancelCurrentResponse() {
        print("🛑 User cancelled response")
        currentLLMTask?.cancel()
        currentLLMTask = nil
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

    // MARK: - Phone-camera fallback (photo actions when glasses are off)

    /// Non-nil while the phone-camera fallback sheet should be presented.
    @Published var phoneCameraRequest: PhoneCameraRequest?

    private func presentPhoneCamera(prompt: String, userLog: String) {
        phoneCameraRequest = PhoneCameraRequest(prompt: prompt, userLog: userLog)
    }

    /// Called by the phone-camera sheet once a still is captured: save it, then run the
    /// same image+prompt → LLM → speak flow the glasses photo path uses.
    func handlePhoneCapture(_ data: Data) {
        guard let req = phoneCameraRequest else { return }
        phoneCameraRequest = nil
        cameraService.saveToPhotoLibrary(data)
        Task { await sendPhotoToLLM(imageData: data, prompt: req.prompt, userLog: req.userLog) }
    }

    private func sendPhotoToLLM(imageData: Data, prompt: String, userLog: String) async {
        isProcessing = true
        speechService.startThinkingSound()
        do {
            let rawResponse = try await llmService.sendMessage(
                prompt,
                locationContext: locationService.locationContext,
                imageData: imageData,
                memoryContext: Config.userMemoryEnabled ? userMemory.systemPromptContext() : nil
            )
            let response = Config.userMemoryEnabled ? userMemory.parseAndExecuteCommands(in: rawResponse) : rawResponse
            lastResponse = response
            if Config.conversationPersistenceEnabled {
                conversationStore.appendMessage(role: "user", content: userLog)
                conversationStore.appendMessage(role: "assistant", content: response)
            }
            isProcessing = false
            speechService.stopThinkingSound()
            await speechService.speak(response)
        } catch {
            isProcessing = false
            speechService.stopThinkingSound()
            errorMessage = error.localizedDescription
        }
    }

    /// Capture a photo and send it to the LLM with a custom prompt.
    func capturePhotoAndSend(prompt: String) async {
        guard isConnected else {
            // No glasses — fall back to the phone camera (live preview to aim + frame).
            presentPhoneCamera(prompt: prompt, userLog: "[Phone photo] \(prompt)")
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

    /// Toggle Assistive Mode (A3). Wires the shared service to this AppState's camera/LLM/TTS.
    func toggleAssistiveMode() {
        AssistiveModeService.shared.toggle(camera: cameraService, llm: llmService, tts: speechService)
    }

    /// Start the dev-only MCP glasses server (Plan E) with this AppState's services.
    func startMCPServer() {
        MCPGlassesServer.shared.configure(camera: cameraService, tts: speechService)
        MCPGlassesServer.shared.start()
    }

    /// Capture a photo from the glasses camera and present the share sheet.
    /// Capture a photo and send it to the LLM for analysis (manual camera button).
    /// Execute a QuickAction by type — used by widget deep links and overlay.
    func executeQuickAction(_ action: QuickAction) async {
        switch action.type {
        case .prompt:
            guard let text = action.promptText, !text.isEmpty else { return }
            speechService.startThinkingSound()
            do {
                let response = try await llmService.sendMessage(
                    text,
                    locationContext: locationService.locationContext,
                    memoryContext: Config.userMemoryEnabled ? userMemory.systemPromptContext() : nil
                )
                lastResponse = response
                await speechService.speak(response)
            } catch {
                speechService.stopThinkingSound()
                errorMessage = error.localizedDescription
            }
        case .photo:
            await captureAndAnalyzePhoto()
        case .photoThenPrompt:
            let prompt = action.promptText ?? "Describe what you see."
            await capturePhotoAndSend(prompt: prompt)
        case .homeAssistant:
            guard let service = action.haService else { return }
            var command = "Call Home Assistant service '\(service)'"
            if let entity = action.haEntityId, entity != "all" {
                command += " on entity '\(entity)'"
            }
            if let data = action.haData, !data.isEmpty {
                command += " with data: \(data)"
            }
            speechService.startThinkingSound()
            do {
                let response = try await llmService.sendMessage(command, locationContext: nil, memoryContext: nil)
                lastResponse = response
                await speechService.speak(response)
            } catch {
                speechService.stopThinkingSound()
                errorMessage = error.localizedDescription
            }
        case .siriShortcut:
            guard let name = action.shortcutName, !name.isEmpty else { return }
            if let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
               let url = URL(string: "shortcuts://run-shortcut?name=\(encoded)") {
                await UIApplication.shared.open(url)
            }
        case .openApp:
            guard let scheme = action.urlScheme, let url = URL(string: scheme) else { return }
            await UIApplication.shared.open(url)
        }
    }

    func captureAndAnalyzePhoto() async {
        guard isConnected else {
            // No glasses — fall back to the phone camera.
            presentPhoneCamera(prompt: "Describe what you see in this image.", userLog: "[Phone photo]")
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
    /// Capture a photo silently — no LLM call, no TTS, transcription keeps running.
    /// Saves to Documents/Photos/ and injects a timestamped note into the ambient
    /// caption history so the meeting transcript references the photo at the right moment.
    func capturePhotoSilently() async {
        guard isConnected else { return }
        do {
            // Start camera briefly if needed (audio recording doesn't use it)
            let wasStreaming = cameraService.isStreaming
            if !wasStreaming {
                try await cameraService.startStreaming()
                // Give camera a moment to warm up before capturing
                try? await Task.sleep(nanoseconds: 500_000_000)
            }

            let photoData = try await cameraService.capturePhoto()

            if currentMode == .direct {
                cameraService.restoreAudioForWakeWord()
            }
            // Stop camera again if we only started it for the capture
            if !wasStreaming {
                await cameraService.stopStreaming()
            }

            // Save to Documents/Photos/ with a timestamped name
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let dir = docs.appendingPathComponent("Photos", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            let filename = "OG_\(formatter.string(from: Date())).jpg"
            let fileURL = dir.appendingPathComponent(filename)
            try? photoData.write(to: fileURL)

            // Insert a timestamped note into the caption stream so the transcript records it
            let timeStr = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
            ambientCaptions.insertVisualNote("Photo captured at \(timeStr) — \(filename)")

            // Soft bing through the glasses + taptic on the watch
            speechService.playPhotoTone()
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.success)
            NSLog("[SilentPhoto] Saved to %@", filename)
        } catch {
            NSLog("[SilentPhoto] Failed: %@", error.localizedDescription)
        }
    }

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
                if !cameraService.isStreaming {
                    try await cameraService.startStreaming()
                }
                let frameSize = cameraService.latestFrame?.size ?? CGSize(width: 720, height: 1280)
                let bitrate = max(Config.recordingBitrate, 4_000_000)
                try videoRecorder.startRecording(
                    from: cameraService.framePublisher,
                    bitrate: bitrate,
                    outputSize: frameSize
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

    // MARK: - Background Resource Optimization

    /// Whether we applied background optimizations that need reverting.
    private var isBackgroundOptimized = false

    /// Optimize resource allocation when the app moves to background during active streaming.
    /// Reduces non-essential work to prioritize the encoding pipeline.
    func optimizeForBackground() {
        let isStreaming = broadcastService.isBroadcasting || webRTCStreaming.isStreaming
        guard isStreaming else {
            print("📱 Background: no active streams — normal background behavior")
            return
        }

        isBackgroundOptimized = true
        print("📱 Background: active stream detected — optimizing for encoding")

        // Pause proactive alerts (non-essential background work)
        proactiveAlerts.pauseAlerts()

        // Reduce face recognition frequency if running (CPU-intensive Vision work)
        faceRecognition.reduceFrequency()

        // Suspend privacy filter (Gaussian blur is GPU-intensive, not visible when backgrounded)
        privacyFilter.suspend()

        // Log the optimization for diagnostics
        addDebugEvent("Background optimization: streaming priority mode enabled")
    }

    /// Restore normal resource allocation when the app returns to foreground.
    func restoreFromBackground() {
        guard isBackgroundOptimized else { return }
        isBackgroundOptimized = false
        print("📱 Foreground: restoring normal resource allocation")

        proactiveAlerts.resumeAlerts()
        faceRecognition.restoreFrequency()
        privacyFilter.resume()

        addDebugEvent("Background optimization: normal mode restored")
    }

    /// Start listening directly — no wake word needed.
    /// Called from Action Button intent or manual mic button.
    /// Transcription will check for persona names in the spoken text.
    func startDirectTranscription() {
        print("🎤 Action Button: starting direct transcription (no wake word)")
        Task {
            // Configure audio (uses glasses mic if connected, phone mic otherwise)
            wakeWordService.configureAudioSession()
            // manual: true — this is an explicit user trigger (Action Button / Siri / tap),
            // so the reply speaks through the phone speaker even with no glasses connected.
            await handleWakeWordDetected(manual: true)
        }
    }

    /// End the current voice session immediately — backs the in-app "Tap to stop"
    /// button and any explicit Push-to-Talk end. Stops the recorder (which otherwise
    /// only ends on silence) and resets conversation state.
    func endListeningSession() {
        transcriptionService.stopRecording()
        Task { await returnToWakeWord() }
    }

    /// Whether the current conversation was started by an explicit user tap (not wake word).
    /// When true, TTS speaks through the phone speaker even without glasses connected.
    private(set) var manuallyTriggered: Bool = false

    func handleWakeWordDetected(manual: Bool = false) async {
        print("🎤 \(manual ? "Tap-to-talk" : "Wake word") detected! Starting conversation...")
        manuallyTriggered = manual
        inConversation = true

        // Ensure audio session + engine are alive BEFORE marking ourselves as listening.
        // Tap-to-talk calls stopListening() first (engine = nil), and startListening()
        // bails on `guard !isListening`, so setting isListening early would leave the shared
        // engine dead and force TranscriptionService onto a fragile fallback engine.
        wakeWordService.configureAudioSession()
        try? await wakeWordService.ensureAudioEngineRunning()
        isListening = true

        // Snapshot what's playing before pausing it
        nowPlayingAtStart = NowPlayingSnapshot.current()

        // Pause podcasts/music so the user can speak clearly (skips if call in progress)
        wakeWordService.pauseOtherAudio()

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

    // MARK: - Smart Camera Activation

    /// Timestamp of the last smart camera activation (for cooldown window).
    private var lastSmartCameraActivation: Date?

    /// Determine image data for a query using smart camera logic:
    /// 1. If camera is already streaming, reuse the latest frame (existing behavior).
    /// 2. If smart camera is enabled and query is vision-related, activate camera and capture.
    /// 3. If preset has "always" camera behavior, keep camera on.
    /// 4. Otherwise, no image.
    private func smartCameraImageData(for query: String) async -> Data? {
        guard Config.activeModel?.visionEnabled == true else { return nil }

        // Already have a live frame? Use it (cheapest path).
        if let existing = currentVisionFrameDataIfAvailable() {
            lastSmartCameraActivation = Date()
            return existing
        }

        // Check camera behavior from active preset
        let cameraBehavior = Config.activePresetCameraBehavior

        // "always" mode: try to keep camera on and capture
        if cameraBehavior == "always" {
            return await smartCameraCapture(reason: "always-on mode")
        }

        // Smart camera detection
        guard Config.smartCameraEnabled || cameraBehavior == "smart" else { return nil }

        // Within cooldown window from last vision query? Auto-activate for follow-ups.
        if let lastActivation = lastSmartCameraActivation,
           Date().timeIntervalSince(lastActivation) < Config.smartCameraCooldown {
            return await smartCameraCapture(reason: "cooldown follow-up")
        }

        // Classify the query
        let intent = VisionIntentDetector.classify(query)
        guard intent == .vision else {
            return nil
        }

        lastSmartCameraActivation = Date()
        return await smartCameraCapture(reason: "vision query detected")
    }

    /// Attempt to activate the camera and capture a frame for smart camera.
    /// Returns nil on failure (doesn't crash the flow — text-only fallback).
    private func smartCameraCapture(reason: String) async -> Data? {
        print("📷 Smart Camera: activating (\(reason))")

        // If camera is already streaming, just grab the frame
        if cameraService.isStreaming, let frame = cameraService.latestFrame {
            return frame.jpegData(compressionQuality: Config.geminiLiveVideoJPEGQuality)
        }

        // Try to start streaming and capture
        do {
            try await cameraService.startStreaming()
            // Brief wait for first frame
            try await Task.sleep(nanoseconds: 500_000_000)
            if let frame = cameraService.latestFrame {
                print("📷 Smart Camera: captured frame")
                return frame.jpegData(compressionQuality: Config.geminiLiveVideoJPEGQuality)
            }
            // Try photo capture as fallback
            let photoData = try await cameraService.capturePhoto()
            cameraService.restoreAudioForWakeWord()
            print("📷 Smart Camera: captured photo")
            return photoData
        } catch {
            print("📷 Smart Camera: capture failed — \(error.localizedDescription)")
            return nil
        }
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
            // Start capture immediately — play the shutter tone, no spoken "taking a picture"
            speechService.playAcknowledgmentTone()
            speechService.startThinkingSound()

            currentLLMTask = Task {
                do {
                    // Capture and send to LLM concurrently — no extra round-trip speech
                    let photoData = try await cameraService.capturePhoto()
                    try Task.checkCancellation()
                    // Restore audio for wake word after camera capture (camera reconfigures for Bluetooth)
                    cameraService.restoreAudioForWakeWord()
                    cameraService.saveToPhotoLibrary(photoData)
                    print("📸 Photo captured, sending to LLM with prompt: \(query)")

                    let rawResponse = try await llmService.sendMessage(
                        query,
                        locationContext: locationService.locationContext,
                        imageData: photoData,
                        memoryContext: Config.userMemoryEnabled ? userMemory.systemPromptContext() : nil
                    )
                    try Task.checkCancellation()
                    let response = Config.userMemoryEnabled ? userMemory.parseAndExecuteCommands(in: rawResponse) : rawResponse
                    lastResponse = response
                    if Config.conversationPersistenceEnabled {
                        conversationStore.appendMessage(role: "assistant", content: response)
                    }
                    print("🤖 \(llmService.activeModelName) (vision): \(response)")

                    // If an audio or video recording is active, inject the description
                    // into the caption history so the meeting assistant has visual context.
                    if audioRecorder.isRecording || videoRecorder.isRecording {
                        ambientCaptions.insertVisualNote(response)
                    }

                    // Start wake word listener during TTS so user can say "stop"
                    startStopListener()
                    await speechService.speak(response)
                    stopStopListener()

                } catch is CancellationError {
                    print("🛑 Photo/LLM task cancelled")
                } catch {
                    cameraService.restoreAudioForWakeWord()
                    print("📸 Photo capture failed: \(error)")
                    lastResponse = "Photo failed: \(error.localizedDescription)"
                    await speechService.speak("Sorry, I couldn't take a photo or process the image. \(error.localizedDescription)")
                }
                isProcessing = false
                speechService.stopThinkingSound()
                if inConversation {
                    // Ensure audio engine is alive after TTS playback
                    try? await wakeWordService.ensureAudioEngineRunning()
                    isListening = true
                    transcriptionService.startRecording()
                } else {
                    await returnToWakeWord()
                }
            }
            return
        }

        // Classify the request before deciding how to handle it
        let turnCount = conversationStore.threads
            .first(where: { $0.id == conversationStore.activeThreadId })?
            .messages.filter({ $0.role == "user" }).count ?? 0
        let hasImage = isPhotoCommand(query) // pre-check; smartCamera may override below
        let classification = conversationClassifier.classify(query, hasImage: hasImage, conversationTurnCount: turnCount)
        print("🧭 Classified: complexity=\(String(format: "%.2f", classification.complexity)) tier=\(classification.modelTier.rawValue) direct=\(classification.directToolCall?.toolName ?? "none")")

        // Tier 0: Direct tool call — skip LLM entirely
        if let directCall = classification.directToolCall,
           let router = llmService.nativeToolRouter {
            isProcessing = true
            do {
                let result = try await router.registry.executeTool(
                    name: directCall.toolName,
                    arguments: directCall.arguments
                )
                lastResponse = result
                print("⚡ Direct tool call: \(directCall.toolName) → \(result)")

                if Config.conversationPersistenceEnabled {
                    conversationStore.appendMessage(role: "assistant", content: result)
                }

                startStopListener()
                await speechService.speak(result)
                stopStopListener()
            } catch {
                // Fall through to normal LLM path if direct call fails
                print("⚠️ Direct tool call failed, falling back to LLM: \(error)")
                isProcessing = false
                // Don't return — continue to normal LLM path below
            }

            if isProcessing {
                isProcessing = false
                if inConversation {
                    try? await wakeWordService.ensureAudioEngineRunning()
                    isListening = true
                    transcriptionService.startRecording()
                } else {
                    await returnToWakeWord()
                }
                return
            }
        }

        // Tier 2: Model selection — temporarily switch to the recommended tier if available and enabled
        var originalModelId: String?
        var useLocalAgent = false

        // Route fast-tier queries to on-device Gemma 4 when agentic mode is on + model downloaded
        if classification.modelTier == .fast,
           Config.agentModeEnabled,
           Config.agentModelDownloaded,
           !isPhotoCommand(query) {
            useLocalAgent = true
            print("🧠 Routing to local agent (fast tier, agentic mode)")
        } else if Config.autoModelRoutingEnabled,
           let tierModel = Config.modelForTier(classification.modelTier),
           tierModel.id != Config.activeModelId {
            originalModelId = Config.activeModelId
            Config.setActiveModelId(tierModel.id)
            llmService.refreshActiveModel()
            print("🧭 Model routed: \(classification.modelTier.rawValue) → \(tierModel.name)")
        }

        // Normal message — send to LLM (with Tier 1 prompt trimming via sections)
        isProcessing = true
        speechService.startThinkingSound()

        do {
            let rawResponse: String
            if useLocalAgent {
                // Fast path: on-device Gemma 4 agent
                rawResponse = try await llmService.sendViaLocalAgent(
                    query,
                    locationContext: classification.relevantSections.contains(.location) ? locationService.locationContext : nil,
                    memoryContext: Config.userMemoryEnabled ? userMemory.systemPromptContext() : nil
                )
            } else {
                // Standard path: cloud LLM
                let imageData = await smartCameraImageData(for: query)
                rawResponse = try await llmService.sendMessage(
                    query,
                    locationContext: classification.relevantSections.contains(.location) ? locationService.locationContext : nil,
                    imageData: imageData,
                    memoryContext: Config.userMemoryEnabled ? userMemory.systemPromptContext() : nil,
                    playbookContext: classification.relevantSections.contains(.playbook) ? playbookStore.playbookContext() : nil,
                    nowPlayingContext: nowPlayingAtStart?.promptContext,
                    promptSections: classification.relevantSections
                )
            }
            nowPlayingAtStart = nil  // consumed for this turn

            // Parse and execute memory commands from the response
            let response: String
            if Config.userMemoryEnabled {
                response = userMemory.parseAndExecuteCommands(in: rawResponse)

                // Periodic nudge: after N turns, inject a hidden review prompt
                // into the LLM history so the next response considers what to remember
                if userMemory.incrementTurnAndCheckNudge() {
                    llmService.injectSystemMessage(SemanticMemoryStore.nudgePrompt)
                }
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

        // Restore original model if we switched for this request
        if let originalId = originalModelId {
            Config.setActiveModelId(originalId)
            llmService.refreshActiveModel()
        }

        // After responding, stay in conversation — listen for follow-up
        isProcessing = false
        speechService.stopThinkingSound()
        if inConversation {
            print("💬 Continuing conversation — listening for follow-up...")
            // Ensure audio engine is alive after TTS playback (may have been interrupted)
            try? await wakeWordService.ensureAudioEngineRunning()
            isListening = true
            transcriptionService.startRecording()
        } else {
            await returnToWakeWord()
        }
    }

    // MARK: - Text Message Input

    /// Send a typed text message (with optional image) to the LLM — same pipeline as voice.
    func sendTextMessage(_ text: String, imageData: Data? = nil) async {
        guard !isProcessing else { return }
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        currentTranscription = query
        isListening = false
        errorMessage = nil

        // Track in conversation store
        if Config.conversationPersistenceEnabled {
            if conversationStore.activeThreadId == nil {
                conversationStore.startThread(mode: currentMode.rawValue)
            }
            conversationStore.appendMessage(role: "user", content: query, imageAttached: imageData != nil)
        }

        isProcessing = true
        speechService.startThinkingSound()

        do {
            // Use provided image, or fall back to smart camera if no image attached
            let image: Data?
            if let imageData {
                image = imageData
            } else {
                image = await smartCameraImageData(for: query)
            }
            let rawResponse = try await llmService.sendMessage(
                query,
                locationContext: locationService.locationContext,
                imageData: image,
                memoryContext: Config.userMemoryEnabled ? userMemory.systemPromptContext() : nil,
                playbookContext: playbookStore.playbookContext()
            )

            let response = Config.userMemoryEnabled ? userMemory.parseAndExecuteCommands(in: rawResponse) : rawResponse
            lastResponse = response

            if Config.conversationPersistenceEnabled {
                conversationStore.appendMessage(role: "assistant", content: response)
            }

            // Speak the response (user can still say "stop")
            startStopListener()
            await speechService.speak(response)
            stopStopListener()
        } catch {
            errorMessage = "Failed to get response: \(error.localizedDescription)"
            await speechService.speak("Sorry, I encountered an error.")
        }

        isProcessing = false
        speechService.stopThinkingSound()
    }

    /// Start wake word listener in "stop detection" mode during TTS playback.
    /// With .playAndRecord audio session (Bluetooth HFP), mic works during TTS.
    private func startStopListener() {
        wakeWordService.listenForStop = true
        Task {
            do {
                try await wakeWordService.startListening()
                print("🎤 Stop listener active during TTS")
            } catch {
                print("⚠️ Could not start stop listener: \(error)")
            }
        }
    }

    /// Stop the stop-detection listener before resuming normal flow
    /// Uses pauseRecognition to keep the engine alive
    private func stopStopListener() {
        wakeWordService.listenForStop = false
        wakeWordService.pauseRecognitionPublic()
    }

    // MARK: - OpenClaw Notification Triage

    /// Assess an incoming OpenClaw notification through the agent.
    /// The agent decides: summarize it, query OpenClaw for clarification, or skip.
    func triageOpenClawNotification(_ rawMessage: String) async {
        let trimmed = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count > 5 else { return }

        NSLog("[OpenClaw] Triaging notification (%d chars): %@",
              trimmed.count, String(trimmed.prefix(120)))

        let triagePrompt = """
        An automated task from OpenClaw (a background service) produced this output:

        ---
        \(trimmed.prefix(1500))
        ---

        You have four options:
        1. SUMMARY: If this is useful and actionable, summarize in 2-3 chatty spoken sentences. \
        Start with "From OpenClaw:" so the user knows the source. Keep it short and natural.
        2. CLARIFY: If the output is confusing or incomplete but looks like it was trying to do \
        something useful, write a question to send back to OpenClaw for clarification. \
        Start with "CLARIFY:" followed by your question.
        3. FIX: If the output shows an error or the task failed/broke, send a request back to \
        OpenClaw to investigate and fix the issue. Start with "FIX:" followed by what to fix.
        4. SKIP: If the task had nothing to report ("no results", "nothing to do", idle status) \
        or the output is completely useless gibberish. Stay quiet — don't bother the user.

        Quality bar: Only speak to the user if you have something genuinely worth their attention. \
        Idle reports, empty results, and "task completed with no output" are all SKIP.

        Reply with one of: your spoken summary, "CLARIFY: question", "FIX: instruction", or "SKIP".
        """

        do {
            let response = try await llmService.sendMessage(
                triagePrompt,
                memoryContext: Config.userMemoryEnabled ? userMemory.systemPromptContext() : nil,
                agentContext: currentAgentContext
            )

            let cleaned = response.trimmingCharacters(in: .whitespacesAndNewlines)

            if cleaned.uppercased() == "SKIP" || cleaned.uppercased().hasPrefix("SKIP") {
                NSLog("[OpenClaw] Agent triaged as skip")
                return
            }

            if cleaned.uppercased().hasPrefix("CLARIFY:") {
                let question = String(cleaned.dropFirst(8)).trimmingCharacters(in: .whitespacesAndNewlines)
                NSLog("[OpenClaw] Agent requesting clarification: %@", question)
                await clarifyWithOpenClaw(originalMessage: trimmed, question: question)
                return
            }

            if cleaned.uppercased().hasPrefix("FIX:") {
                let instruction = String(cleaned.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
                NSLog("[OpenClaw] Agent requesting fix: %@", instruction)
                await requestOpenClawFix(originalMessage: trimmed, instruction: instruction)
                return
            }

            // Agent summarized — deliver it
            lastResponse = cleaned
            agentNotificationQueue.enqueue(
                message: cleaned,
                source: "OpenClaw",
                priority: .medium
            )
        } catch {
            NSLog("[OpenClaw] Triage failed: %@ — dropping", error.localizedDescription)
        }
    }

    /// Query OpenClaw for clarification on a confusing notification, then re-triage.
    private func clarifyWithOpenClaw(originalMessage: String, question: String) async {
        guard Config.isOpenClawConfigured else {
            NSLog("[OpenClaw] Can't clarify — OpenClaw not configured")
            return
        }

        let clarifyPrompt = """
        A background task produced this output, and I need clarification:

        Original output: \(originalMessage.prefix(500))

        My question: \(question)

        Please explain briefly what this task was doing and what the result means for the user.
        """

        let result = await openClawBridge.delegateTask(task: clarifyPrompt)

        switch result {
        case .success(let clarification):
            NSLog("[OpenClaw] Clarification received: %@", String(clarification.prefix(200)))

            // Now summarize the clarified version for the user
            let summaryPrompt = """
            OpenClaw originally sent this notification:
            \(originalMessage.prefix(500))

            When asked for clarification, it explained:
            \(clarification.prefix(500))

            Summarize this for the user in 2-3 chatty spoken sentences. \
            Start with "From OpenClaw:" so they know the source. Keep it natural and brief.
            """

            do {
                let summary = try await llmService.sendMessage(
                    summaryPrompt,
                    memoryContext: Config.userMemoryEnabled ? userMemory.systemPromptContext() : nil,
                    agentContext: currentAgentContext
                )
                let cleaned = summary.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleaned.uppercased().hasPrefix("SKIP") else { return }

                lastResponse = cleaned
                agentNotificationQueue.enqueue(
                    message: cleaned,
                    source: "OpenClaw",
                    priority: .medium
                )
            } catch {
                NSLog("[OpenClaw] Summary after clarification failed: %@", error.localizedDescription)
            }

        case .failure(let error):
            NSLog("[OpenClaw] Clarification request failed: %@", error)
        }
    }

    /// Send a fix request to OpenClaw when a task is broken, then optionally notify user.
    private func requestOpenClawFix(originalMessage: String, instruction: String) async {
        guard Config.isOpenClawConfigured else { return }

        let fixPrompt = """
        A background task produced an error or broken output. Please investigate and fix if possible.

        Original output: \(originalMessage.prefix(500))

        Issue to fix: \(instruction)

        Try to resolve the issue. If you can fix it, explain what you did briefly. \
        If you can't, explain why.
        """

        let result = await openClawBridge.delegateTask(task: fixPrompt)

        switch result {
        case .success(let response):
            NSLog("[OpenClaw] Fix response: %@", String(response.prefix(200)))
            // Only tell the user if the fix is noteworthy
            let briefCheck = response.lowercased()
            let isNoteworthy = briefCheck.contains("fixed") ||
                briefCheck.contains("resolved") ||
                briefCheck.contains("updated") ||
                briefCheck.contains("can't") ||
                briefCheck.contains("cannot")
            if isNoteworthy {
                // Re-triage the fix response (single level — won't recurse)
                lastResponse = response
                agentNotificationQueue.enqueue(
                    message: "From OpenClaw: \(String(response.prefix(300)))",
                    source: "OpenClaw fix",
                    priority: .low
                )
            }
        case .failure(let error):
            NSLog("[OpenClaw] Fix request failed: %@", error)
        }
    }

    // MARK: - Quick Disconnect

    // MARK: - Connect & Listen

    /// One-tap reconnect — connect glasses and immediately start listening.
    /// Used by hero capsule, widget, watch, and Dynamic Island reconnect actions.
    func connectAndListen() async {
        guard !isConnected else {
            // Already connected — just start listening
            wakeWordService.stopListening()
            try? await Task.sleep(nanoseconds: 100_000_000)
            await handleWakeWordDetected(manual: true)
            return
        }

        // Connect glasses
        await glassesService.connect()

        // Wait for connection to establish — up to 15s on fresh install (DAT registration
        // can take a while the first time or after re-pairing)
        for _ in 0..<60 {
            if isConnected { break }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        guard isConnected else {
            errorMessage = "Could not connect to glasses"
            return
        }

        // Now start listening
        try? await Task.sleep(nanoseconds: 200_000_000)
        await handleWakeWordDetected(manual: true)
    }

    /// Start auto-sleep countdown. If glasses stay idle for N minutes, disconnect.
    private func startAutoSleepTimer() {
        cancelAutoSleepTimer()
        let minutes = Config.autoSleepMinutes
        guard minutes > 0 else { return }

        autoSleepTask = Task { @MainActor [weak self] in
            let seconds = UInt64(minutes) * 60
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard let self, !Task.isCancelled, self.glassesIdle, self.isConnected else { return }
            NSLog("[AutoSleep] Glasses idle for %d min — disconnecting", minutes)
            self.disconnectGlasses()
        }
        NSLog("[AutoSleep] Timer started: %d minutes", minutes)
    }

    private func cancelAutoSleepTimer() {
        autoSleepTask?.cancel()
        autoSleepTask = nil
    }

    /// Tear down all glasses-dependent services in one tap.
    /// Stops mic, TTS, camera, realtime sessions, and marks glasses disconnected.
    /// OpenClaw bridge and agent tasks continue running server-side.
    func disconnectGlasses() {
        guard isConnected else { return }

        // Stop all active interactions
        speechService.stopSpeaking()
        wakeWordService.stopListening()
        isListening = false
        inConversation = false
        glassesIdle = false

        // Stop realtime sessions
        if geminiLiveSession.isActive { geminiLiveSession.stopSession() }
        if openAIRealtimeSession.isActive { openAIRealtimeSession.stopSession() }

        // Stop camera + recording
        Task { await cameraService.stopStreaming() }
        if videoRecorder.isRecording {
            Task { _ = await videoRecorder.stopRecording() }
        }
        // Audio recording intentionally continues across glasses disconnects —
        // the mic falls back to the phone so the meeting capture keeps going.

        // Stop ambient features that use mic/speakers
        if ambientCaptions.isActive { ambientCaptions.stop() }

        // End conversation thread
        if Config.conversationPersistenceEnabled && conversationStore.activeThreadId != nil {
            conversationStore.endThread()
        }

        // Disconnect the glasses (triggers isConnected didSet cleanup too)
        glassesService.disconnect()

        // Update live activity
        liveActivityManager.end()

        NSLog("[OpenGlasses] Quick disconnect — all glasses services stopped")
    }

    func returnToWakeWord() async {
        // Capture whether we were in a conversation before resetting state.
        // If the user was actively talking, always restart wake word — even in
        // silent mode (silent mode only suppresses the *initial* auto-start).
        let wasInConversation = inConversation

        isListening = false
        inConversation = false
        activePersona = nil
        manuallyTriggered = false
        wakeWordService.listenForStop = false
        // Resume podcasts/music after active listening
        let resumedMedia = nowPlayingAtStart
        nowPlayingAtStart = nil
        wakeWordService.resumeOtherAudio()
        speechService.playDisconnectTone()
        // Announce what's resuming (e.g. "Resuming Hardcore History by Dan Carlin")
        if let media = resumedMedia {
            await speechService.speak("Resuming \(media.displayName).")
        }
        updateLiveActivity()
        // End active conversation thread
        if Config.conversationPersistenceEnabled && conversationStore.activeThreadId != nil {
            conversationStore.endThread()
        }
        // In silent mode, don't restart wake word UNLESS we just finished an
        // active conversation — the user was just talking, so they expect the
        // mic to come back for the next wake word.
        if Config.silentMode && !wasInConversation {
            print("🔇 Silent mode — wake word listener stays off (no active conversation)")
            return
        }
        // Don't restart mic on phone speaker when glasses are disconnected
        if !isConnected {
            print("🔇 Glasses disconnected — wake word listener stays off for privacy")
            return
        }
        if micMuted {
            print("🔇 Mic muted — wake word listener stays off")
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

// MARK: - Now Playing Snapshot

struct NowPlayingSnapshot {
    let title: String?
    let artist: String?
    let albumTitle: String?

    /// Read what's currently playing from MPNowPlayingInfoCenter.
    static func current() -> NowPlayingSnapshot? {
        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo
        guard let info, !info.isEmpty else { return nil }
        let title = info[MPMediaItemPropertyTitle] as? String
        let artist = info[MPMediaItemPropertyArtist] as? String
        let album = info[MPMediaItemPropertyAlbumTitle] as? String
        guard title != nil || artist != nil else { return nil }
        return NowPlayingSnapshot(title: title, artist: artist, albumTitle: album)
    }

    /// One-line description, e.g. "Hardcore History by Dan Carlin" or "Blinding Lights by The Weeknd"
    var displayName: String {
        switch (title, artist) {
        case let (t?, a?): return "\(t) by \(a)"
        case let (t?, nil): return t
        case let (nil, a?): return "something by \(a)"
        default: return "what you were listening to"
        }
    }

    /// Short context string injected into the system prompt.
    var promptContext: String {
        var parts: [String] = []
        if let t = title  { parts.append("title: \"\(t)\"") }
        if let a = artist { parts.append("artist: \"\(a)\"") }
        if let al = albumTitle, al != title { parts.append("album: \"\(al)\"") }
        return "NOW PLAYING (paused when user spoke): \(parts.joined(separator: ", ")). If the user asks about the song, podcast, or what was playing, you already know this."
    }
}
