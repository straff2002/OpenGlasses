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
    Task { @MainActor in
        // Meta AI can deliver a callback at any time, including before anything else has needed
        // the SDK. Configure on demand — without this, handleUrl traps rather than throwing.
        guard WearablesBootstrap.ensureConfigured() else {
            NSLog("[OpenGlasses] [\(source)] Wearables SDK unavailable — dropping URL callback")
            AppStateProvider.shared?.addDebugEvent("Dropped \(source) callback: SDK unavailable")
            return
        }
        do {
            let result = try await Wearables.shared.handleUrl(url)
            NSLog("[OpenGlasses] [\(source)] handleUrl result: \(String(describing: result))")
            AppStateProvider.shared?.addDebugEvent("handleUrl success from \(source): \(String(describing: result))")
        } catch {
            NSLog("[OpenGlasses] [\(source)] handleUrl failed: \(error.localizedDescription)")
            AppStateProvider.shared?.addDebugEvent("handleUrl failed from \(source): \(error.localizedDescription)")
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
        // Move any plaintext provider secrets out of UserDefaults and into the
        // Keychain. Must run before anything reads a secret (AppState, LLM, TTS…).
        Config.migrateSecretsToKeychainIfNeeded()
        // Mint the deep-link trust token before any URL can be delivered, so a first-party link
        // is never rejected because the app hadn't got round to creating one.
        DeepLinkTrust.ensureToken()
        // Configure eagerly once the user is past onboarding, so auto-reconnect and the launch
        // state check behave exactly as before. Everything else goes through
        // WearablesBootstrap.ensureConfigured() on demand, so a user who never reaches here can
        // still connect without trapping — see WearablesBootstrap for the desync this fixes.
        if Config.isPastOnboarding {
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

                // Sideload install confirmations (Plan BX P3) — invisible until a link arrives.
                SkillPackSideloadPromptOverlay(sideload: appState.skillPackSideload)

                // Apple Translation session host (BY P3) — invisible; the framework only hands
                // out sessions through a view, so the on-device tier's session lives here.
                TranslationEngineHost(engine: appState.translationEngine)

                // HIPAA biometric lock overlay
                if isHipaaLocked {
                    BiometricLockView(isLocked: $isHipaaLocked)
                        .transition(.opacity)
                        .zIndex(999)
                }
            }
            .onAppear {
                AppStateProvider.shared = appState
                // Plan BQ: refresh Siri's phrase predictions for the parameterized
                // shortcuts (persona + action catalog) against current runtime data.
                OpenGlassesShortcuts.updateAppShortcutParameters()
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

                    // A custom URL scheme is an open door: any app on the device can call it, with
                    // no prompt and no caller identity. Links that act — capture a frame from the
                    // glasses, open the mic, run a quick action — are honoured only when they carry
                    // the app-group token the first-party widgets stamp on. See [[DeepLinkTrust]].
                    if url.scheme == "openglasses",
                       DeepLinkTrust.requiresTrustedCaller(host: url.host, action: url.lastPathComponent),
                       !DeepLinkTrust.isTrusted(url) {
                        NSLog("[OpenGlasses] Ignored untrusted deep link: %@/%@",
                              url.host ?? "?", url.lastPathComponent)
                        return
                    }

                    // Skill-pack sideload (Plan BX P3). Deliberately outside the DeepLinkTrust
                    // token gate: a QR-scanned link can't carry the app-group token, and this
                    // handler never acts — it fetches a preview and raises a confirmation alert;
                    // the human tap is the gate. Source URLs are HTTPS-or-LAN-only (see
                    // SkillPackSideload.isPermittedSource).
                    if url.scheme == "openglasses", url.host == "skillpack" {
                        switch SkillPackSideload.parse(url) {
                        case .success(let request):
                            Task { @MainActor in
                                await appState.skillPackSideload.handle(request)
                            }
                        case .failure(let error):
                            NSLog("[OpenGlasses] Refused skillpack link: %@", String(describing: error))
                        }
                        return
                    }

                    // Handle persona quick-launch from widget/watch
                    if url.scheme == "openglasses", url.host == "persona" {
                        let personaId = url.lastPathComponent
                        Task { @MainActor in
                            if let persona = Config.enabledPersonas.first(where: { $0.id == personaId }) {
                                // Activate this persona's model + prompt
                                appState.applyPersonaRouting(persona)
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
            // Plan W: feed foreground state into the presence throttle (background ⇒ away ⇒ paused).
            appState.notePresenceForeground(newPhase == .active)
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
                    appState.releaseFramePin(trigger: .cameraTeardown)   // Plan CE
                    Task { await appState.cameraService.stopStreaming() }
                }
                appState.conversationStore.lock()
                // Re-lock for HIPAA — requires biometric to re-enter
                if Config.hipaaMode { isHipaaLocked = true }
            case .active:
                print("📱 App became active")
                appState.restoreFromBackground()
                // Teleprompter (PR B): pull in any scripts shared via the iOS share sheet
                // while we were away.
                let imported = appState.teleprompterStore.importPendingShares()
                if imported > 0 {
                    appState.glassesDisplay.flash("Imported \(imported) teleprompter script\(imported == 1 ? "" : "s")")
                }
                // Refresh the Siri Shortcuts catalog — the user may have added shortcuts
                // while away — so the agent's run_shortcut menu stays current (Plan Z).
                Task { await ShortcutsCatalog.shared.refresh() }
                // Plan BQ P2: re-donate user-exposed content to Spotlight (diff-only).
                SpotlightIndexService.shared.requestRefresh()
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
                if Config.isPastOnboarding {
                    Task { @MainActor in
                        // Give onOpenURL time to process any pending Meta Auth callbacks
                        try? await Task.sleep(nanoseconds: 1_500_000_000)

                        guard WearablesBootstrap.ensureConfigured() else { return }
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
                            await appState.wakeWordService.reconfigureAudioSessionIfNeeded()
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
        NSLog("[OpenGlasses] Logging active")
        // Single owner of configure(); safe to call more than once.
        guard WearablesBootstrap.ensureConfigured() else {
            NSLog("[OpenGlasses] Wearables SDK unavailable — glasses features disabled this launch")
            return
        }
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
    }
}

/// Global application state
@MainActor
class AppState: ObservableObject, AppStateProtocol {
    @Published var isConnected: Bool = false {
        didSet {
            speechService.glassesConnected = isConnected
            // Tell the gateway-side agent the glasses attached/detached (device.event push,
            // Plan BH follow-up). Consent-gated like the remote observe class; the client
            // itself no-ops unless the socket is authenticated.
            if oldValue != isConnected, Config.agentModeEnabled, Config.remoteInvokeObserveEnabled {
                openClawEventClient.sendDeviceEvent(type: "glasses", payload: [
                    "connected": isConnected,
                    "battery": glassesService.batteryLevel ?? -1,
                ])
            }
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
                releaseFramePin(trigger: .sessionStop)   // Plan CE

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
                    await self.wakeWordService.reconfigureAudioSessionIfNeeded()
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
    /// In-flight assistant reply for the Chat tab, streamed token-by-token where the provider
    /// supports it (on-device models today). The Chat thread renders this as a live bubble, then
    /// swaps it for the persisted message on completion. Nil when no reply is streaming.
    @Published var streamingTurn: StreamingTurn?
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
    let recordedSessionStore = RecordedSessionStore()
    let recordingTranscriber = RecordingTranscriber()
    /// Lazy: depends on the services above; first touched from the Recordings UI.
    lazy var sessionRecorder = SessionRecorderController(
        audioRecorder: audioRecorder,
        wakeWordService: wakeWordService,
        store: recordedSessionStore,
        transcriber: recordingTranscriber
    )
    let meetingAssistant = MeetingAssistantService()
    let broadcastService = BroadcastService()
    /// Broadcast chat read-aloud (Plan CI) — lives and dies with the broadcast session.
    let chatReadback = BroadcastChatReadbackService()
    let locationService = LocationService()
    let proactiveAlerts = ProactiveAlertService()
    let ambientCaptions = AmbientCaptionService()
    let glassesDisplay = GlassesDisplayService()
    /// Hermes agent bridge (Plan CL P5): optional LAN "brain" behind Agent Mode.
    let hermesBridge = HermesBridgeService()
    /// Dwell capture (Plan CG): gaze-hold on an object captures it. Passive until frames
    /// flow; `Config.dwellCaptureEnabled` gates the per-frame work.
    let dwellCapture = DwellCaptureService()
    /// Frame pinning (Plan CE): the pinned frame the model sees instead of the live feed.
    let framePin = FramePin()
    private var framePinGate = FramePinGate()

    /// Presence-aware throttle (Plan W): fuses cheap on-device signals into an engagement mode that
    /// scales the continuous loops' cadence and lowers the agent autonomy ceiling when disengaged.
    let presenceMonitor = PresenceMonitor()
    /// Notification digest (Plan BZ): first-party event streams composed into one glance.
    let notificationDigest = NotificationDigestService()
    /// Turn-by-turn walking navigation (Plan CA).
    let walkingRoute = WalkingRouteService()
    /// Web HUD mirror server (Plan BP) — entitlement-free Ray-Ban Display web-view path.
    let webHUDMirror = WebHUDMirrorServer()
    /// Acting tool calls the supervisor held while the user was disengaged (Plan W), surfaced on
    /// re-engagement.
    let heldRecommendations = HeldRecommendationStore()
    /// CoreMotion activity signal (Plan W v2) — feeds presence so a moving-but-quiet user reads as
    /// present, not idle. Inert on Simulator / without permission.
    let motionProvider = MotionActivityProvider()
    /// Last explicit user interaction (wake word / transcription) — the presence `lastInteraction`
    /// signal. `isForegroundActive` is the `foreground` signal (MLX is foreground-only, so
    /// background ⇒ `away` ⇒ paused). `presenceTimer` drives periodic re-evaluation.
    private var lastInteractionAt = Date()
    private var isForegroundActive = true
    private var presenceTimer: Timer?
    /// Drives periodic power-posture re-evaluation (Plan BV P2); also nudged on battery/thermal/
    /// power-state notifications.
    private var powerTimer: Timer?
    let faceRecognition = FaceRecognitionService()
    let memoryRewind = MemoryRewindService()
    let privacyFilter = PrivacyFilterService()
    let webRTCStreaming = WebRTCStreamingService()
    let liveActivityManager = LiveActivityManager()
    let agentDocs = AgentDocumentStore()
    let agentScheduler = AgentScheduler()
    let agentNotificationQueue = AgentNotificationQueue()
    let playbookStore = PlaybookStore()
    /// Interactive HUD (Display Phase 3 / Plan X): drives a Now/Next task card on the
    /// glasses from the active Playbook, navigable with the Neural Band.
    lazy var hudRouter = HUDRouter(display: glassesDisplay)
    lazy var playbookHUDSource = PlaybookHUDTaskSource(store: playbookStore)
    lazy var procedureHUDSource = ProcedureHUDTaskSource()
    /// Band-navigable launcher on the lens (Display Phase 4 / Plan Y).
    lazy var hudLauncher = HUDLauncher(router: hudRouter)
    /// Audio-paced HUD teleprompter (Teleprompter Phase 2): streams recognized speech into
    /// the `ScriptAligner` to keep your place, owns the display while active.
    let teleprompterStore = TeleprompterScriptStore()
    lazy var teleprompterService = TeleprompterService(store: teleprompterStore)
    let hipaaService = HIPAAComplianceService()
    let medicalExportService = MedicalExportService()

    /// Offline field queue + store-and-forward sync (Plan T): work done without signal is saved
    /// locally and flushed on reconnect.
    let offlineQueue = OfflineQueue()
    let reachability = Reachability()
    /// On-device translation (BY P3) — sessions are served by `TranslationEngineHost` in the
    /// app root; the engine itself is UI-free.
    let translationEngine = AppleTranslationEngine()
    lazy var syncEngine = SyncEngine(queue: offlineQueue, sink: LocalSyncSink())

    /// Alternative hands-free triggers (Additional Capabilities #5) — shake/acoustic/volume, all
    /// opt-in, each routing to the same entry point as the wake word.
    let alternativeTriggers = AlternativeTriggerService()
    let mediaTrigger = MediaTriggerService()

    /// Pending item to show in the share sheet
    @Published var pendingShareItem: ShareItem?

    /// Spotlight/Siri content result awaiting presentation (Plan BQ P2 OpenIntent).
    @Published var pendingSiriContent: SiriContentLink?

    // OpenClaw + Realtime sessions
    let openClawBridge = OpenClawBridge()
    let openClawEventClient = OpenClawEventClient()
    /// Remote invoke (Plan BH): gateway-initiated device commands, deny-by-default.
    lazy var remoteInvoke: RemoteInvokeService = makeRemoteInvokeService()
    let geminiLiveSession = GeminiLiveSessionManager()
    let openAIRealtimeSession = OpenAIRealtimeSessionManager()

    /// The live session that can put content in front of its model right now, or nil outside live
    /// modes (Plan CB). Resolved per call — never cache the session managers' conformances, they
    /// are per-session state behind long-lived objects.
    var activeLiveInjector: LiveSessionInjecting? {
        switch currentMode {
        case .geminiLive: return geminiLiveSession.canInject ? geminiLiveSession : nil
        case .openaiRealtime: return openAIRealtimeSession.canInject ? openAIRealtimeSession : nil
        default: return nil
        }
    }
    let backgroundVoice = BackgroundVoiceService()

    // Native tool system
    let nativeToolRegistry: NativeToolRegistry
    let nativeToolRouter: NativeToolRouter
    /// Installed skill packs (Plan BX). Actions merge into the registry below; re-merge after any
    /// install/remove/enable change via `refreshSkillPackTools()`.
    let skillPackStore: SkillPackStore
    /// QR/LAN sideload path (Plan BX P3) — fetch + preview + human-confirmed install.
    let skillPackSideload: SkillPackSideloadService

    /// Human-in-the-loop confirmation for high-impact / irreversible tool calls (prompt-injection backstop).
    let toolConfirmationCoordinator = ToolConfirmationCoordinator()

    // Tier 1 services
    let conversationStore = ConversationStore()
    /// On-device FTS index over conversation turns for cross-session recall (Memory & Recall Phase 2).
    let conversationIndex = ConversationIndex()
    let userMemory = SemanticMemoryStore()
    let documentStore = DocumentStore()
    let intentClassifier = IntentClassifier()
    let conversationClassifier = ConversationClassifier()

    private var cancellables: [Any] = []
    private var autoSleepTask: Task<Void, Never>?
    private var currentLLMTask: Task<Void, Never>?
    /// BK P2c — set once the model-switch notice has been spoken this turn, so a multi-hop cascade
    /// narrates only the FIRST fallback hop (not once per hop). Reset at the start of every turn.
    private var didNarrateModelSwitchThisTurn = false
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
        Self.persistDebugEvent("[\(timestamp)] \(message)")
    }

    /// Append a debug event to Documents/debug-events.log (ring-capped at ~200 KB). Live console
    /// attaches require an unlocked phone at the exact launch moment — this file can be pulled
    /// off the device at leisure (`devicectl device copy from … Documents/debug-events.log`),
    /// which makes field diagnosis survivable.
    nonisolated static func persistDebugEvent(_ line: String) {
        DispatchQueue.global(qos: .utility).async {
            guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
            let url = docs.appendingPathComponent("debug-events.log")
            let data = Data((line + "\n").utf8)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                if (try? handle.seekToEnd()) ?? 0 > 200_000 {
                    // Cap: keep the newest half when the log outgrows ~200 KB.
                    if let all = try? Data(contentsOf: url) {
                        try? all.suffix(100_000).write(to: url)
                    }
                    try? handle.seekToEnd()
                }
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }

    func recordCallback(url: URL, source: String) {
        lastCallbackSource = source
        lastCallbackURL = url.absoluteString
        lastCallbackAt = Date()
        addDebugEvent("Callback received via \(source)")
    }

    private func waitForRegistration(minState: Int, timeoutSeconds: Double) async -> Int {
        guard WearablesBootstrap.ensureConfigured() else { return 0 }
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
        // Active project namespace for document scoping (Plan AN). Bind a local ref to
        // `userMemory` (already initialized + kept current by activePersona.didSet) so the
        // closure resolves the live project id without capturing the half-built AppState.
        let memoryForNamespace = userMemory
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
            documentStore: documentStore,
            activeNamespace: { memoryForNamespace.activePersonaId ?? "global" }
        )
        nativeToolRouter = NativeToolRouter(registry: nativeToolRegistry, openClawBridge: openClawBridge)

        // Skill packs (Plan BX): the store validates against the RAW native tool names — captured
        // before any pack merge, so a previously installed pack can't launder a name past the
        // validator for the next install.
        let registryForPacks = nativeToolRegistry
        skillPackStore = SkillPackStore(nativeToolNames: {
            Set(registryForPacks.allTools.compactMap { $0 is SkillPackToolWrapper ? nil : $0.name })
        })
        nativeToolRegistry.registerSkillPackTools(from: skillPackStore)
        let storeForSideload = skillPackStore
        skillPackSideload = SkillPackSideloadService(
            store: storeForSideload,
            onInstalled: { [weak registryForPacks] in
                guard let registryForPacks else { return }
                registryForPacks.registerSkillPackTools(from: storeForSideload)
            })

        // Wire "still working" updates for long-running tool executions (Plan CB). Direct mode
        // speaks a deterministic phrase; during a live session this stays SILENT — the same router
        // serves live tool calls, where ToolCallRouter's two-phase ack already covers the wait in
        // the model's own voice, and this TTS was talking over it in a different one.
        // Plan CG: dwell capture speaks its confirmation through the shared TTS, and its
        // frame tap rides the existing camera publisher.
        dwellCapture.announce = { [weak self] text in await self?.speechService.speak(text) }
        dwellCapture.start(cameraService: cameraService)

        nativeToolRouter.onLongRunningUpdate = { [weak self] elapsed in
            guard let self else { return }
            Task { @MainActor in
                guard self.activeLiveInjector == nil else { return }
                await self.speechService.speak(AsyncDeliveryPhrasing.directModeStillWorking(elapsedSeconds: elapsed))
            }
        }

        // Wire the high-impact action confirmation gate (prompt-injection backstop) and have it
        // speak the prompt aloud so the user hears what they're approving while wearing the glasses.
        nativeToolRouter.confirmationCoordinator = toolConfirmationCoordinator
        // Deterministic safety supervisor context (Plan S): snapshot clock + current location +
        // persisted rules per tool call so geofence/quiet-hours rules reflect the real situation.
        nativeToolRouter.safetyContextProvider = { [weak self] in
            // Plan W: the presence mode lowers the autonomy ceiling — when the user is idle/away, an
            // acting tool is held rather than run autonomously (see SafetySupervisor.autonomyCeiling).
            let autonomy = ThrottlePolicy.decide(mode: self?.presenceMonitor.mode ?? .active).autonomy
            return SafetyContext.live(now: Date(),
                                      location: self?.locationService.currentLocation?.coordinate,
                                      autonomy: autonomy)
        }
        // Plan W: record actions the supervisor holds under a lowered autonomy ceiling, to surface
        // when the user re-engages.
        nativeToolRouter.onActionHeld = { [weak self] summary in
            self?.heldRecommendations.record(summary: summary, at: Date())
        }
        toolConfirmationCoordinator.onSpeakPrompt = { [weak self] prompt in
            guard let self else { return }
            // Shared consent surface (BN P1): spoken prompt + in-lens HUD card together.
            self.glassesDisplay.showNotification(title: "Approve?", body: prompt, icon: .info, duration: 10)
            Task { @MainActor in
                await self.speechService.speak(prompt)
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

        // (Gemma-4 is now supplied by mlx-swift-lm's own LLMModelFactory registration; the
        // former custom port + override here shadowed the library's tested model for every
        // "gemma4" text load and was only reached — never — because the model mistakenly
        // loaded through the vision factory. See LocalLLMService.visionModelIds.)

        // Share the audio engine so transcription works in background
        transcriptionService.sharedAudioEngineProvider = wakeWordService

        // TTS borrows the wake-word service so it can pause/resume other audio via the
        // same reference-counted hold that the active-listening flow uses.
        speechService.wakeWordService = wakeWordService

        // Mirror spoken AI responses + ambient captions to the in-lens HUD (no-op on
        // glasses without a display, and gated behind Config.glassesDisplayEnabled).
        speechService.glassesDisplay = glassesDisplay
        glassesDisplay.onDebugEvent = { [weak self] message in
            Task { @MainActor in self?.addDebugEvent(message) }
        }

        // Let the TTS engine selector know whether we're online, so a configured ElevenLabs key
        // isn't preferred while offline (it'd fail the network call and fall back anyway).
        speechService.reachability = reachability

        // Wire Tier 1 services
        ambientCaptions.wakeWordService = wakeWordService
        ambientCaptions.glassesDisplay = glassesDisplay
        // BY P3: on-device translation tier — the Apple Translation engine is hosted in the app
        // root (`TranslationEngineHost`); reachability drives the offline → on-device tier rule.
        ambientCaptions.translationEngine = translationEngine
        ambientCaptions.reachability = reachability
        // Toggling HIPAA mid-session must tear down any live cloud diarization at once (Plan BM
        // P0): reconfigure ambient captions onto the on-device path the moment the flag flips.
        hipaaService.onModeChanged = { [weak ambientCaptions, weak self] in
            ambientCaptions?.reconfigureForModeChange()
            // Plan BP: HIPAA hard-disables the web mirror — kill a live listener at once.
            if Config.hipaaMode { self?.webHUDMirror.stop() }
        }
        // Same teardown when translation settings change under a live session (BY P2) — the
        // backend branch is picked at session start, so a settings flip must restart it.
        NotificationCenter.default.addObserver(forName: .captionBackendChanged, object: nil,
                                               queue: .main) { [weak ambientCaptions] _ in
            Task { @MainActor in ambientCaptions?.reconfigureForModeChange() }
        }
        // Teleprompter (Phase 2): shared audio engine for live recognition + the in-lens HUD.
        teleprompterService.wakeWordService = wakeWordService
        teleprompterService.glassesDisplay = glassesDisplay
        // Phase 4: glasses camera for OCR script capture (OCR uses the default OCRService seam).
        teleprompterService.camera = cameraService
        memoryRewind.wakeWordService = wakeWordService
        videoRecorder.wakeWordService = wakeWordService
        videoRecorder.ambientCaptionService = ambientCaptions
        // Stream-death auto-stop: announce it — the user can't tell from inside a pocket that
        // the glasses died and the recording was ended and saved.
        videoRecorder.onAutoStopped = { [weak self] message in
            guard let self else { return }
            Task { @MainActor in
                await self.speechService.speak(message)
            }
        }
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
                guard let self else { return }
                // Log the encounter (who/where/when) in the brain's encounter log.
                BrainStore.shared.logEncounter(
                    person: name,
                    locationName: self.locationService.locationContext,
                    latitude: self.locationService.currentLocation?.coordinate.latitude,
                    longitude: self.locationService.currentLocation?.coordinate.longitude
                )
                // Whisper the name quietly via TTS
                await self.speechService.speak("That's \(name).")
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
        // Live native-tool-name source so the MCP tool-poisoning scanner can flag collisions
        // (Plan R). Read lazily so late-registered tools are included.
        mcpClient.nativeToolNames = { [weak nativeToolRegistry] in
            Set(nativeToolRegistry?.allTools.map(\.name) ?? [])
        }
        // Launch-time re-discovery (BM P6): discovered MCP tools live only in memory, so without
        // this they vanish on every relaunch until the user re-taps "Discover Tools". Re-running
        // discovery also re-runs the Plan R tool-poisoning scan on current definitions.
        Task { [weak mcpClient] in
            await mcpClient?.rediscoverAtLaunch()
        }
        // Plan-then-execute HUD trace (Plan S): show the plan header + per-step progress on the lens
        // while a multi-step agent task runs. The final summary is spoken via the normal TTS path.
        llmService.onAgentNarrate = { [weak self] line in
            self?.glassesDisplay.showNotification(title: "Agent", body: line, icon: .info, duration: 4)
        }
        llmService.onAgentStep = { [weak self] index, total, step in
            let body = step.rationale.isEmpty ? step.tool : step.rationale
            self?.glassesDisplay.showNotification(title: "Step \(index) of \(total)", body: body, icon: .navigation, duration: 4)
        }

        // Structured capture flows (Plan U): persist finished records to the offline queue (Plan T)
        // and stamp each captured value with the current GPS for provenance.
        CaptureFlowService.shared.offlineQueue = offlineQueue
        CaptureFlowService.shared.location = { [weak self] in
            self?.locationService.currentLocation.map { (lat: $0.coordinate.latitude, lon: $0.coordinate.longitude) }
        }

        // Offline field queue (Plan T): feed captured photos into the durable queue, surface the
        // offline/reconnect state hands-free, and flush on the rising edge of connectivity.
        FieldSessionService.shared.offlineQueue = offlineQueue
        reachability.onChange = { [weak self] online in
            guard let self else { return }
            if online {
                let n = self.offlineQueue.pendingCount
                guard n > 0 else { return }
                self.glassesDisplay.flash("Back online — syncing \(n) item\(n == 1 ? "" : "s")")
                Task { await self.speechService.speak("Back online. Syncing \(n) item\(n == 1 ? "" : "s").") }
            } else {
                self.glassesDisplay.showNavigation("Offline — your work is saved and will sync when you reconnect", icon: .info)
                Task { await self.speechService.speak("You're offline. Your work is being saved and will sync when you're back online.") }
            }
        }
        syncEngine.bind(to: reachability)        // chains the affordance above, then flushes on reconnect
        syncEngine.onConflict = { [weak self] _, reason in
            Task { @MainActor in await self?.speechService.speak("Heads up — \(reason).") }
        }
        // Launch-time flush (Plan BM P1): a relaunch that comes up already-online produces no
        // reachability edge, so bind() alone would never sync work captured before the last quit.
        // OfflineQueue.init already re-armed any inFlight strands. Reclaim space either way.
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.reachability.isOnline, self.offlineQueue.pendingCount > 0 {
                await self.syncEngine.flush()      // drains (in pages) and maintains
            } else {
                self.syncEngine.runMaintenance()
            }
        }

        // Register live translation tool with its service reference
        var translationTool = LiveTranslationTool()
        translationTool.translationService = liveTranslation
        nativeToolRegistry.register(translationTool)

        // Teleprompter tool (Phase 2): registered after the lazy service is available. The
        // document store enables prompting from a saved knowledge-base doc (Document-RAG source),
        // scoped to the active project + global so it can't read another project's doc (Plan BM P8).
        var teleprompterTool = TeleprompterTool(service: teleprompterService, documentStore: documentStore)
        teleprompterTool.activeNamespace = { memoryForNamespace.activePersonaId ?? "global" }
        nativeToolRegistry.register(teleprompterTool)

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

        // Hands-free "new topic" — the new_topic tool posts this; clear the LLM's context
        // (deferred-safe when a turn is in flight) and start a fresh persistence thread so the
        // conversation history view also breaks here.
        NotificationCenter.default.addObserver(forName: .ogNewTopicRequested, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.llmService.requestHistoryClear()
                if Config.conversationPersistenceEnabled {
                    self.conversationStore.startThread(mode: self.currentMode.rawValue, personaId: self.activePersona?.id)
                }
                NSLog("[AppState] New topic — conversation context cleared")
            }
        }

        // Wire camera frames for realtime sessions:
        // Direct push: CameraService streams frames to whichever session is active.
        // Frame pinning (Plan CE) gates ONLY this model-facing path: while a pin is held, live
        // frames are suppressed and the pinned frame is re-injected on a heartbeat (sharp-inject,
        // bypassing the throttler, so the model's copy is exactly the on-screen frame). Every
        // other framePublisher consumer keeps receiving live frames.
        cameraService.onVideoFrame = { [weak self] image in
            guard let self else { return }
            let pinned = Config.framePinEnabled && self.framePin.isPinned
            switch self.framePinGate.evaluate(isPinned: pinned, now: Date().timeIntervalSinceReferenceDate) {
            case .suppress:
                return
            case .resendPinned:
                self.injectPinnedFrame()
                return
            case .deliverLive:
                if self.currentMode == .geminiLive {
                    self.geminiLiveSession.submitVideoFrame(image)
                } else if self.currentMode == .openaiRealtime {
                    self.openAIRealtimeSession.submitVideoFrame(image)
                }
            }
        }

        // Polling fallback for both session managers — a held pin substitutes for the live frame
        geminiLiveSession.onRequestVideoFrame = { [weak self] in
            guard let self else { return nil }
            if Config.framePinEnabled, let pinned = self.framePin.pinnedFrame { return pinned }
            return self.cameraService.latestFrame
        }
        openAIRealtimeSession.onRequestVideoFrame = { [weak self] in
            guard let self else { return nil }
            if Config.framePinEnabled, let pinned = self.framePin.pinnedFrame { return pinned }
            return self.cameraService.latestFrame
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

        // Defer the SDK's Bluetooth prompt until the user is past onboarding.
        // startPermissionRequiringServices() itself observes + auto-connects — calling those
        // two here as well DOUBLED every glasses listener (device-traced: every registration/
        // devices/permission log line appeared twice from launch).
        // `isPastOnboarding`, not `hasCompletedOnboarding`: the latter leaves a user who saved a
        // key without finishing onboarding with the glasses stack permanently off.
        if Config.isPastOnboarding {
            startPermissionRequiringServices()
        }

        // Start proactive calendar alerts — speaks through TTS when events are imminent,
        // and mirrors a richer notification card to the in-lens HUD.
        proactiveAlerts.onAlert = { [weak self] message, urgency in
            guard let self else { return }
            self.glassesDisplay.showNotification(title: "Reminder", body: message, icon: .calendar)
            // Plan BZ: calendar/proactive alerts also feed the digest.
            self.notificationDigest.ingest(source: .proactive, title: message,
                                           priority: urgency == .high ? .high : .medium)
            Task {
                await self.speechService.speak(message, urgency: urgency, mirrorToHUD: false)
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

        // Wire the presence-aware throttle (Plan W) into the loops + signal sources.
        configurePresence()

        // Wire the battery/thermal power posture (Plan BV) to the device signals.
        configurePower()

        // Remote Agent Harness (Plan N): build the harness registry (OpenClaw + Custom URL) and
        // narrate via TTS. Gated at the tool layer by Config.agentModeEnabled.
        AgentSessionService.shared.configure(registry: makeAgentRegistry(), speak: { [weak self] line in
            Task { @MainActor in await self?.speechService.speak(line) }
        })
        // BN P1: a `code_agent confirm` tool call only raises the user-distinct consent prompt —
        // it can never approve itself (the prompt-injection → self-approved-push hole).
        AgentSessionService.shared.requestUserConsent = { [weak self] request in
            guard let self else { return false }
            return await self.toolConfirmationCoordinator.requestConfirmation(
                toolName: "code_agent", summary: request.summary, source: request.source)
        }

        // Configure Navigation Assist (Plan J) similarly.
        NavigationAssistService.shared.configure(camera: cameraService, llm: llmService, tts: speechService)
        NavigationAssistService.shared.glassesDisplay = glassesDisplay

        // First-Aid / Emergency Assist (Additional Capabilities) — spoken protocol coach + CPR metronome.
        FirstAidAssistService.shared.configure(tts: speechService, glassesDisplay: glassesDisplay, location: locationService)

        // Configure Structured Vision (vision_assess / read-the-instrument) similarly.
        StructuredVisionService.shared.configure(camera: cameraService, llm: llmService, tts: speechService)
        StructuredVisionService.shared.glassesDisplay = glassesDisplay

        // Configure Safety Assessment (HECA) — runs through the structured-vision provider layer.
        SafetyAssessmentService.shared.configure(camera: cameraService, llm: llmService)

        // Visual State Memory (Plan AV) — the keyframe describe needs a vision LLM.
        VisualStateService.shared.llm = llmService

        // Health-Safety Advisor (Plan AB) — grounded long-tail reasoning for "is this safe for me?".
        HealthSafetyAdvisor.shared.llm = llmService

        // Apply any saved LLM pricing overrides into the live table (Plan AU editor).
        Config.applyModelPricingOverrides()

        // Projects (Plan AN) — grounds the prompt in the active project's documents.
        ProjectContextService.shared.configure(
            documentStore: documentStore,
            activeProjectId: { [weak self] in self?.activePersona?.id },
            activeProjectName: { [weak self] in self?.activePersona?.name }
        )

        // Configure Study Mode — generates decks from documents via the text→JSON LLM call;
        // camera enables the hands-free scan → OCR source.
        StudyService.shared.configure(llm: llmService, documentStore: documentStore, tts: speechService, camera: cameraService)

        // Reading companion (Plan BT) — camera frames for page turns, Study Mode for the
        // end-of-session deck, DocumentStore for P4 reference copies, HUD for the recap card.
        ReadingCompanionService.shared.configure(camera: cameraService, study: StudyService.shared,
                                                 documents: documentStore)
        ReadingCompanionService.shared.glassesDisplay = glassesDisplay
        // Lets end() give the camera back the way it found it without stopping a stream some
        // other feature is mid-way through using (same consumer set LivePreviewView checks).
        ReadingCompanionService.shared.otherStreamConsumersActive = { [weak self] in
            guard let self else { return false }
            return self.videoRecorder.isRecording || self.broadcastService.isBroadcasting
                || self.webRTCStreaming.isStreaming || self.geminiLiveSession.isActive
                || self.openAIRealtimeSession.isActive
        }

        // Skill Self-Evolution (Plan AW) — give the loop its LLM analyzer. The capture hook
        // (NativeToolRouter) feeds tool-error samples; this completes the loop so proposals reach the
        // review inbox. Agent-Mode-gated throughout; inert until the user turns Agent Mode on.
        let llm = llmService
        SkillEvolutionService.shared.analyzer = LLMSkillEvolutionAnalyzer(complete: { system, user in
            try await llm.completeStateless(user, system: system)
        })

        // Memory & Recall Phase 2 — index conversation turns; recall summarizes via the user's
        // active provider (on-device when that's their choice). Backfill existing history once.
        conversationStore.recallIndex = conversationIndex
        if conversationIndex.count() == 0 { conversationStore.backfillIndex() }
        RecallService.shared.configure(index: conversationIndex) { [weak self] question, hits in
            guard let self else { return RecallService.fallbackSummary(hits) }
            let prompt = RecallService.summarizationPrompt(question: question, hits: hits)
            return (try? await self.llmService.completeStateless(prompt.user, system: prompt.system))
                ?? RecallService.fallbackSummary(hits)
        }

        // Memory & Recall Phase 3 — the self-improving loop: nudge (or, in Agent Mode, silently
        // save) durable facts + repeated multi-step requests. Presence-aware; off by default.
        MemoryLoopService.shared.configure(presence: presenceMonitor) { [weak self] message in
            Task { @MainActor in await self?.speechService.speak(message) }
        }

        // Memory & Recall Phase 4 — on-device usage insights from conversation history.
        InsightsService.shared.configure(conversationStore: conversationStore)

        // Field Assist Phase 5 (Plan K2): expert stream bridge for escalations. Transport
        // (MJPEG / WebRTC) is selected in Settings; MJPEG is the working default.
        EscalationCoordinator.shared.bridge = ExpertStreamBridge(
            streamer: webRTCStreaming, framePublisher: cameraService.framePublisher)

        // Plan M3: hand the audio session to a live expert call (pause TTS + wake word), and
        // refuse to start one while a realtime voice session (Gemini Live / OpenAI Realtime)
        // already owns the mic — only one audio owner at a time.
        ExpertCallAudioCoordinator.shared.control = AppExpertCallAudioControl(
            wakeWord: wakeWordService, tts: speechService)
        ExpertCallAudioCoordinator.shared.isRealtimeSessionActive = { [weak self] in
            (self?.geminiLiveSession.isActive ?? false) || (self?.openAIRealtimeSession.isActive ?? false)
        }

        // MCP Glasses server (Plan E, dev-only) — configure and start if both gates are on.
        MCPGlassesServer.shared.configure(camera: cameraService, tts: speechService)
        MCPGlassesServer.shared.startIfEnabled()

        // Web HUD mirror (Plan BP, dev-only): serves the current HUD frame to the glasses'
        // built-in web view — the entitlement-free Ray-Ban Display path. Read-only.
        webHUDMirror.payloadProvider = { [weak self] in
            guard let screen = self?.glassesDisplay.mirrorScreen else { return .empty }
            return WebHUDPayload.from(screen: screen)
        }
        webHUDMirror.startIfEnabled()

        // Pre-fetch Home Assistant entity cache for fuzzy matching
        Task { await HomeAssistantEntityCache.shared.refreshIfNeeded() }

        // Wire geofence alerts — speak via TTS when entering/leaving a region, and
        // mirror a location notification card to the in-lens HUD.
        if let geofenceTool = nativeToolRegistry.tool(named: "geofence") as? GeofenceTool {
            geofenceTool.onAlert = { [weak self] message, urgency in
                guard let self else { return }
                self.glassesDisplay.showNotification(title: "Location", body: message, icon: .location)
                // Plan BZ: geofence transitions feed the digest (near-dup dedup absorbs bounces).
                self.notificationDigest.ingest(source: .geofence, title: message,
                                               priority: urgency == .high ? .high : .medium)
                Task {
                    await self.speechService.speak(message, urgency: urgency, mirrorToHUD: false)
                }
            }
            // BK P1: wire the region-event forwarders (via LocationService's single delegate) and
            // re-arm saved geofences. Without this the alert path was dead code.
            geofenceTool.activate()
        }

        // OpenClaw WebSocket — triage notifications through the agent before speaking
        openClawEventClient.onNotification = { [weak self] message in
            guard let self else { return }
            Task { @MainActor in
                await self.triageOpenClawNotification(message)
            }
        }
        // Remote invoke (Plan BH): gateway-initiated device commands. Parser/policy/reply are
        // pure and tested; the policy denies everything while Agent Mode is off, before the
        // executor is ever consulted. Every exchange is audited (gateway settings).
        openClawEventClient.onRemoteRequest = { [weak self] frame, respond in
            guard let self else { return }
            Task { @MainActor in
                if let reply = await self.remoteInvoke.handleFrame(frame) {
                    respond(reply)
                }
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

        // BK P0: only start the inbound event loop (→ LLM triage → outbound delegate) when the
        // gateway is an active agentic capability. `connect()` re-checks this itself, too.
        if Config.isOpenClawAgentActive {
            openClawEventClient.connect()
            Task { await openClawBridge.checkConnection() }
        }

        // Hermes agent bridge (Plan CL P5): eyes on request, events into the field log.
        hermesBridge.photoProvider = { [weak self] in
            guard let self, self.isConnected else {
                throw NSError(domain: "HermesBridge", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "Glasses camera unavailable"])
            }
            return try await self.cameraService.capturePhoto()
        }
        hermesBridge.onDebugEvent = { [weak self] event in
            self?.addDebugEvent(event)
        }
        if hermesBridge.isEnabled {
            hermesBridge.connect()
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

        // Plan CF: was a live call in progress? Captured BEFORE teardown — the policy turns
        // this into an auto-redial so switching brains mid-call doesn't go silently dead.
        let wasSessionActive = (oldMode == .geminiLive && geminiLiveSession.isActive)
            || (oldMode == .openaiRealtime && openAIRealtimeSession.isActive)
        let actions = ModeSwitchPolicy.actions(from: oldMode, to: mode,
                                               wasSessionActive: wasSessionActive,
                                               autoRedial: Config.modeSwitchAutoRedialEnabled)
        // Plan CE interplay (open question resolved "yes" in CF): a redial carries a held pin
        // into the new session — the referent is the user's intent, not the session's lifetime.
        // Only a non-redialing switch releases it.
        if !actions.contains(.startSession(mode)) {
            releaseFramePin(trigger: .modeSwitch)
        }

        Task {
            for action in actions {
                switch action {
                case .teardown(let target):
                    switch target {
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

                case .settleDelay:
                    // Brief delay for audio session to release
                    try? await Task.sleep(nanoseconds: 500_000_000)

                case .startSubstrate(let target):
                    switch target {
                    case .direct:
                        try? await wakeWordService.startListening()
                    case .geminiLive, .openaiRealtime:
                        // Background voice keeps audio alive when backgrounded; camera up so
                        // frames are available when the session starts
                        backgroundVoice.startBackgroundSession()
                        do {
                            try await cameraService.startStreaming()
                        } catch {
                            NSLog("[App] Camera streaming failed to start: %@", error.localizedDescription)
                        }
                    }

                case .startSession(let target):
                    // The redial. Errors surface exactly as a manual failed connect would —
                    // the managers publish `connectionState`/`errorMessage` themselves, and the
                    // automatic path must not swallow them.
                    switch target {
                    case .geminiLive: await geminiLiveSession.startSession()
                    case .openaiRealtime: await openAIRealtimeSession.startSession()
                    case .direct: break   // policy never emits this
                    }
                    let ready = (target == .geminiLive && geminiLiveSession.isActive)
                        || (target == .openaiRealtime && openAIRealtimeSession.isActive)
                    if ready {
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        // Plan CE: re-push a held pin so the new brain sees the same referent.
                        if Config.framePinEnabled, framePin.isPinned {
                            injectPinnedFrame()
                            framePinGate.notePinnedPushed(now: Date().timeIntervalSinceReferenceDate)
                        }
                        NSLog("[App] Mode-switch redial connected (%@)", target.rawValue)
                    } else {
                        NSLog("[App] Mode-switch redial failed (%@) — error surfaced via session state",
                              target.rawValue)
                    }
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

    /// The active model id before a Field Assist session swapped in the vault's model.
    private var modelBeforeFieldSession: String?

    /// Apply a vault's linked model for the lifetime of a Field Assist session, then
    /// restore. `session == nil` means the session ended.
    private func applyFieldSessionModel(for session: FieldSession?) {
        if let session {
            guard let modelId = Config.fieldAssistVaultModelId(for: session.vaultId),
                  Config.savedModels.contains(where: { $0.id == modelId }),
                  modelId != Config.activeModelId else { return }
            if modelBeforeFieldSession == nil { modelBeforeFieldSession = Config.activeModelId }
            Config.setActiveModelId(modelId)
            llmService.refreshActiveModel()
            NSLog("[FieldAssist] Session started — using vault model %@", modelId)
        } else if let prev = modelBeforeFieldSession {
            Config.setActiveModelId(prev)
            llmService.refreshActiveModel()
            NSLog("[FieldAssist] Session ended — restored model %@", prev)
            modelBeforeFieldSession = nil
        }
    }

    private func setupServiceCallbacks() {
        // BS P2: broadcast mic audio rides the wake-word shared tap.
        broadcastService.audioProvider = wakeWordService

        // Wire camera debug events to the on-screen debug log
        cameraService.onDebugEvent = { [weak self] message in
            Task { @MainActor in
                self?.addDebugEvent(message)
            }
        }

        // BR P2: announce a DAT update requirement once per notice — voice-first, the
        // phone may be pocketed; without this an outdated Meta AI app reads as a mystery
        // connection failure.
        let compatToken = cameraService.$compatibilityNotice
            .compactMap { $0 }
            .removeDuplicates()
            .sink { [weak self] notice in
                guard let self else { return }
                self.addDebugEvent(notice)
                Task { await self.speechService.speak(notice) }
            }
        cancellables.append(compatToken)

        // Field Assist: a vault's linked model is applied only for the session's
        // duration — switch to it when a session starts, restore the prior model when it
        // ends. Observing activeSession covers both UI- and voice-started sessions.
        let fieldSessionToken = FieldSessionService.shared.$activeSession
            .removeDuplicates { $0?.id == $1?.id }
            .sink { [weak self] session in
                self?.applyFieldSessionModel(for: session)
            }
        cancellables.append(fieldSessionToken)

        // Auto-present the interactive HUD task card (Display Phase 3 / Plan X) when a
        // Playbook session starts; the router self-dismisses when the workflow ends.
        let playbookHUDToken = playbookStore.$activeSession
            .map { $0 != nil }
            .removeDuplicates()
            .sink { [weak self] active in
                guard let self, active else { return }
                self.hudRouter.startTask(self.playbookHUDSource)
            }
        cancellables.append(playbookHUDToken)

        // Auto-present the interactive HUD task card when a Field Assist procedure starts.
        let procedureHUDToken = FieldSessionService.shared.$activeProcedureId
            .map { $0 != nil }
            .removeDuplicates()
            .sink { [weak self] active in
                guard let self, active else { return }
                self.hudRouter.startTask(self.procedureHUDSource)
            }
        cancellables.append(procedureHUDToken)

        // Wire the HUD launcher's leaf actions (Display Phase 4 / Plan Y).
        // Notification digest (Plan BZ): surface + rewrite + source wiring.
        notificationDigest.hudRouter = hudRouter
        notificationDigest.presence = presenceMonitor
        notificationDigest.speak = { [weak self] text in
            Task { await self?.speechService.speak(text) }
        }
        // One-shot structured call — never the conversation path, so rewrites can't pollute
        // chat history. Offline/reserve skip the rewrite entirely (fallback lines only).
        notificationDigest.rewrite = { [weak self] prompt, schema in
            await self?.llmService.completeStructured(
                systemPrompt: "You compress notifications into terse heads-up display lines.",
                userText: prompt, jsonSchema: schema, toolName: "digest_lines", maxTokens: 300)
        }
        notificationDigest.acknowledgeAgentItems = { [weak self] ids in
            self?.agentNotificationQueue.markDelivered(ids: ids)
        }
        notificationDigest.isOffline = { [weak self] in !(self?.reachability.isOnline ?? true) }
        agentNotificationQueue.onQueued = { [weak self] notification in
            self?.notificationDigest.ingest(
                source: .agent, title: notification.message, priority: notification.priority,
                threadKey: notification.id, awaitingReply: notification.priority == .high)
        }
        hudLauncher.digestHasContent = { [weak self] in self?.notificationDigest.hasContent ?? false }
        hudLauncher.openDigest = { [weak self] in
            Task { await self?.notificationDigest.presentGlance() }
        }

        // Walking navigation (Plan CA): location + HUD + urgency-scaled TTS, launcher recents.
        walkingRoute.locationService = locationService
        walkingRoute.glassesDisplay = glassesDisplay
        walkingRoute.speak = { [weak self] text, urgency in
            Task { await self?.speechService.speak(text, urgency: urgency, mirrorToHUD: false) }
        }
        hudLauncher.recentDestinations = { Config.recentDestinations }
        hudLauncher.startNavigation = { [weak self] destination in
            Task {
                do { _ = try await self?.walkingRoute.start(destination: destination) }
                catch { NSLog("[Navigation] Launcher start failed: %@", error.localizedDescription) }
            }
        }

        hudLauncher.runQuickAction = { [weak self] action in
            Task { @MainActor in await self?.executeQuickAction(action) }
        }
        hudLauncher.switchPersona = { [weak self] persona in
            guard let self else { return }
            self.activePersona = persona
            Config.setActiveModelId(persona.modelId)
            Config.setActivePresetId(persona.presetId)
        }
        hudLauncher.activePersonaId = { [weak self] in self?.activePersona?.id }

        // Workflows branch: list the saved playbooks; selecting one starts it and hands off
        // to the Plan X Now/Next card (startTask supersedes the open menu).
        hudLauncher.availablePlaybooks = { [weak self] in self?.playbookStore.playbooks ?? [] }
        hudLauncher.startPlaybook = { [weak self] id in
            guard let self else { return }
            _ = self.playbookStore.startPlaybook(id)
            self.hudRouter.startTask(self.playbookHUDSource)
        }

        // SOPs branch: gated on the Field Assist entitlement; procedures are vault-scoped so
        // they list during an active session. Selecting one ensures a session, starts the
        // procedure, and hands off to the Plan X card.
        hudLauncher.fieldAssistActive = { Config.fieldAssistActive }
        hudLauncher.availableProcedures = { FieldSessionService.shared.availableProcedureDefinitions() }
        hudLauncher.startProcedure = { [weak self] id in
            guard let self else { return }
            do {
                if FieldSessionService.shared.activeSession == nil {
                    try FieldSessionService.shared.startSession(vaultId: Config.fieldAssistDefaultVaultId, assetId: nil)
                }
                _ = try FieldSessionService.shared.startProcedure(id: id)
                self.hudRouter.startTask(self.procedureHUDSource)
            } catch {
                self.glassesDisplay.flash("⚠️ \(error.localizedDescription)")
            }
        }

        wakeWordService.onWakeWordDetected = { [weak self] matchedPhrase in
            Task { @MainActor in
                guard let self = self else { return }
                self.noteUserInteraction()   // Plan W: a wake word is an explicit engagement
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
                    self.applyPersonaRouting(persona)
                    print("🎭 Persona activated: \(persona.name) (model: \(persona.modelId.isEmpty ? "user's current" : persona.modelId))")
                }
                await self.handleWakeWordDetected()
            }
        }

        // Alternative hands-free triggers (Additional Capabilities #5): a shake/cough/volume press
        // routes to the same entry as the wake word, suppressed under the same conditions.
        alternativeTriggers.isSuppressed = { [weak self] in
            guard let self else { return true }
            return self.inConversation || self.isProcessing || AssistiveModeService.shared.isActive
        }
        alternativeTriggers.onTrigger = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.noteUserInteraction()
                await self.handleWakeWordDetected(manual: true)
            }
        }
        if Config.anyAlternativeTriggerEnabled { alternativeTriggers.start() }

        // Temple-tap media trigger (Plan CH): a glasses temple double-tap arrives as an AVRCP
        // next-track command while we hold Now Playing, and routes to the same entry as the wake
        // word. The claim/release policy keeps the user's audio and realtime sessions first.
        mediaTrigger.isSuppressed = { [weak self] in
            guard let self else { return true }
            return self.inConversation || self.isProcessing || AssistiveModeService.shared.isActive
        }
        mediaTrigger.realtimeSessionActive = { [weak self] in
            (self?.geminiLiveSession.isActive ?? false) || (self?.openAIRealtimeSession.isActive ?? false)
        }
        mediaTrigger.onTrigger = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.noteUserInteraction()
                await self.handleWakeWordDetected(manual: true)
            }
        }
        if Config.mediaTriggerEnabled { mediaTrigger.start() }

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
                self.noteUserInteraction()   // Plan W: a spoken command is an explicit engagement
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

    /// True once the Wearables listeners below are installed — this function is reachable from
    /// more than one startup path, and installing the listeners twice doubles every event
    /// (and the camera-permission pre-request chain).
    private var glassesObserversInstalled = false

    private func observeGlassesConnection() {
        guard !glassesObserversInstalled else { return }
        glassesObserversInstalled = true
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

        // Every SDK access below traps if configure() never succeeded. Registration stays at 0 and
        // the UI shows the unregistered state, which is the honest outcome.
        guard WearablesBootstrap.ensureConfigured() else {
            addDebugEvent("Wearables SDK unavailable — glasses features disabled")
            return
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
                    // Plan BZ: flash the digest once on reconnect when something urgent is
                    // pending (presence- and power-gated inside; after the queue's window so
                    // spoken delivery and the glance don't collide).
                    if wasDisconnected {
                        Task {
                            try? await Task.sleep(nanoseconds: 5_000_000_000)
                            await self.notificationDigest.autoSurfaceOnConnect()
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
            guard WearablesBootstrap.ensureConfigured() else {
                self.isConnected = false
                self.addDebugEvent("Wearables SDK unavailable — skipping launch state check")
                return
            }
            let state = Wearables.shared.registrationState
            self.registrationStateRaw = state.rawValue
            print("📋 Launch state check: state=\(state.rawValue)")
            self.addDebugEvent("Launch state check: state=\(state.rawValue)")

            if state.rawValue >= 3 {
                // Already registered this session
                self.hasEverRegistered = true
                self.addDebugEvent("Already registered on launch")
                await requestEarlyPermission(allowRequest: false)
            } else {
                // Wait briefly for SDK to auto-reconnect via Bluetooth
                try? await Task.sleep(nanoseconds: 3_000_000_000)  // 3s
                let settledState = Wearables.shared.registrationState
                self.registrationStateRaw = settledState.rawValue
                if settledState.rawValue >= 3 {
                    self.hasEverRegistered = true
                    self.addDebugEvent("SDK auto-reconnected to state \(settledState.rawValue)")
                    await requestEarlyPermission(allowRequest: false)
                } else {
                    self.isConnected = false
                    self.addDebugEvent("State \(settledState.rawValue) — tap Connect to register")
                }
            }
        }
    }

    /// Establish camera permission early so devices appear in addDevicesListener.
    /// Per Meta docs: "A device will not appear in devicesStream until the user has
    /// granted at least one permission (e.g., camera) through the Meta AI app."
    ///
    /// `allowRequest` decides what happens when the permission is *not* already granted.
    /// Requesting it deep-links out to the Meta AI app, so that only ever happens for a
    /// user-initiated action — the same rule `autoConnectGlasses()` follows for registration.
    /// At launch we only *check*: an already-granted permission still connects silently, but a
    /// registered user with no glasses paired is no longer thrown into the Meta AI app on every
    /// single launch, where there is nothing for them to approve.
    private func requestEarlyPermission(allowRequest: Bool) async {
        addDebugEvent("Checking early camera permission for device discovery...")
        guard WearablesBootstrap.ensureConfigured() else {
            addDebugEvent("Wearables SDK unavailable — cannot request glasses camera permission")
            return
        }

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

            guard allowRequest else {
                addDebugEvent("Camera permission not granted — tap Connect to approve in Meta AI")
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
        // The Connect button is the path that used to kill the app: for a user who saved an API key
        // without finishing onboarding, nothing had ever called configure().
        guard WearablesBootstrap.ensureConfigured() else {
            addDebugEvent("Wearables SDK unavailable — cannot start registration (\(WearablesBootstrap.statusDescription))")
            return
        }
        do {
            try await Wearables.shared.startRegistration()
        } catch {
            print("📋 Manual registration start failed: \(error)")
            addDebugEvent("Manual registration start failed: \(error.localizedDescription)")
        }

        let currentState = Wearables.shared.registrationState.rawValue
        registrationStateRaw = currentState
        if currentState >= 3 {
            // User-initiated: deep-linking to the Meta AI app to approve the permission is the
            // whole point of this path.
            await requestEarlyPermission(allowRequest: true)
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
        guard WearablesBootstrap.ensureConfigured() else {
            addDebugEvent("Wearables SDK unavailable — cannot reset registration")
            return
        }
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
        let interruptedTask = currentLLMTask
        interruptedTask?.cancel()
        currentLLMTask = nil
        isProcessing = false
        speechService.stopThinkingSound()

        guard inConversation else {
            Task { await returnToWakeWord() }
            return
        }

        // Let the cancelled turn finish its cleanup before starting the replacement. Otherwise its
        // finish closure can race the new turn and reset processing/listening state mid-flight.
        Task { @MainActor [weak self] in
            await interruptedTask?.value
            guard let self, self.inConversation, self.listeningEnabled, !self.isProcessing else { return }
            await self.handleTranscription(bargeInText)
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
            // Stop everything: wake word, transcription, TTS, Live Activity — including any
            // in-flight LLM turn, whose finish stage would otherwise resume listening.
            currentLLMTask?.cancel()
            currentLLMTask = nil
            wakeWordService.stopListening()
            transcriptionService.stopRecording()
            speechService.stopSpeaking()
            liveActivityManager.end()
            // Release any audio pause held by an in-flight conversation so Music/Podcasts resume.
            Task { await wakeWordService.forceResumeOtherAudio() }
            isListening = false
            isProcessing = false
            inConversation = false
            activePersona = nil
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
                memoryContext: Config.userMemoryEnabled ? userMemory.systemPromptContext(query: Config.userMemoryRetrievalEnabled ? prompt : nil) : nil
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
            print("📸 Photo + prompt: \(prompt)")

            let rawResponse = try await llmService.sendMessage(
                prompt,
                locationContext: locationService.locationContext,
                imageData: photoData,
                memoryContext: Config.userMemoryEnabled ? userMemory.systemPromptContext(query: Config.userMemoryRetrievalEnabled ? prompt : nil) : nil
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
                    memoryContext: Config.userMemoryEnabled ? userMemory.systemPromptContext(query: Config.userMemoryRetrievalEnabled ? text : nil) : nil
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
        if !isConnected {
            // Recheck before surrendering to the phone camera: the flag can be stale (auto-
            // sleep fired, a Disconnect tap, a dropped link) while the glasses sit on the
            // user's face. One bounded reconnect attempt — the same path the hero capsule uses.
            NSLog("[Photo] Glasses flagged disconnected — rechecking before phone fallback")
            await glassesService.connect()
            for _ in 0..<20 where !isConnected {   // up to 5s
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        guard isConnected else {
            // Genuinely no glasses — fall back to the phone camera (explicit UI).
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
            print("📸 Manual photo captured, sending to LLM for analysis")

            let prompt = "Describe what you see in this image."
            let rawResponse = try await llmService.sendMessage(
                prompt,
                locationContext: locationService.locationContext,
                imageData: photoData,
                memoryContext: Config.userMemoryEnabled ? userMemory.systemPromptContext(query: Config.userMemoryRetrievalEnabled ? prompt : nil) : nil
            )
            var response = Config.userMemoryEnabled ? userMemory.parseAndExecuteCommands(in: rawResponse) : rawResponse
            // A phone-camera capture must SAY so — the phone sees the desk, not what the
            // glasses are pointed at, and an unannounced camera swap reads as hallucination.
            if cameraService.lastCaptureSource == .phone {
                response = "From the phone camera — the glasses weren't available. " + response
            }
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
            chatReadback.stop()
        } else {
            do {
                try await broadcastService.startBroadcast(
                    rtmpURL: Config.broadcastRTMPURL,
                    streamKey: Config.broadcastStreamKey,
                    from: cameraService.framePublisher
                )
                startChatReadbackIfConfigured()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Start chat read-aloud alongside a live broadcast (Plan CI) — opt-in, and only when a
    /// channel is configured (the RTMP stream key is opaque, so the channel can't be derived).
    private func startChatReadbackIfConfigured() {
        guard Config.broadcastChatReadbackEnabled else { return }
        let channel = Config.broadcastChatChannel.trimmingCharacters(in: .whitespaces)
        guard !channel.isEmpty else {
            NSLog("[ChatReadback] enabled but no channel configured — skipping")
            return
        }
        chatReadback.ttsBusy = { [weak self] in
            guard let self else { return true }
            return self.speechService.isSpeaking || self.inConversation || self.isProcessing
        }
        chatReadback.realtimeSessionActive = { [weak self] in
            (self?.geminiLiveSession.isActive ?? false) || (self?.openAIRealtimeSession.isActive ?? false)
        }
        chatReadback.speak = { [weak self] item in
            // Low urgency; the built-in HUD mirror doubles as the plan's ambient chat line.
            await self?.speechService.speak(item.text, urgency: .low)
        }
        chatReadback.start(channel: channel, rules: Config.broadcastChatRules)
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

    // MARK: - Presence-Aware Throttle (Plan W)

    /// Wire the presence monitor's signal sources, the loops it throttles, and re-engagement
    /// surfacing. Called once at launch after the services exist.
    private func configurePresence() {
        // Signal sources (cheap, on-device): DAT connectivity, scene-phase foreground (MLX is
        // foreground-only), live voice activity, and the last explicit command timestamp.
        presenceMonitor.connected = { [weak self] in self?.glassesService.isConnected ?? false }
        presenceMonitor.foreground = { [weak self] in self?.isForegroundActive ?? true }
        presenceMonitor.voiceActive = { [weak self] in self?.wakeWordService.isListening ?? false }
        presenceMonitor.lastInteraction = { [weak self] in self?.lastInteractionAt ?? Date() }
        // CoreMotion activity (Plan W v2): a moving-but-quiet user reads as present, not idle.
        presenceMonitor.motionActive = { [weak self] in self?.motionProvider.isActive ?? false }
        motionProvider.start()

        // Surface anything the supervisor held while the user was away, on re-engagement (TTS + HUD).
        presenceMonitor.onReEngage = { [weak self] in
            guard let self, let line = self.heldRecommendations.drainSummary() else { return }
            Task { @MainActor in await self.speechService.speak(line) }
            self.glassesDisplay.showNotification(title: "Held while away", body: line, icon: .info)
        }

        // The periodic loops that read the throttle decision each tick. Assistive Mode (A3) is an
        // accessibility loop, so it floors at `.present` inside its own tick (never paused by idle).
        LiveCoachService.shared.presence = presenceMonitor
        proactiveAlerts.presence = presenceMonitor
        AssistiveModeService.shared.presence = presenceMonitor
        // Reading is the same shape as captions, not a tick loop: a reader is motionless and silent
        // (so, `.idle`) but very much engaged, and it checks the same `.away`-only gate internally.
        ReadingCompanionService.shared.presence = presenceMonitor

        // Continuous ambient captions can't take a tick multiplier (Plan W v2): a user reading them
        // silently is still engaged, so suspend ONLY when fully away (disconnected/backgrounded) and
        // auto-resume on return. Driven by mode transitions, not the periodic tick.
        let captionToken = presenceMonitor.$mode.sink { [weak self] mode in
            guard let self else { return }
            if CaptionPresenceGate.shouldSuspend(mode: mode) {
                self.ambientCaptions.suspendForPresence()
            } else {
                self.ambientCaptions.resumeForPresence()
            }
        }
        cancellables.append(captionToken)

        // Periodic re-evaluation; also nudged immediately on interaction / scene-phase change.
        presenceTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.presenceMonitor.update() }
        }
        presenceMonitor.update()
    }

    // MARK: - Power Policy (Plan BV P2)

    /// Wire `PowerPolicyService.shared`'s signal sources to the live device signals and drive its
    /// re-evaluation. Phone signals are real (battery / thermals / Low Power Mode); glasses battery
    /// rides `GlassesConnectionService` (nil until firmware reports it) and glasses thermal is left
    /// absent until the DAT device-state stream is observed — a phone-only posture, which the plan
    /// requires to stand on its own. Presence decides *whether* a loop runs; this decides *how
    /// expensively* — deliberately independent services.
    private func configurePower() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let power = PowerPolicyService.shared

        power.phoneBatteryFraction = {
            let level = UIDevice.current.batteryLevel   // -1 when unknown/monitoring off
            return level >= 0 ? Double(level) : nil
        }
        power.phoneCharging = {
            let state = UIDevice.current.batteryState
            return state == .charging || state == .full
        }
        power.phoneThermal = { ThermalPressure(ProcessInfo.processInfo.thermalState) }
        power.glassesBatteryPercent = { [weak self] in self?.glassesService.batteryLevel }
        power.lowPowerMode = { ProcessInfo.processInfo.isLowPowerModeEnabled }

        // Live spenders read the posture in their own terms. Live-mode frame throttlers stretch
        // their interval; more consumers (camera snapshot-first, local-model tier) adopt it as
        // their device passes land.
        let postureToken = power.$posture.sink { posture in
            NSLog("[Power] posture → %@", posture.label)
        }
        cancellables.append(postureToken)

        // Re-evaluate on the OS signals that move the posture, plus a slow periodic backstop for
        // the battery percentage (which has no fine-grained notification).
        let center = NotificationCenter.default
        for name in [UIDevice.batteryLevelDidChangeNotification,
                     UIDevice.batteryStateDidChangeNotification,
                     ProcessInfo.thermalStateDidChangeNotification,
                     Notification.Name.NSProcessInfoPowerStateDidChange] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.powerPolicy.update() }
            }
            cancellables.append(token)
        }
        powerTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.powerPolicy.update() }
        }
        power.update()
    }

    /// Convenience alias for the shared power service (mirrors `presenceMonitor` as a stored ref).
    var powerPolicy: PowerPolicyService { PowerPolicyService.shared }

    // MARK: - Remote Agent Harness (Plan N)

    /// Build the agent harness registry from current config: the OpenClaw gateway adapter plus the
    /// Custom URL adapter (configured from `Config.customAgentHarness`). Rebuilt on settings change.
    private func makeAgentRegistry() -> AgentHarnessRegistry {
        let openClaw = OpenClawAgentHarness(send: { [weak self] method, params in
            guard let self else { throw AgentHarnessError.transport("App unavailable.") }
            return try await self.openClawBridge.agentRequest(method: method, params: params)
        })
        let custom = CustomAgentHarness(config: Config.customAgentHarness ?? CustomHarnessConfig())

        // Codex / Claude Code remote (Plan N Phase 3) — preset-backed HTTP harnesses, ready when a token is set.
        let codex = CustomAgentHarness(
            kind: .codexCloud,
            config: AgentHarnessPreset.codexCloud(token: Config.codexAgentToken, baseURL: Config.codexAgentBaseURL),
            displayName: AgentHarnessKind.codexCloud.displayName,
            isConfigured: !Config.codexAgentToken.isEmpty)
        let claudeCode = CustomAgentHarness(
            kind: .claudeRemote,
            config: AgentHarnessPreset.claudeRemote(token: Config.claudeRemoteToken, baseURL: Config.claudeRemoteBaseURL),
            displayName: AgentHarnessKind.claudeRemote.displayName,
            isConfigured: !Config.claudeRemoteToken.isEmpty)

        return AgentHarnessRegistry([openClaw, custom, codex, claudeCode])
    }

    /// Re-read the Custom endpoint config into the session's registry — call after the user edits the
    /// Remote Agents settings so a new/changed endpoint takes effect without relaunch.
    func rebuildAgentHarnessRegistry() {
        AgentSessionService.shared.setRegistry(makeAgentRegistry())
    }

    /// Note an explicit user interaction (wake word / transcription) for the presence
    /// `lastInteraction` signal, re-evaluating at once so throttled loops resume promptly.
    func noteUserInteraction() {
        lastInteractionAt = Date()
        presenceMonitor.update()
    }

    /// Track foreground/background for the presence `foreground` signal (background ⇒ `away`).
    func notePresenceForeground(_ active: Bool) {
        isForegroundActive = active
        presenceMonitor.update()
    }

    /// Start listening directly — no wake word needed.
    /// Called from Action Button intent or manual mic button.
    /// Transcription will check for persona names in the spoken text.
    func startDirectTranscription() {
        print("🎤 Action Button: starting direct transcription (no wake word)")
        addDebugEvent("ActionButton: direct transcription requested (bg=\(UIApplication.shared.applicationState == .background))")
        Task {
            // Configure audio (uses glasses mic if connected, phone mic otherwise)
            await wakeWordService.configureAudioSession()
            // manual: true — this is an explicit user trigger (Action Button / Siri / tap),
            // so the reply speaks through the phone speaker even with no glasses connected.
            await handleWakeWordDetected(manual: true)
            addDebugEvent("ActionButton: listening started (isListening=\(isListening))")
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
        // The engine-before-listening ordering lives (tested) in ConversationStartSequence.
        await ConversationStartSequence.run(.init(
            beginConversation: { [self] in inConversation = true },
            configureAudioSession: { [self] in await wakeWordService.configureAudioSession() },
            ensureAudioEngineRunning: { [self] in try await wakeWordService.ensureAudioEngineRunning() },
            markListening: { [self] in isListening = true },
            snapshotNowPlaying: { [self] in nowPlayingAtStart = NowPlayingSnapshot.current() },
            pauseOtherAudio: { [self] in await wakeWordService.pauseOtherAudio() },
            playAcknowledgmentTone: { [self] in speechService.playAcknowledgmentTone() },
            startRecording: { [self] in transcriptionService.startRecording() },
            updateLiveActivity: { [self] in updateLiveActivity() }
        ))
    }

    // MARK: - Voice Commands

    /// Pure recognizer for the pre-LLM voice commands (Plan BG P2 groundwork). AppState still owns
    /// the side effects; the phrase matching + persona-prefix stripping live in a tested unit.
    private let voiceCommandParser = VoiceCommandParser.default

    private func isStopCommand(_ text: String) -> Bool { voiceCommandParser.isStop(text) }
    private func isGoodbyeCommand(_ text: String) -> Bool { authorises(.goodbye, text) }
    private func isPhotoCommand(_ text: String) -> Bool { authorises(.photo, text) }

    /// Rebuild the registry's skill-pack tools after an install/remove/enable change (Plan BX).
    func refreshSkillPackTools() {
        nativeToolRegistry.registerSkillPackTools(from: skillPackStore)
    }

    /// Resolve a command candidate, logging any demotion so a field miss is traceable to the clause
    /// that caused it. Counts only, never the words — transcripts stay out of the log.
    private func authorises(_ command: VoiceCommandParser.Command, _ text: String) -> Bool {
        guard let match = voiceCommandParser.match(command, in: text) else { return false }
        if let rule = match.demotedBy {
            NSLog("[Voice] %@ candidate demoted by %@ (%d tokens) — routing as speech",
                  command.rawValue, rule.rawValue, PhraseMatcher.tokenize(text).count)
            addDebugEvent("Voice \(command.rawValue) demoted: \(rule.rawValue)")
        }
        return match.authorises
    }

    /// After finishing or short-circuiting a turn, either keep listening for a follow-up (while a
    /// conversation is active) or drop back to wake-word detection. Replaces the 8+ copy-pasted
    /// `if inConversation { … } else { await returnToWakeWord() }` blocks (Plan BG P2).
    /// - Parameter ensureEngine: run the audio-engine keepalive first — needed after TTS playback,
    ///   which may have interrupted the engine.
    private func resumeListeningOrReturnToWakeWord(ensureEngine: Bool = false) async {
        // The user may have disabled listening while the turn was finishing — a finish stage
        // must never turn the microphone back on behind their back.
        guard listeningEnabled else { return }
        if inConversation {
            if ensureEngine { try? await wakeWordService.ensureAudioEngineRunning() }
            // The engine keepalive suspends; re-check the user didn't flip the toggle meanwhile.
            guard listeningEnabled, inConversation else { return }
            isListening = true
            transcriptionService.startRecording()
        } else {
            await returnToWakeWord()
        }
    }

    /// The ordered pre-LLM voice-command chain (Plan BG P2). Each handler checks the transcript and,
    /// if it applies, drives its mode and resumes listening, reporting that it consumed the turn so
    /// the flow stops before the LLM. Order is preserved exactly from the original if-ladder:
    /// teleprompter → HUD task → launcher select → launcher open → intent-ignore filter.
    private func preLLMHandlers() -> [VoiceCommandHandler] {
        [
            // Teleprompter (Phase 2): while a session is running it owns the display, so
            // "next/back/pause/resume/restart/faster/slower/stop" drive the prompter rather than
            // the LLM. Checked first since it's a focused, full-screen mode.
            VoiceCommandHandler(label: "teleprompter") { [weak self] text in
                guard let self, self.teleprompterService.isActive,
                      self.teleprompterService.handleVoiceCommand(text) else { return false }
                print("📜 Teleprompter command handled: \(text)")
                await self.resumeListeningOrReturnToWakeWord()
                return true
            },
            // HUD task control (Display Phase 3 / Plan X): while a Now/Next card is on the glasses,
            // "next/done/skip/back" drive the task instead of the LLM. Before intent classification
            // so these short commands aren't filtered.
            VoiceCommandHandler(label: "hud-task") { [weak self] text in
                guard let self, await self.hudRouter.handleVoiceCommand(text) else { return false }
                print("🎯 HUD task command handled: \(text)")
                await self.resumeListeningOrReturnToWakeWord()
                return true
            },
            // HUD launcher voice nav (Display Phase 4 / Plan Y): while a menu is open, a spoken item
            // label (or "back"/"close") selects it. Before the open command so saying a leaf name
            // inside the menu navigates instead of re-opening the root.
            VoiceCommandHandler(label: "hud-launcher-select") { [weak self] text in
                guard let self, self.hudLauncher.handleVoiceSelection(text) else { return false }
                print("🎛 HUD launcher voice selection: \(text)")
                await self.resumeListeningOrReturnToWakeWord()
                return true
            },
            // HUD launcher (Display Phase 4 / Plan Y): "menu" opens the band-navigable launcher.
            VoiceCommandHandler(label: "hud-launcher-open") { [weak self] text in
                guard let self, HUDLauncher.isOpenCommand(text), self.hudLauncher.hasContent else { return false }
                print("🎛 HUD launcher opened")
                self.hudLauncher.open()
                await self.resumeListeningOrReturnToWakeWord()
                return true
            },
            // Notification digest (Plan BZ): "what's new" / "catch me up" pulls up the glance.
            // Global — works with or without a task card; strict whole-phrase match only.
            VoiceCommandHandler(label: "digest-briefing") { [weak self] text in
                guard let self, Config.digestEnabled,
                      HUDVoiceCommand.parse(text) == .briefing else { return false }
                print("📋 Digest briefing requested")
                await self.notificationDigest.presentGlance()
                await self.resumeListeningOrReturnToWakeWord()
                return true
            },
            // Intent classification — filter bystander/filler speech.
            VoiceCommandHandler(label: "intent-ignore") { [weak self] text in
                guard let self, self.intentClassifier.isEnabled,
                      !self.isPhotoCommand(text), !self.isStopCommand(text), !self.isGoodbyeCommand(text)
                else { return false }
                guard await self.intentClassifier.classify(transcript: text) == .ignore else { return false }
                print("🚫 Intent classifier: IGNORE — not responding")
                await self.resumeListeningOrReturnToWakeWord()
                return true
            },
        ]
    }

    /// The post-store voice-command chain (Plan BG P2): stop, goodbye, and photo. These run after
    /// the user's turn is persisted to the conversation store and after persona detection, so the
    /// photo handler prompts the LLM with the persona-stripped `query` while command matching uses
    /// the raw transcript. Same first-consumer-wins contract as `preLLMHandlers`.
    private func postStoreHandlers(query: String) -> [VoiceCommandHandler] {
        [
            // "stop" — interrupt TTS, stay in conversation
            VoiceCommandHandler(label: "stop") { [weak self] text in
                guard let self, self.isStopCommand(text) else { return false }
                print("🛑 Voice command: stop")
                self.speechService.stopSpeaking()
                if self.inConversation { print("💬 Stopped — listening for next question...") }
                await self.resumeListeningOrReturnToWakeWord()
                return true
            },
            // "goodbye" — end conversation, back to wake word
            VoiceCommandHandler(label: "goodbye") { [weak self] text in
                guard let self, self.isGoodbyeCommand(text) else { return false }
                print("👋 Voice command: goodbye")
                self.speechService.stopSpeaking()
                self.inConversation = false
                self.lastResponse = "Goodbye!"
                await self.speechService.speak("Goodbye!")
                await self.returnToWakeWord()
                return true
            },
            // "take a picture" — capture photo from glasses camera, describe via the vision LLM
            VoiceCommandHandler(label: "photo") { [weak self] text in
                guard let self, self.isPhotoCommand(text) else { return false }
                print("📸 Voice command: take a picture")
                self.isProcessing = true
                // Start capture immediately — play the shutter tone, no spoken "taking a picture"
                self.speechService.playAcknowledgmentTone()
                self.speechService.startThinkingSound()

                self.currentLLMTask = Task {
                    await ConversationTurnRunner.run(.init(
                        send: {
                            // Capture and send to LLM concurrently — no extra round-trip speech
                            let photoData = try await self.cameraService.capturePhoto()
                            try Task.checkCancellation()
                            // Restore audio for wake word after camera capture (camera reconfigures for Bluetooth)
                            self.cameraService.restoreAudioForWakeWord()
                            print("📸 Photo captured, sending to LLM with prompt: \(query)")

                            return try await self.llmService.sendMessage(
                                query,
                                locationContext: self.locationService.locationContext,
                                imageData: photoData,
                                memoryContext: Config.userMemoryEnabled ? self.userMemory.systemPromptContext(query: Config.userMemoryRetrievalEnabled ? query : nil) : nil
                            )
                        },
                        postProcess: { rawResponse in
                            var response = Config.userMemoryEnabled ? self.userMemory.parseAndExecuteCommands(in: rawResponse) : rawResponse
                            // Phone-camera captures must announce themselves (see captureAndAnalyzePhoto).
                            if self.cameraService.lastCaptureSource == .phone {
                                response = "From the phone camera — the glasses weren't available. " + response
                            }
                            return response
                        },
                        accept: { response in
                            self.lastResponse = response
                            if Config.conversationPersistenceEnabled {
                                self.conversationStore.appendMessage(role: "assistant", content: response)
                            }
                            print("🤖 \(self.llmService.activeModelName) (vision): \(response)")

                            // If an audio or video recording is active, inject the description
                            // into the caption history so the meeting assistant has visual context.
                            if self.audioRecorder.isRecording || self.videoRecorder.isRecording {
                                self.ambientCaptions.insertVisualNote(response)
                            }
                        },
                        speak: { response in
                            // Start wake word listener during TTS so user can say "stop"
                            self.startStopListener()
                            await self.speechService.speak(response)
                            self.stopStopListener()
                        },
                        onCancelled: {
                            print("🛑 Photo/LLM task cancelled")
                        },
                        onError: { error in
                            self.cameraService.restoreAudioForWakeWord()
                            print("📸 Photo capture failed: \(error)")
                            self.lastResponse = "Photo failed: \(error.localizedDescription)"
                            // Speak a human sentence; raw error internals (DecodingError
                            // paths, model module trees) go to the log only — live-traced:
                            // TTS once read out "keyNotFound(path: [language_model…".
                            await self.speechService.speak(
                                "Sorry, I couldn't take a photo or process the image. \(SpokenErrorPolicy.spokenReason(for: error))")
                        },
                        finish: {
                            self.isProcessing = false
                            self.speechService.stopThinkingSound()
                            await self.resumeListeningOrReturnToWakeWord(ensureEngine: true)
                        }
                    ))
                }
                return true
            },
        ]
    }

    /// Reuse an already-available live frame for vision-capable models without trying to
    /// start the camera. This avoids re-triggering fragile Meta camera permission flows.
    private func currentVisionFrameDataIfAvailable() -> Data? {
        guard Config.activeModel?.visionEnabled == true else { return nil }
        // Frame pinning (Plan CE): a held pin IS the referent — multi-turn "and the label? and
        // the connector?" interrogates the same scene, whether or not the camera still streams.
        if Config.framePinEnabled, let pinned = framePin.pinnedFrame,
           let pinnedData = pinned.jpegData(compressionQuality: Config.geminiLiveVideoJPEGQuality),
           !LLMImagePreparer.isDegenerate(pinnedData) {
            return pinnedData
        }
        guard cameraService.isStreaming, let frame = cameraService.latestFrame else { return nil }
        guard let data = frame.jpegData(compressionQuality: Config.geminiLiveVideoJPEGQuality),
              !LLMImagePreparer.isDegenerate(data) else { return nil }
        return data
    }

    // MARK: - Frame Pinning (Plan CE)

    /// Pin the current camera frame: the model receives nothing newer until release. The exact
    /// pinned frame is pushed to the live session immediately (sharp-inject, bypassing the
    /// throttler), so the model's referent is the on-screen frame, not whatever the throttler
    /// last sampled. Returns false when there's nothing to pin.
    @discardableResult
    func pinCurrentFrame() -> Bool {
        guard Config.framePinEnabled, let frame = cameraService.latestFrame else { return false }
        framePin.pin(frame: frame)
        framePinGate.reset()
        injectPinnedFrame()
        framePinGate.notePinnedPushed(now: Date().timeIntervalSinceReferenceDate)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        glassesDisplay.flash("📌 Pinned")
        NSLog("[FramePin] Pinned frame (%.0f×%.0f)", frame.size.width, frame.size.height)
        return true
    }

    /// Release a held pin for `trigger` (policy-gated; a no-op when nothing is pinned). The
    /// per-session frame gates reset so the first live frame after release goes through as a
    /// keyframe rather than being deduped against the pin.
    func releaseFramePin(trigger: FramePinReleaseTrigger) {
        guard FramePinReleasePolicy.shouldRelease(on: trigger), framePin.unpin() else { return }
        framePinGate.reset()
        geminiLiveSession.resetFrameGateAfterPin()
        openAIRealtimeSession.resetFrameGateAfterPin()
        if trigger == .explicitUnpin {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            glassesDisplay.flash("Pin released")
        }
        NSLog("[FramePin] Released (%@)", String(describing: trigger))
    }

    /// Sharp-inject the pinned frame into the active live session (no-op outside live modes —
    /// Direct mode reads the pin at photo time instead).
    private func injectPinnedFrame() {
        guard let frame = framePin.pinnedFrame,
              let jpeg = frame.jpegData(compressionQuality: 0.8) else { return }
        activeLiveInjector?.injectSharpImage(jpegData: jpeg)
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

        // If camera is already streaming, just grab the frame — but never a degenerate
        // placeholder (don't restart a running stream over a bad frame; just send no image).
        if cameraService.isStreaming, let frame = cameraService.latestFrame {
            guard let data = frame.jpegData(compressionQuality: Config.geminiLiveVideoJPEGQuality),
                  !LLMImagePreparer.isDegenerate(data) else { return nil }
            return data
        }

        // Try to start streaming and capture
        do {
            try await cameraService.startStreaming()
            // Brief wait for first frame
            try await Task.sleep(nanoseconds: 500_000_000)
            if let frame = cameraService.latestFrame,
               let data = frame.jpegData(compressionQuality: Config.geminiLiveVideoJPEGQuality),
               !LLMImagePreparer.isDegenerate(data) {
                print("📷 Smart Camera: captured frame")
                return data
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

    /// BK P2c — speak a one-line "switching model" notice on the FIRST fallback hop of a turn.
    /// Only wired into the interactive voice/typed send paths (notification triage / scheduled runs
    /// don't cascade), so this is inherently interactive-only per Plan W's presence principle.
    /// Restarts the thinking sound afterwards — `speak()` stops it, and the turn hasn't finished, so
    /// without this the retry latency would be the exact dead air the notice was meant to fill.
    @MainActor
    private func narrateModelSwitch(from: ModelConfig?, to: ModelConfig?,
                                    failure: ModelFallbackChain.FailureClass) async {
        guard Config.narrateModelSwitchesEnabled, !didNarrateModelSwitchThisTurn else { return }
        didNarrateModelSwitchThisTurn = true
        let phrase = ModelSwitchNarrator.fallbackPhrase(
            from: .init(name: from?.name ?? "the model", isLocal: from?.llmProvider == .local),
            to: .init(name: to?.name ?? "another model", isLocal: to?.llmProvider == .local),
            failure: failure)
        await speechService.speak(phrase, urgency: .low, mirrorToHUD: true)
        speechService.startThinkingSound()
    }

    /// Plan CG: render an explicit multiple-choice reply as band-selectable HUD buttons.
    /// Selection re-enters the conversation exactly like a spoken utterance would.
    private func presentChoiceButtonsIfDetected(in response: String) {
        guard Config.hudChoiceButtonsEnabled else { return }
        let choices = ChoiceDetector.detect(in: response)
        guard !choices.isEmpty else { return }

        let items = choices.enumerated().map { index, choice in
            HUDItem(id: "choice-\(index)", label: choice.label, action: {})
        }
        glassesDisplay.present(screen: HUDScreen(title: "Choose", items: items)) { [weak self] id in
            guard let self,
                  let index = Int(id.dropFirst("choice-".count)),
                  choices.indices.contains(index) else { return }
            Task { await self.sendTextMessage(choices[index].spokenForm) }
        }
    }

    func handleTranscription(_ text: String) async {
        // Shared consent surface, voice half (BN P1): while an approve/deny prompt is pending, a
        // short spoken yes/no answers THE PROMPT — never the model. Checked before the
        // isProcessing guard because the turn that raised the prompt is still in flight,
        // suspended on the coordinator.
        if toolConfirmationCoordinator.pending != nil, toolConfirmationCoordinator.resolveByVoice(text) {
            currentTranscription = text
            print("🛡️ Consent prompt answered by voice: \(text)")
            return
        }
        guard !isProcessing else {
            print("⚠️ Already processing, ignoring: \(text)")
            return
        }

        currentTranscription = text
        isListening = false
        errorMessage = nil
        speechService.playEndListeningTone()
        print("📝 Transcription: \(text)")
        addDebugEvent("Transcription: \(String(text.prefix(80)))")

        // Pre-LLM voice-command chain (Plan BG P2): teleprompter, HUD task card, HUD launcher
        // selection/open, and the intent-ignore filter each get first crack at the transcript. The
        // first one that consumes it drives its own mode and short-circuits before the LLM. Order
        // matters and is preserved from the original if-ladder (see `preLLMHandlers`).
        if await ConversationFlowEngine(handlers: preLLMHandlers()).route(text) != nil {
            return
        }

        // Will be updated below if persona detected in text
        var query = text

        // Check for persona names in the transcription (for Action Button / push-to-talk mode)
        // e.g. "Hey Claude, what's the weather" → activate Claude persona, strip prefix.
        // Recognition + stripping is pure (VoiceCommandParser); AppState applies the match.
        // Runs even with a persona active so "hey travel" can switch away from another persona
        // mid-session (wake-word mode always could); re-matching the ACTIVE persona's own
        // phrase just strips the prefix without re-applying routing.
        do {
            let personas = Config.enabledPersonas
            let personaPhrases = personas.map {
                VoiceCommandParser.PersonaPhrases(id: $0.id, phrases: $0.allPhrases)
            }
            if let match = voiceCommandParser.detectPersona(in: text, personas: personaPhrases),
               let persona = personas.first(where: { $0.id == match.personaId }) {
                if persona.id != activePersona?.id {
                    applyPersonaRouting(persona)
                    print("🎭 Persona detected in transcription: \(persona.name)")
                }
                query = match.query
            }
        }

        // Track in conversation store
        if Config.conversationPersistenceEnabled {
            if conversationStore.activeThreadId == nil {
                conversationStore.startThread(mode: currentMode.rawValue, personaId: activePersona?.id)
            }
            conversationStore.appendMessage(role: "user", content: text)
        }

        // Post-store voice-command chain (Plan BG P2): stop, goodbye, photo. Runs after the user
        // turn is persisted (so "stop"/"goodbye" still appear in the thread) and after persona
        // detection (the photo prompt uses the persona-stripped `query`). The first consumer
        // short-circuits before the LLM; order is preserved from the original if-ladder.
        if await ConversationFlowEngine(handlers: postStoreHandlers(query: query)).route(text) != nil {
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

                // Follow-up continuity: the LLM never saw this exchange (tier-0 bypasses
                // it) — record it in the model's history so "what about tomorrow?" can
                // refer back to the forecast just spoken.
                llmService.recordExternalExchange(user: query, assistant: result)

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
                await resumeListeningOrReturnToWakeWord(ensureEngine: true)
                return
            }
        }

        // Tier 2: Model selection (Plan BG P2). The pure `ModelRoutingPolicy` decides between the
        // on-device agent model, a temporary switch to the tier-recommended model, and keeping the
        // active one; this applies the chosen route's side effects.
        didNarrateModelSwitchThisTurn = false   // BK P2c: fresh per-turn narration budget
        var originalModelId: String?
        var useLocalAgent = false
        let agentIsCloud = Config.savedModels.contains(where: { $0.id == Config.agentModelId })
        let tierModel = Config.modelForTier(classification.modelTier)
        switch ModelRoutingPolicy.decide(
            isFastTier: classification.modelTier == .fast,
            agentModeEnabled: Config.agentModeEnabled,
            agentModelDownloaded: Config.agentModelDownloaded,
            agentIsCloud: agentIsCloud,
            localAgentEnabled: Config.localAgentEnabled,
            isPhoto: isPhotoCommand(query),
            autoRoutingEnabled: Config.autoModelRoutingEnabled,
            tierModelId: tierModel?.id,
            activeModelId: Config.activeModelId
        ) {
        case .localAgent:
            useLocalAgent = true
            print("🧠 Routing to agent model (fast tier, agentic mode)\(agentIsCloud ? " [cloud]" : " [on-device]")")
        case .switchModel(let id):
            originalModelId = Config.activeModelId
            Config.setActiveModelId(id)
            llmService.refreshActiveModel()
            print("🧭 Model routed: \(classification.modelTier.rawValue) → \(tierModel?.name ?? id)")
            // BK P2c: narrate the auto-routing switch too, so the principle holds everywhere a model
            // changes under the user (not just on failure). Speaks before the thinking sound starts.
            if Config.narrateModelSwitchesEnabled, let dest = tierModel {
                didNarrateModelSwitchThisTurn = true
                await speechService.speak(
                    ModelSwitchNarrator.routingPhrase(to: .init(name: dest.name, isLocal: dest.llmProvider == .local)),
                    urgency: .low, mirrorToHUD: true)
            }
        case .keepCurrent:
            break
        }

        // Normal message — send to LLM (with Tier 1 prompt trimming via sections)
        isProcessing = true
        speechService.startThinkingSound()

        // Run the turn inside a tracked, cancellable task (Plan BG P2). Barge-in / stop / cancel
        // cancel it, so a normal text turn no longer speaks its now-stale response after the user
        // interrupts — previously only the photo path was cancellable, so a barged-in text turn
        // would still speak the earlier answer once the LLM call returned.
        currentLLMTask = Task {
            await ConversationTurnRunner.run(.init(
                send: { [self] in
                    let rawResponse: String
                    let backgrounded = UIApplication.shared.applicationState == .background
                    // A location-flavored turn with no fix yet gets a brief one-shot await
                    // (cold launch / backgrounded when-in-use) instead of a location-less prompt.
                    let locationCtx: String?
                    if classification.relevantSections.contains(.location) {
                        locationCtx = await locationService.awaitLocationContext()
                    } else {
                        locationCtx = nil
                    }
                    let memoryCtx = Config.userMemoryEnabled ? userMemory.systemPromptContext(query: Config.userMemoryRetrievalEnabled ? query : nil) : nil
                    // Cloud send with automatic model fall-over (BK P2b): active model leads, then
                    // the user's fallback order — spills on overflow / rate-limit / empty completion.
                    func cloudCascade() async throws -> String {
                        let imageData = await smartCameraImageData(for: query)
                        return try await llmService.sendMessageCascading(
                            query,
                            locationContext: locationCtx,
                            imageData: imageData,
                            memoryContext: memoryCtx,
                            // Unconditional like the photo path: the classifier never sets .playbook
                            // (mid-playbook utterances — "done", "next" — match no keyword list), and
                            // playbookContext() already returns nil when no playbook is active.
                            playbookContext: playbookStore.playbookContext(),
                            nowPlayingContext: nowPlayingAtStart?.promptContext,
                            shortcutsContext: ShortcutsCatalog.shared.promptBlock(),
                            promptSections: classification.relevantSections,
                            backgrounded: backgrounded,
                            onModelSwitch: { [self] from, to, failure in
                                await narrateModelSwitch(from: from, to: to, failure: failure)
                            }
                        )
                    }
                    // Hermes agent bridge (Plan CL P5): when enabled (Agent Mode), the
                    // bridge is the brain for the turn — it runs its own tools/memory and
                    // may request a photo mid-query. Any failure falls through to the
                    // normal local/cloud path so the bridge can never strand a turn.
                    if hermesBridge.isEnabled {
                        do {
                            let bridged = try await hermesBridge.ask(query)
                            nowPlayingAtStart = nil
                            return bridged
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            addDebugEvent("Hermes bridge failed (\(error.localizedDescription)) — using normal path")
                        }
                    }
                    if useLocalAgent {
                        // Weather-decision turn ("do I take a jacket"): pre-fetch the forecast
                        // into the prompt. A 2B model asked to *act* stalls in ever-new
                        // phrasings (live-traced); handed the data, it just answers. ~200ms,
                        // local path only — cloud models tool-call fine on their own.
                        var weatherCtx: String?
                        if classification.relevantSections.contains(.weather) {
                            weatherCtx = try? await nativeToolRegistry.executeTool(
                                name: "get_weather", arguments: [:])
                        }
                        // Fast path: on-device Gemma 4 agent — but spill to the cloud cascade if it
                        // can't serve the turn (BK P2b: prefer local for cost, fall over to cloud).
                        do {
                            rawResponse = try await llmService.sendViaLocalAgent(
                                query,
                                locationContext: locationCtx,
                                memoryContext: memoryCtx,
                                weatherContext: weatherCtx
                            )
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            guard Config.modelCascadeEnabled,
                                  ModelFallbackChain.classify(error) != .terminalForTurn,
                                  !Task.isCancelled else { throw error }
                            print("🔀 Local agent failed (\(error)) — cascading to cloud")
                            rawResponse = try await cloudCascade()
                        }
                    } else {
                        rawResponse = try await cloudCascade()
                    }
                    nowPlayingAtStart = nil  // consumed for this turn
                    return rawResponse
                },
                postProcess: { [self] rawResponse in
                    // Parse and execute memory commands from the response
                    guard Config.userMemoryEnabled else { return rawResponse }
                    let response = userMemory.parseAndExecuteCommands(in: rawResponse)

                    // Periodic nudge: after N turns, inject a hidden review prompt
                    // into the LLM history so the next response considers what to remember
                    if userMemory.incrementTurnAndCheckNudge() {
                        llmService.injectSystemMessage(SemanticMemoryStore.nudgePrompt)
                    }
                    return response
                },
                accept: { [self] response in
                    lastResponse = response
                    print("🤖 \(llmService.activeModelName): \(response)")

                    // Save to conversation store
                    if Config.conversationPersistenceEnabled {
                        conversationStore.appendMessage(role: "assistant", content: response)
                    }
                },
                speak: { [self] response in
                    // Start wake word listener during TTS so user can say "stop"
                    startStopListener()
                    await speechService.speak(response)
                    stopStopListener()
                },
                onCancelled: {
                    print("🛑 LLM turn cancelled")
                },
                onError: { [self] error in
                    errorMessage = "Failed to get response: \(error.localizedDescription)"
                    // BK P2c: when the cascade is exhausted, speak the real reason instead of the
                    // generic line (e.g. "the last one was rate-limited"), so the app stays honest
                    // about what happened. Off ⇒ the generic line.
                    let spoken = Config.narrateModelSwitchesEnabled
                        ? ModelSwitchNarrator.exhaustionPhrase(lastError: error)
                        : "Sorry, I encountered an error."
                    await speechService.speak(spoken)
                },
                finish: { [self] in
                    // Restore original model if we switched for this request
                    if let originalId = originalModelId {
                        Config.setActiveModelId(originalId)
                        llmService.refreshActiveModel()
                    }

                    // After responding, stay in conversation — listen for follow-up
                    isProcessing = false
                    speechService.stopThinkingSound()
                    if inConversation { print("💬 Continuing conversation — listening for follow-up...") }
                    await resumeListeningOrReturnToWakeWord(ensureEngine: true)
                }
            ))
        }
    }

    // MARK: - Text Message Input

    /// Send a typed text message (with optional image) to the LLM — same pipeline as voice.
    /// Send a text query through the full LLM/persona pipeline.
    /// - Parameter speakResponse: when `false`, the answer is not read aloud via the
    ///   internal TTS engine. Used by the Siri "ask a question" intent, where Siri
    ///   itself speaks the returned dialog (avoids the response being spoken twice).
    func sendTextMessage(_ text: String, imageData: Data? = nil, speakResponse: Bool = true) async {
        guard !isProcessing else { return }
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        currentTranscription = query
        isListening = false
        errorMessage = nil

        // Track in conversation store
        if Config.conversationPersistenceEnabled {
            if conversationStore.activeThreadId == nil {
                conversationStore.startThread(mode: currentMode.rawValue, personaId: activePersona?.id)
            }
            // User-correction signal (Plan AW): before logging this turn, if it corrects the
            // previous answer, feed it to the skill-evolution loop (Agent-Mode-gated, no-op otherwise).
            if let prev = conversationStore.lastExchange() {
                await SkillEvolutionService.shared.noteUserTurn(
                    message: query, priorPrompt: prev.prompt, priorResponse: prev.response)
            }
            conversationStore.appendMessage(role: "user", content: query, imageAttached: imageData != nil)
        }

        isProcessing = true
        didNarrateModelSwitchThisTurn = false   // BK P2c: fresh per-turn narration budget
        speechService.startThinkingSound()

        // Live-stream the reply into the Chat thread (where the provider supports it).
        let streamThreadId = conversationStore.activeThreadId
        if let streamThreadId { streamingTurn = StreamingTurn(threadId: streamThreadId, text: "") }

        // Typed turns run the same skeleton as voice turns, tracked in `currentLLMTask` so
        // barge-in / cancel stops a typed turn too (Plan BG P2: every turn is cancellable).
        // Awaited so callers (Siri intent, askUnderPersona) still see the turn complete.
        let turn = Task {
            await ConversationTurnRunner.run(.init(
                send: { [self] in
                    // Use provided image, or fall back to smart camera if no image attached
                    let image: Data?
                    if let imageData {
                        image = imageData
                    } else {
                        image = await smartCameraImageData(for: query)
                    }
                    return try await llmService.sendMessageCascading(
                        query,
                        locationContext: locationService.locationContext,
                        imageData: image,
                        memoryContext: Config.userMemoryEnabled ? userMemory.systemPromptContext(query: Config.userMemoryRetrievalEnabled ? query : nil) : nil,
                        playbookContext: playbookStore.playbookContext(),
                        shortcutsContext: ShortcutsCatalog.shared.promptBlock(),
                        backgrounded: UIApplication.shared.applicationState == .background,
                        onToken: { [weak self] chunk in
                            guard let self, let id = streamThreadId else { return }
                            if self.streamingTurn?.threadId == id { self.streamingTurn?.text += chunk }
                        },
                        onStreamReset: { [weak self] in
                            // A new tool-loop iteration is starting (BM P9): drop the previous
                            // iteration's text so the bubble never shows intermediate+final concatenated.
                            guard let self, let id = streamThreadId else { return }
                            if self.streamingTurn?.threadId == id { self.streamingTurn?.text = "" }
                        },
                        onModelSwitch: { [self] from, to, failure in
                            guard speakResponse else { return }   // silent when Siri speaks the reply
                            await narrateModelSwitch(from: from, to: to, failure: failure)
                        }
                    )
                },
                postProcess: { [self] rawResponse in
                    Config.userMemoryEnabled ? userMemory.parseAndExecuteCommands(in: rawResponse) : rawResponse
                },
                accept: { [self] response in
                    lastResponse = response
                    streamingTurn = nil  // clear before persisting so the live bubble doesn't duplicate the saved message

                    if Config.conversationPersistenceEnabled {
                        conversationStore.appendMessage(role: "assistant", content: response)
                    }

                    // Memory loop (Phase 3): spot a durable fact or a repeated multi-step request and
                    // offer to remember it (or silently save it in Agent Mode).
                    MemoryLoopService.shared.observeTurn(userText: query, assistantText: response,
                                                         toolNames: nativeToolRouter.takeTurnToolNames())

                    // Plan CG: an explicit multiple-choice reply renders as band-selectable
                    // HUD buttons; selecting one feeds the option back as the next user turn.
                    if speakResponse { presentChoiceButtonsIfDetected(in: response) }
                },
                speak: { [self] response in
                    // Speak the response (user can still say "stop")
                    guard speakResponse else { return }
                    startStopListener()
                    await speechService.speak(response)
                    stopStopListener()
                },
                onCancelled: { [self] in
                    streamingTurn = nil
                    print("🛑 Text turn cancelled")
                },
                onError: { [self] error in
                    streamingTurn = nil
                    errorMessage = "Failed to get response: \(error.localizedDescription)"
                    if speakResponse {
                        // BK P2c: speak the real exhaustion reason, not the generic line.
                        let spoken = Config.narrateModelSwitchesEnabled
                            ? ModelSwitchNarrator.exhaustionPhrase(lastError: error)
                            : "Sorry, I encountered an error."
                        await speechService.speak(spoken)
                    }
                },
                finish: { [self] in
                    isProcessing = false
                    speechService.stopThinkingSound()
                }
            ))
        }
        currentLLMTask = turn
        await turn.value
    }

    /// Run a one-shot query under a specific persona, then restore the prior
    /// active model/preset/persona. Used by the Siri persona intent so a persona
    /// ask doesn't permanently switch the user's active setup. `sendMessage`
    /// reads `Config.activeModel` per call, so switching here routes this turn to
    /// the persona's model (mirrors the wake-word persona-routing path).
    func askUnderPersona(_ persona: Persona, question: String) async {
        let prevModelId = Config.activeModelId
        let prevPresetId = Config.activePresetId
        let prevPersona = activePersona

        applyPersonaRouting(persona)

        await sendTextMessage(question, speakResponse: false)

        Config.setActiveModelId(prevModelId)
        Config.setActivePresetId(prevPresetId)
        activePersona = prevPersona
        llmService.refreshActiveModel()
    }

    /// Single owner of the push-to-talk switch (Settings toggle + home-screen BarButton both
    /// call this): persists the flag and stops/starts the always-on wake-word mic to match.
    func setPushToTalk(_ enabled: Bool) {
        Config.setSilentMode(enabled)
        if enabled {
            wakeWordService.stopListening()
            isListening = false
        } else {
            Task { try? await wakeWordService.startListening() }
        }
    }

    /// Restart the wake-word listener after settings changes that affect it (Direct mode only).
    func restartWakeWordIfDirect() {
        guard currentMode == .direct else { return }
        Task {
            wakeWordService.stopListening()
            try? await Task.sleep(nanoseconds: 300_000_000)
            try? await wakeWordService.startListening()
        }
    }

    /// Apply a persona's routing: persona + prompt preset, and its model ONLY when it names one.
    /// All built-in mode templates ship `modelId: ""` meaning "keep the user's current model" —
    /// setting that blindly hit `activeModelId`'s empty-id fallback and silently reset the
    /// active model to the FIRST saved model (live-traced: "hey travel" kicked the user off
    /// their selected local model).
    func applyPersonaRouting(_ persona: Persona) {
        activePersona = persona
        if !persona.modelId.isEmpty {
            Config.setActiveModelId(persona.modelId)
        }
        Config.setActivePresetId(persona.presetId)
        llmService.refreshActiveModel()
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

    // MARK: - Remote Invoke (Plan BH)

    /// Build the remote-invoke pipeline: pure parser/policy/reply + an executor whose stage
    /// bodies map onto the live services. Capture-class commands confirm via the same
    /// `ToolConfirmationCoordinator` UX as high-impact tools, then announce over TTS before any
    /// sensor starts — nothing remote is ever silent.
    private func makeRemoteInvokeService() -> RemoteInvokeService {
        let executor = RemoteCommandExecutor(deps: .init(
            confirmCapture: { [weak self] summary in
                guard let self else { return false }
                return await self.toolConfirmationCoordinator.requestConfirmation(
                    toolName: "remote_invoke", summary: summary)
            },
            announce: { [weak self] text in
                await self?.speechService.speak(text)
            },
            capturePhoto: { [weak self] in
                guard let self else { throw RemoteInvokeError.unavailable }
                let data = try await self.cameraService.capturePhoto()
                self.cameraService.restoreAudioForWakeWord()
            },
            startAudioRecording: { [weak self] in
                guard let self else { throw RemoteInvokeError.unavailable }
                try self.audioRecorder.startRecording()
            },
            stopAudioRecording: { [weak self] in
                guard let self else { return nil }
                return await self.audioRecorder.stopRecording()?.lastPathComponent
            },
            startVideo: { [weak self] in
                guard let self else { throw RemoteInvokeError.unavailable }
                if !self.cameraService.isStreaming {
                    try await self.cameraService.startStreaming()
                }
                let frameSize = self.cameraService.latestFrame?.size ?? CGSize(width: 720, height: 1280)
                try self.videoRecorder.startRecording(
                    from: self.cameraService.framePublisher,
                    bitrate: max(Config.recordingBitrate, 4_000_000),
                    outputSize: frameSize
                )
            },
            stopVideo: { [weak self] in
                guard let self else { return nil }
                return await self.videoRecorder.stopRecording()?.lastPathComponent
            },
            startTranslation: { [weak self] source, target in
                Task { await self?.liveTranslation.start(from: source ?? "auto", to: target ?? "en") }
            },
            stopTranslation: { [weak self] in
                self?.liveTranslation.stop()
            },
            startTranscription: { [weak self] in
                self?.ambientCaptions.start()
            },
            stopTranscription: { [weak self] in
                self?.ambientCaptions.stop()
            },
            speak: { [weak self] text in
                await self?.speechService.speak(text)
            },
            displayShow: { [weak self] text, icon in
                guard let self, self.glassesDisplay.deviceSupportsDisplay() else { return false }
                self.glassesDisplay.showNotification(title: "Agent", body: text, icon: Self.remoteHUDIcon(for: icon))
                return true
            },
            displayClear: { [weak self] in
                self?.glassesDisplay.clear()
            },
            deviceStatus: { [weak self] in
                guard let self else { return [:] }
                return [
                    "glasses_connected": String(self.glassesService.isConnected),
                    "device_name": self.glassesService.deviceName ?? "none",
                    "battery": self.glassesService.batteryLevel.map(String.init) ?? "unknown",
                    "listening": String(self.isListening),
                    "recording_audio": String(self.audioRecorder.isRecording),
                    "recording_video": String(self.videoRecorder.isRecording),
                    "transcribing": String(self.ambientCaptions.isActive),
                    "translating": String(self.liveTranslation.isActive),
                ]
            },
            deviceCapabilities: { [weak self] in
                guard let self else { return [:] }
                // What is *currently* true, not what the app theoretically has.
                return [
                    "camera": String(self.glassesService.isConnected),
                    "display": String(self.glassesDisplay.deviceSupportsDisplay()),
                    "speak": "true",
                    "audio_recording": "true",
                    "video_recording": String(self.glassesService.isConnected),
                    "transcription": "true",
                    "translation": "true",
                    "notes": "true",
                ]
            },
            addNote: { [weak self] text in
                guard let self else { throw RemoteInvokeError.unavailable }
                return try await self.nativeToolRouter.registry.executeTool(
                    name: "save_note", arguments: ["content": text])
            },
            getTranscript: { [weak self] in
                guard let self else { return "" }
                // History is newest-first; reply chronologically, bounded.
                return self.ambientCaptions.captionHistory.prefix(20).reversed()
                    .map { $0.text }.joined(separator: "\n")
            },
            stopAll: { [weak self] in
                guard let self else { return }
                self.speechService.stopSpeaking()
                if self.audioRecorder.isRecording { _ = await self.audioRecorder.stopRecording() }
                if self.videoRecorder.isRecording { _ = await self.videoRecorder.stopRecording() }
                if self.ambientCaptions.isActive { self.ambientCaptions.stop() }
                if self.liveTranslation.isActive { self.liveTranslation.stop() }
            }
        ))
        return RemoteInvokeService(
            environment: .init(
                agentModeEnabled: { Config.agentModeEnabled },
                toggles: { Config.remoteInvokeToggles },
                now: { Date() }
            ),
            executor: executor
        )
    }

    private static func remoteHUDIcon(for name: String?) -> GlassesDisplayService.HUDIcon {
        switch name?.lowercased() {
        case "success": return .success
        case "warning": return .warning
        case "error": return .error
        default: return .info
        }
    }

    // MARK: - OpenClaw Notification Triage

    /// Assess an incoming OpenClaw notification through the agent.
    /// The agent decides: summarize it, query OpenClaw for clarification, or skip.
    func triageOpenClawNotification(_ rawMessage: String) async {
        // BK P0: triaging untrusted gateway output through the LLM (whose CLARIFY/FIX branches call
        // delegateTask) is an autonomous action — don't run it with Agent Mode off.
        guard Config.isOpenClawAgentActive else { return }
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
                memoryContext: Config.userMemoryEnabled ? userMemory.systemPromptContext(query: Config.userMemoryRetrievalEnabled ? triagePrompt : nil) : nil,
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
                    memoryContext: Config.userMemoryEnabled ? userMemory.systemPromptContext(query: Config.userMemoryRetrievalEnabled ? summaryPrompt : nil) : nil,
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
            let stateRaw = Wearables.shared.registrationState.rawValue
            errorMessage = RegistrationFlow.connectFailureMessage(stateRaw: stateRaw)
            addDebugEvent("connectAndListen gave up: registrationState=\(stateRaw)")
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
        releaseFramePin(trigger: .sessionStop)   // Plan CE

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
        await wakeWordService.resumeOtherAudio()
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
        // The master toggle wins over every restart rule below.
        if !listeningEnabled {
            print("🔇 Listening disabled — wake word listener stays off")
            return
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
        // The temple-tap trigger's silent claim (Plan CH) must not read back as user media.
        guard !SilentNowPlayingClaimer.isOwnInfo(info) else { return nil }
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
